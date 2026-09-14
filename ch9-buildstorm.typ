// 决赛负载优化：以真实构建路径串联地址空间、文件读与事件等待。

= 决赛负载与跨模块优化

BuildStorm 在 CosmOS guest 中运行 glibc 用户态 Rust 工具链，并从离线仓库构建 ArceOS 目标。一次构建集中触发 fork/exec、ELF 文件缺页、海量 openat/statx、管道 jobserver 和 mio epoll 事件循环。它既检验接口兼容性，也把进程启动、地址空间、读路径与等待机制的固定成本放大。

优化以真实工作负载和微基准共同归因。所有对照使用相同 guest 镜像、QEMU 配置和 workload；分层实验用于判断成本来自内核路径、页表/TLB 行为还是宿主模拟器。

== 地址空间切换：共享高半区与 ASID

初始 getppid 微基准在 QEMU TCG、SMP=1 下约为 21.97–29.00 µs；同一环境中的 Linux guest 约为 1.09–1.25 µs。分层 sweep 显示，当前任务、进程身份、返回工作状态和 trap context 的轻量缓存能减少锁与重复查表，完整缓存链相对基线约改善 24%–29%。进一步拆解发现，RISC-V 陷入路径每次写 satp 会触发 QEMU TCG 的全量 TLB 处理，剩余开销已不只是 guest 指令数。

#figure(image("assets/buildstorm_trap_sweep.svg", width: 100%), caption: [getppid 陷入路径的分层优化测量])

为消除普通陷入中的页表切换，RISC-V 用户根页表共享内核高半区；trap 入口可直接进入内核映射，仅在地址空间实际切换时更新 satp。用户页表仍拥有独立低半区，进程隔离不变。ASID 用于标识地址空间，使切换可避免不必要的全量失效；ASID 资源耗尽时回退兼容刷新策略。图示中的共享映射布局见 @vm_layout。LoongArch 则利用 DMW 直接映射窗口避免在陷入入口重复改写根页表寄存器。

用户根页表复制内核高半区目录项并标记为全局映射；trap context 保留在用户低半区的专用位置，使共享目录范围不与进程私有状态冲突。ASID 在启动时探测硬件位宽后单调分配，当前启动周期内不复用；编号耗尽的新地址空间使用兼容刷新路径，避免旧 TLB 项与新根页表别名。

这一选择也解释了虚拟机测量的边界：RISC-V 特权架构并不要求写 satp 自动清空所有 TLB，但当前 QEMU TCG 会在地址空间字段变化时全量处理软件 TLB；该版本对 sfence.vma 的地址与 ASID 操作数也未提供等价的选择性失效。因此，优化评估把墙钟延迟与 guest 指令数并列，并将 TCG 下的 TLB 行为明确作为测量环境因素，而不把它泛化成真实硬件结论。

== 进程启动：批量 COW、vfork 与懒 ELF

fork 的私有页复制改为按连续物理页段批量建立子映射并批量降低父映射权限，减少逐页遍历；常用 posix_spawn 路径实现 CLONE_VM|CLONE_VFORK 地址空间借用，避免为子进程复制页表。多线程父进程等不满足借用安全条件时回退普通共享 VM 路径。

vfork 子进程在 execve 或退出前借用父进程的页表根，父进程在 wait-exit 队列上等待。子进程执行期间物化的映射变化在结束时被收集并交还父进程，再唤醒父进程继续运行；多线程父进程可能同时修改地址空间，因此不走该借用快路径。此处优化的是页表复制与同步成本，不能削弱父子之间的生命周期和映射可见性约束。

execve 只读取 ELF 头与程序头并建立 PT_LOAD 对应 VMA，代码和数据页在首次访问时再通过缺页装入 Page Cache。这样，查询版本等只触及少量映射的执行不必预读整个大型可执行文件；已访问页面仍经过同一套页权限、缺页和 COW 检查。

#figure(image("assets/rust_elf_size_pies.svg", width: 100%), caption: [Rust 工具链 ELF 中实际装载段与非装载信息的占比])

== 文件读路径：预读与元数据去重

真实构建显示，源码、registry 和 rustc 可执行文件形成大工作集。文件数据改由 Page Cache 直读块设备，避免 Page Cache/Block Cache 双重保存；顺序缺页触发有限窗口，需求页由前台完成，其余相邻页交给低优先级 kreadahead worker。后台范围可合并且有界，拥塞时丢弃投机任务，不延迟需求 I/O。

前台按需读与后台预读分工：需求页优先完成，后台任务只填充顺序窗口的剩余部分。队列合并相邻区间并限制总页数；资源不足时丢弃投机读，不等待预读完成。装入后的 cache page 可直接安装到用户映射，多页读取还可按物理连续段组织块设备请求，减少重复分配和中间拷贝。

元数据路径按父目录分桶，以读写锁和负缓存减少并发 openat/statx 的串行查找及重复失败查询；常见绝对路径使用借用解析，单页内用户缓冲翻译走单次页表查询快路径。

缓存水位根据一次构建同时触及的源码、registry 与构建产物工作集调整；正向 dentry 与负缓存共用分桶结构，读路径用读锁并避免临时名字分配。对 statx 小结果缓冲，单页范围用一次页表查询处理，跨页输入则回到通用翻译路径，快路径不改变边界检查。

#figure(image("assets/dentry_cache_structure.svg", width: 100%), caption: [按父目录分桶的 dentry cache 与并发查找])
#figure(image("assets/statx_latency_compare_simple.svg", width: 100%), caption: [statx 用户缓冲翻译优化的对照测量])

== 事件等待：epoll 家族

mio 将构建进程的管道、终端和信号放入 epoll 事件循环。CosmOS 在统一 source_id 通知上实现持久兴趣集、就绪队列和边沿触发状态；eventfd 与 signalfd 将计数和信号接入相同事件模型，非阻塞文件描述符支持 jobserver 与构建事件循环。

#figure(image("assets/epoll_flow_and_data_structures.svg", width: 100%), caption: [poll/epoll 兴趣集、通知源与就绪队列])

epoll 项同时记录事件掩码、用户 data、底层文件描述及按 source 和 fd 反查的订阅索引；关闭 fd 时可以摘除双向关系。就绪变化沿 source_id 通知，边沿触发项用原子就绪位保证一次新边沿只入队一次。eventfd 以计数器接入事件循环，signalfd 把匹配信号转成 ABI 记录，使 SIGCHLD、管道和终端可统一等待。

== 负载画像与验证边界

syscalls_count 先按调用次数和内核侧累计时间排序，帮助把 openat/statx、缺页与事件等待纳入优化优先级。wait4、futex、sigsuspend 和 ppoll 的累计时间包含预期阻塞，不应直接解释成内核执行慢；文件路径的微基准则固定文件大小、记录粒度、缓存状态和测量次数，并与 Linux guest 使用同一静态负载和 QEMU 配置。

#figure(image("visualize/syscalls_count_top15_total_us.svg", width: 100%), caption: [BuildStorm 构建期间系统调用累计耗时画像])

这些工作由同一观测闭环驱动：系统调用画像确定热点，局部探针和缓存计数解释原因，再以相同负载验证改动。项目特色不在单个孤立快路径，而在地址空间、进程、文件读和事件等待协同支撑真实构建。
