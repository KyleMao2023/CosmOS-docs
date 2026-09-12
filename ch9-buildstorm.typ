// 第九章（下）：面向真实工具链的负载优化 —— 由 main.typ 在 `= 敏捷开发与性能观测` 之后、总结之前 #include。

前几章按子系统描述了 CosmOS 的设计。本章换一个视角：以决赛阶段引入的真实工作负载——*在内核上原生编译一个内核*——为线索，回顾我们为支撑它所做的功能补全与性能优化。这一章的材料按“负载画像 → 逐主题优化 → 观测方法”组织；各主题只展开机制与结论，与前文的子系统叙述互为印证。

= 优化实例：BuildStorm构建流程

决赛的评测项 BuildStorm 要求在 CosmOS 内以 glibc 用户态完成一次真实的 Rust 工具链冷构建：评测脚本挂载自包含的 rootfs 镜像（Debian glibc + nightly Rust 工具链 + 完整 cargo 离线仓库 + TGOSKits 源码树），在 guest 内执行 `cargo xtask arceos build -p arceos-helloworld`，从零编译出 ArceOS 内核镜像。计分取决于构建是否成功、产物大小，以及——最主要的部分——以 `/proc/uptime` 口径测量的总耗时。

这不是一个普通的测试集负载。cargo 与 rustc 的行为模式给内核提出了五类集中要求：

+ *进程生命周期风暴。* 一次多 crate 构建要 fork/exec 数百个 rustc、ar、ld 子进程；glibc 的 `posix_spawn` 走 `vfork`（`CLONE_VM|CLONE_VFORK`）+ `execve` 快路径。fork 的页表复制成本、execve 的镜像装载成本直接乘以进程数。
+ *大地址空间与缺页高频。* 单个 rustc 进程映射数百 MB 的代码与数据；首次执行每个代码页都产生缺页。TLB 刷新、帧分配、文件缺页装页构成第二条热路径。
+ *海量小文件与元数据。* 源码树与 cargo registry 的遍历以十万计地产生 `openat`/`statx`/`getdents64`；不存在的候选路径（probe 尝试）还会产生等量的负查找。dentry/inode 缓存的命中率与路径解析的常数成本决定第三条热路径。
+ *管道与多路等待。* cargo 的 jobserver 用管道传递构建令牌，rustc 的并行前端用管道回传消息；mio 事件循环要求 `epoll`（含边沿触发）、`eventfd`、`signalfd` 与非阻塞 fd 的完整语义。
+ *写回与计时。* 数千个 `.o`/`.rlib` 产物写入后由 `sync` 统一回写；评测脚本本身用 `/proc/uptime` 计时，逼真地暴露了任意细小的卡顿。

工具链还带来一批“兼容性必答题”：`pivot_root`（评测镜像以第二张盘提升为运行时根）、`fchdir`、`copy_file_range`、`mremap`、`MADVISE_DONTNEED`、LP64 上的 `pselect/ppoll` timespec ABI、`FIONBIO` 等。它们大多在相关章节顺带提及，本章不再重复；下面四个主题是这轮迭代中机制含量最高的部分。

== 主题一：地址空间切换——从“每次陷入换页表”到“内核共享高半区”

=== 测量先行：trap 路径的分层归因

初赛结束后，我们用 lmbench 的 `lat_syscall null`（RISC-V 上实测为 `getppid`）做微基准，发现 CosmOS 一次裸系统调用要 21.97–29.00 µs，而同一 QEMU 上 Linux 仅 1.09–1.25 µs。差距达一个数量级以上。经过测试，构建负载总共大约产生100,0000次系统调用，分摊到8个SMP也会带来了几十秒的差距。这项固定成本必须压下去。

优化沿“测量→假设→单变量改动→再测量”的循环展开。我们把 trap 路径拆成可以逐层启用的 feature（每层恰好引入一处缓存或省略一处工作），在受控环境（QEMU TCG、SMP=1、宿主 CPU 绑定、交错启动取中位数）下逐层测量，同时用 QEMU 的 `icount` 交叉验证墙钟数字——墙钟含宿主噪声，指令数反映 guest 侧路径长度，两者互相印证。分层的结果如下：

#figure(image("assets/buildstorm_trap_sweep.svg", width: 100%), caption: [getppid 微基准的分层优化 sweep：左为墙钟延迟（µs），右为 guest 指令数；数据为 10 万次取中位数（QEMU TCG，SMP=1）])

每一层的含义：*current_task_cache* 为每个 hart 引入一个 `AtomicPtr<TaskControlBlock>` 快速指针，读当前任务不再经过调度器关中断自旋锁（单项收益最大，约 −3.5 µs）；*process_identity_cache* 把 `parent_pid` 之类的不变身份缓存进 PCB 原子字段，`getppid` 不再升级父进程 `Weak` 与大锁；*return_work_cache* 在 TCB/PCB 上缓存“无信号、无需重调度、无 zombie 工作”的提示位，trap 返回路径读原子量即可放行；*trap_context_cache* 在 TCB 上快照 trap context 的物理页号、用户地址与地址空间 token，避免每次陷入重复查表加锁。四级缓存在 Cargo feature 上严格嵌套（依赖链 `trap_context_cache` → `return_work_cache` → `process_identity_cache` → `current_task_cache`），既便于逐层计价，也便于单独回退。相邻层的严格配对实验显示完整缓存链相对基线改善约 24%–29%；修复 `return_work_cache` 的一处锁外清提示位竞态后，SMP=4 下 40 轮八线程混合负载与 100 次并发 fork/exec/wait 均未观察到回退。

同一轮测量还把另外几项开销定界：进出内核的 CPU 记账与活跃 hart 位图合计约 2.2 µs，syscall 内核中断开合守卫约 0.55 µs，trap 轮询 TLB shootdown 邮箱仅约 14 条 guest 指令——都远小于剩余的大头。用只含汇编保存/恢复的探针内核直接测量，*两次 `satp` 写入本身占约 4.1 µs*，而 guest 指令数只差 6 条：成本几乎全部来自 QEMU 对 CSR 写与 TLB 失效的处理，而不是我们路径上的指令。结论明确：软件缓存已到边际收益，剩余差距是架构级的——*每次陷入内核都在切换页表*。

=== 架构改动：内核搬入高半区，trap 不再写 satp

上述观测结果看起来很违背常识：写入一个寄存器，为什么需要几微秒的时间呢？答案在QEMU实现源码中。我们可以观测到下面的行为：

*行为一：写 `satp` 即全量刷，且这不是 ISA 语义。* `write_satp` 经 `legalize_xatp` 处理：只要新值与旧值在 MODE、ASID 或 PPN 任一字段上不同，就执行 `tlb_flush(env_cpu(env))`——刷掉本 hart 软件译码 TLB 的*全部*条目：

```c
// target/riscv/csr.c: legalize_xatp（write_satp 调用）
mask = (val ^ old_xatp) & (SATP64_MODE | SATP64_ASID | SATP64_PPN);
if (vm && mask) {
    /*
     * The ISA defines SATP.MODE=Bare as "no translation", but we still
     * pass these through QEMU's TLB emulation as it improves
     * performance.  Flushing the TLB on SATP writes with paging
     * enabled avoids leaking those invalid cached mappings.
     */
    tlb_flush(env_cpu(env));
    return val;
}
```

注释中解释动机：连 Bare 模式的“无翻译”访问在 QEMU 里也要过软件 TLB，若 `satp` 写入不刷，旧地址空间的缓存翻译会泄漏到新地址空间。这是 QEMU 保守正确的实现选择——RISC-V 特权规范本身并不要求 `satp` 写入刷 TLB；恰恰相反，ASID 机制的设计初衷就是让“同 ASID 内改页表才需要刷、换 ASID 不必刷”。因此“每次陷入写两次 `satp`”在 QEMU 上的代价，是每次陷入两轮全量 TLB 失效——这解释了汇编探针测出的 4.1 µs 中为何绝大部分是模拟器 CSR/TLB helper 的成本，而非 guest 指令。内核共享高半区后普通陷入不再写 `satp`，在 QEMU 上的收益因此比真硬件更夸张。

*行为二：`sfence.vma` 的操作数被完全忽略。* 按 ISA，`sfence.vma rs1, rs2` 应只失效 rs1 指定虚拟页（rs1=x0 时为全部）、且只针对 rs2 指定 ASID（rs2=x0 时为全部 ASID）。QEMU 的翻译例程却是：

```c
// target/riscv/insn_trans/trans_privileged.c.inc
static bool trans_sfence_vma(DisasContext *ctx, arg_sfence_vma *a)
{
    decode_save_opc(ctx, 0);
    gen_helper_tlb_flush(tcg_env);   // rs1/rs2 未被使用
    return true;
}
```

译码格式 `@sfence_vma ... %rs2 %rs1` 提取了两个操作数，但翻译后的代码根本不引用它们——带 ASID 的刷、按页的刷、全量刷，在 QEMU 里是*同一个* `tlb_flush`：刷掉本 hart 全部 mmu_idx 的所有条目。连 Svinval 扩展里本应逐页失效的 `sinval_vma` 也复用同一处理，源码注释直言“目前与 `sfence.vma` 相同”。

根因是软件 TLB 的索引方式，而非能力缺失。QEMU 软件 TLB 的键是 `(mmu_idx, 虚拟地址)`，而 RISC-V 的 `mmu_idx` 只由特权级、SUM 位与两阶段译码派生——表项里*没有 ASID 字段*。“按 ASID 挑出若干条目清零”意味着遍历整张表逐项比对，而全量刷只是对每 mmu_idx 一次 `memset`（`tlb_mmu_flush_locked`），外加清空 4096 项的翻译块跳转缓存（`TB_JMP_CACHE_BITS = 12`）。在软件实现中“选择性清除”远贵于“全部清空”，QEMU 便选择了恒定成本的全量路径。作为对照，QEMU 核心层其实提供了精细失效原语（`tlb_flush_page_bits_by_mmuidx` 等），ARM 目标机正在使用——所以这是 RISC-V 目标机的实现简化，不是 QEMU 整体的架构限制。

#figure(
  table(
    columns: (auto, auto, auto),
    [操作], [RISC-V ISA 语义], [QEMU 10.1 TCG 实际行为],
    [写 `satp`（字段变化）], [不隐含刷 TLB；配合 ASID 可免刷], [全量刷本 hart 全部 TLB（`legalize_xatp`）],
    [`sfence.vma`（带 vaddr/ASID）], [按 rs1 页、rs2 ASID 选择性失效], [忽略操作数，全量刷（`trans_sfence_vma`）],
    [`sinval_vma`（Svinval，按页）], [仅失效单个地址项], [与 `sfence.vma` 相同（复用同一 helper）],
  ),
  caption: [QEMU TCG 与 ISA 语义的偏差及源码位置（`target/riscv/`）],
)

因此，我们要尽可能减少任何 `sfence.vma` 与 `satp` 的写入。我们参考Linux的内存布局：Linux 在 RISC-V 上 syscall 入口不切换 `satp`：用户 PGD 共享内核高半区顶层页表项，普通陷入在同一个地址空间内完成，只有调度器切换 `mm` 时才写 `satp`。我们照此重整了地址空间布局，成为了最终如 @vm_layout 所示的结构：

+ *内核整体迁入 Sv39 高半区。* 链接脚本把内核从 `0x80200000` 平移到 `0xffffffc000000000` 起的规范高地址，仅保留一小段物理地址的 bootstrap 入口在打开分页前执行；物理 direct map 同样落在高半区。
+ *每个用户根页表共享内核半区。* 每个进程的 `MemorySet` 建立时调用 `share_kernel_half_from(&KERNEL_SPACE)`，把内核根页表高半区的全部顶层项复制进用户根页表，再以 `mark_kernel_half_global` 置 G 位（全局映射，进程切换不失效）。内核目录页的生存期由 `KERNEL_SPACE` 持有，用户根页表只拥有自己的低半区子树。
+ *trap 路径删除两次 `satp` 写。* trap 入口直接在当前地址空间进入内核代码；trap 返回只在目标 token 与当前 `satp` 不一致（即发生了进程切换）时才写 `satp` 并按 ASID 决定是否 `sfence.vma`。
+ *trap context 迁至低半区顶端。* 它是进程私有映射，原先紧贴 trampoline 的布局会与“共享完整内核半区”冲突；移到低半区最高页之下后，每个进程的内核半区顶层项可以整段共享而无碰撞。

// 图片生成说明（待绘制）：建议画“优化前 vs 优化后”对比图。
// 左（优化前）：用户态 --(trap: 写 satp→内核页表)--> 内核 --(返回: 写 satp→用户页表)--> 用户态；两次切换各配一次 TLB 失效。
// 右（优化后）：用户态与内核共享同一根页表；trap 只换栈不换 satp；仅调度器 switch_mm 时写 satp（配 ASID）。
// 下方可标注用户根页表结构：低半区 = 用户 VMA + trap context；高半区 = 复制自 KERNEL_SPACE 的共享目录项（G 位）。

这一改动与前述四级缓存正交且叠加：缓存层削掉了锁与查找，共享页表层削掉了切换本身。LoongArch 侧对应地利用了 DMW 直接映射窗口——内核执行本就不依赖页表切换，trap 入口不再重写 `PGDL`，只有检测到根页表变化时才 `invtlb`。

=== ASID：让进程切换也不必全量刷 TLB

对于硬件设备，ASID可以避免TLB flush时全量的刷新，仍然值得引入。具体来说：

- 启动时经 `probe_address_space_id_mask` 探测硬件 ASID 位宽（QEMU 上为 16 位，即 65535 个可用号）；ASID 0 保留给内核与兼容回退。
- 每个用户 `MemorySet` 创建时分配一个*启动期内单调递增、不回收*的 ASID，编码进地址空间 token。不回收是刻意的保守设计：一个 ASID 在本次启动内不会指向第二个根页表，从而把“删除 trap 路径刷 TLB”与地址空间销毁顺序完全解耦，无需复杂的分代回收协议。
- 耗尽时新地址空间回退 ASID 0，trampoline 保留兼容刷法，正确性不受影响。

配合 ASID，HAL 的 TLB 操作按粒度拆为 `flush_tlb_asid` / `flush_tlb_page_asid` / `flush_tlb_range_asid` 三个接口；第四章描述的 shootdown 协议由“按地址空间全量本地刷”细化为按 ASID 与按范围。但对于QEMU，因为之前介绍的冲刷策略退化的原因，其中范围刷的 `TLB_RANGE_PAGE_LIMIT` 则为1——只有单页才进行范围刷，其他情况仍然全量刷（实际策略总是一遍全量刷）。

== 主题二：fork 与 exec——批量 COW、vfork 快路径与懒 ELF 装载

构建负载里进程创建的两大成本是：fork 时逐页降权+逐页建子页表映射，execve 时整镜像读入。我们沿三条链优化。

+ *减轻execve负载。* 早期实现为处理“刚写入的产物立即被 exec”的一致性，在 execve 里全局同步 page cache（`sync_page_cache_all`），一次构建数百次 exec 意味着数百次全局扫描。因此，我们先优化为按 `(fs_id, ino)` 精确同步目标文件。随后引入*懒 ELF 装载*：装载器只预读 ELF 头与程序头表（上限 1 MiB、16 KiB 分块 I/O），为各 `PT_LOAD` 段登记 VMA 而不装页，代码与数据页推迟到首次执行/访问缺页时经 page cache 物化。以最常调用、最大的两个二进制文件`cargo`和`librustc_driver.so`为例，我们可以用 `readelf` 提取它们的结构占比。可以看到，真正可执行的代码段仅占一部分，即使运行代码全部被覆盖到，也能节省大量 I/O 与页表操作；对于仅查询版本号这类操作，几乎可以瞬时完成。

#figure(image("assets/rust_elf_size_pies.svg"), caption: [Rust 工具链 ELF 文件的结构占比：代码段、数据段、BSS、符号表、调试信息等。])

+ *fork 的批量 COW。* 原 fork 对每个私有页分别执行“降权父 PTE + 建子 PTE”，每次都是完整的页表遍历。现在 fork 先在锁内收集 `(vpn, PrivatePage)` 批次，把*物理连续的页段*合并成 run：中间页表页一次性预分配，叶子 PTE 以 `map_preallocated_range` 批量写入；父侧降权也改为 `update_flags_range` 按段批量完成。对拥有大量连续物化页的 rustc 父进程，页表操作的次数从“每页一趟”降到“每连续段一趟”。

+ *vfork 快路径。* glibc `posix_spawn` 的 `CLONE_VM|CLONE_VFORK` 语义是“子进程借用父地址空间直到 exec/exit”。我们实现了真正的借用：`from_shared_vfork_view` 让子进程的 `PageTable` 经 `borrowed_from` 直接引用父根页表（同一根帧，`Arc` 保活），*零页表分配、零 COW 降权*；子进程 exec 或退出时经 `take_shared_vfork_state` 把运行期累积的状态（物化的新页等）整体交还父进程 `adopt`，父进程随后从等待中放行。快路径有明确的安全边界：多线程父进程回退普通共享 VM 克隆（其他线程可能在借用期修改地址空间）；共享借用期间父侧 COW 页的写语义按“写即可见”物化为可写副本，保证 posix_spawn 依赖的 `args.err` 回传正确。

// 图片生成说明（待绘制）：建议画 vfork 快路径时序图。
// 父进程 --clone(CLONE_VM|CLONE_VFORK)--> 子进程（PageTable::borrowed_from 父根，零分配）；父进程阻塞在 wait_exit_queue。
// 子进程 execve/exit --> take_shared_vfork_state（运行期状态打包）--> 唤醒父 --> adopt_shared_vfork_state（状态并回）--> 父继续。
// 旁注：多线程父 → 回退普通共享 VM 克隆（安全边界）。

配套的正确性收尾：进程退出与 `msync`/`munmap`/`mremap` 的文件映射回写统一为 *prepare/execute* 两段式——持地址空间锁时只收集脏范围（`prepare_msync_range` 返回 `FileMappingSyncPlan`），锁外执行真正的块 I/O，任务保持 Running 直至写回完成，避免持锁阻塞与退出竞态。

== 主题三：读路径与元数据缓存——预读、去重、负缓存

=== 读路径：四步演进

构建的读模式高度顺序化（源码、`.rlib`、rustc 自身的代码页），读路径的优化是一个四步演进链：

+ *去重。* PageCache 装页改经 `read_at_page_cache` 直接读块设备，文件数据不再同时驻留 page cache 与 block cache（第五章所述“双重缓存”局限就此消除；block cache 回归元数据块职责）。
+ *缺页窗口预读。* 文件缺页确认顺序窗口后一次装载 `FAULT_READ_WINDOW_PAGES = 16` 页（恰为一个 64 KiB virtio 请求），随机缺页仍只装请求页——Rust 工具链的二进制大而只读，逐页缺页会让每个冷页各付一次完整的文件系统与块缓存路径。
+ *前后台分离。* 前台同步只装 `FAULT_READAHEAD_DEMAND_PAGES = 16` 页，确认的 128 KiB 顺序窗口的后半段交给低优先级内核线程 `kreadahead` 后台补齐；任务队列以相邻范围合并（有 `READAHEAD_MERGED/DROPPED_JOBS` 计数），上限 2048 页防堆积，供不应求时静默丢弃——预读是尽力而为的，绝不阻塞需求 I/O。
+ *预映射与直读。* 缺页装好的 cache 页不经中间 `Vec` 拷贝直接安装进用户页表；多页读检测*物理连续段*，直接把块设备 DMA 到页缓存物理页，全程一次拷贝（`direct_read_runs/pages` 计数区分直读与缓冲读）。另有一处细节：帧分配器返回的页本已清零，装页路径删去了第二次冗余清零。

=== 元数据缓存：负缓存、水位与并发化

除了加速正常查找的正向dentry cache，还有很多场景下，会在某一个固定的目录多次查询，但结果都是失败（不存在）的。例如，在PATH变量中找到某个命令。为此 dentry cache 引入*负缓存项*：查找结果用 `DentryLookup::{Positive, Negative, Miss}` 三态表达，`Negative` 记录“这个名字确认不存在”，让重复探测命中内存直接返回 ENOENT。

容量的依据来自工作集画像：一次 `cargo build` 同时引用源码树、registry 与构建产物的上万个名字，原先 4096/2304 的水位在单次构建内反复淘汰抖动。dentry 与 inode 缓存水位一致提升到 16384/12288（dentry 强持有 inode `Arc`，两者水位联动才能兑现容量）。

并发化的演进同样三步：全局单锁 `BTreeMap` 先按*父目录分桶*成两级结构（外层目录→内层名字表，命中路径经 `String: Borrow<str>` 零分配查找，删除整个目录桶一次完成）；再从 `Mutex` 换成 `RwLock`——查路径只取读锁，海量并发 `statx`/`openat` 不再互斥；桶内访问位改为原子量，读锁下也能标记引用。

#figure(image("assets/dentry_cache_structure.svg", width: 100%), caption: [当前 dentry cache 的两级目录分桶、并发读路径与 CLOCK 回收结构])

=== 微优化：路径解析与 statx

两处单点优化源于 syscall 计数画像。其一，`execve`/`openat` 传入的绝对路径多数已是规范形式，路径解析对“以 `/` 开头、无空段、无 `.`/`..`”的简单绝对路径走零分配借用（`Cow::Borrowed`），跳过 canonicalize 的字符串构造。其二，`statx` 的 256 字节结果缓冲常跨页边界，原翻译路径按页循环分配；新的 `translated_single_page_fast` 用单次页表查找覆盖“单页内小对象”这一绝大多数情形，跨页对象退回慢路径。同一 `read_cstring_from_user` 从逐字节翻译改为按页翻译，长路径名（工具链路径动辄上百字节）的拷贝成本线性下降。下图展示了 statx 翻译路径的微优化效果。

#figure(image("assets/statx_latency_compare_simple.svg"), caption: [statx 翻译路径的微优化：左为 Linux guest，右为 CosmOS guest；数据为 10 万次取中位数（QEMU TCG，SMP=1）])

== 主题四：IPC 与等待——epoll 家族的补全

初赛的 polling 子系统以二维位图 `ppoll` 为核心，epoll 仅有 `epoll_create1` 占位——当时判断“海量连接下 $O(1)$ 就绪通知的收益在当前规模不兑现”。构建负载推翻了这个判断：cargo/rustc 的事件循环（mio）把管道、终端、信号统一挂进 epoll，且默认注册*边沿触发*。这一轮补全了整个家族：

+ *epoll 完整语义。* `epoll_ctl` 的兴趣集挂在 `EpollItem` 上：每项记录事件掩码、用户 `data`、底层 `FileDescription` 与两个订阅索引（按通知源、按描述符），关闭 fd 时能反查摘除。就绪通知复用第六章的 `notify_poll_source`：文件状态变化时对应项进入就绪队列，`epoll_pwait/pwait2` 支持带信号掩码的等待。
+ *边沿触发。* ET 项维护 `edge_ready` 原子状态：仅当就绪位从 0 变为非 0（新边沿）才入队，消费一次后不再重复上报，直到状态清零后再次置位——这正是 mio 要求的“通知一次、读到 EAGAIN 为止”语义。
+ *eventfd 与 signalfd。* eventfd 以 64 位计数器 + 两条等待队列实现完整读写语义（含超过 8 字节缓冲、溢出检查与非阻塞）；signalfd 把信号掩码变成可读文件：到达的信号若落在掩码内即写入 128 字节 Linux ABI 兼容的 `signalfd_siginfo` 记录，供 `epoll` 统一等待——构建工具由此把 SIGCHLD 纳入同一事件循环。
+ *管道与非阻塞。* 环形缓冲从 1 KiB 扩到 1.5 KiB 以减少 jobserver 令牌传递的唤醒频率；`ioctl(FIONBIO)` 与非阻塞 socket 补齐后，mio 的注册路径才完整工作。

总的来说，CosmOS的poll/epoll逻辑如下面的流程图所示：

#figure(image("assets/epoll_flow_and_data_structures.svg", width: 100%), caption: [CosmOS poll/epoll 的数据结构与就绪通知流程图])

== 小结

总的来说，优化方法上有两点值得一提。第一，*画像先于优化*：`syscalls_count` 显示构建初期 `statx`/`openat` 与缺页的计数远超预期，元数据缓存与翻译微优化的优先级由此排定，而不是凭直觉猜热点。第二，*对照环境的公平性*：所有跨系统对照（statx、进程周期、cargo 微负载）使用同一份静态链接二进制、同一 QEMU 版本与内存配置，Linux 侧由同一脚本测量，避免“拿优化的内核比没优化的对照”这类自我欺骗。

在最终，我们给系统调用的入口和出口添加计数器，测量所有syscall所花费的累计时间和平均时间（多hart也同样累积）。

#figure(image("visualize/syscalls_count_top15_total_us.svg"), caption: [构建负载下 syscalls_count 的前 15 个系统调用累计耗时（µs）])

从表中可以看到，耗时最长的一部分syscalls为`wait4`、`futex`、`sigsuspend`、`ppoll`，和`pselect6`，但它们本身就有阻塞等待语义，间隔很久返回是预期的。`read`也有一部分的阻塞等待块设备语义，但我们之前已经有所优化。剩余的调用多在几秒量级，并且分摊到多SMP则更短。这表明较显著的优化已经基本结束，考虑到机器也有性能波动，后续的微优化可能不会产生可观测的收益。

这一轮工作的主线可以概括为三句话。*以真实负载定优先级*：构建风暴把进程生命周期、缺页、元数据与 IPC 四条路径同时推到极限，观测工具先于优化建立了画像。*先削固定成本，再动架构*：trap 分层 sweep 用逐层计价把“软件缓存收益”与“页表切换成本”干净地分离，后者以内核高半区共享 + ASID 的架构改动收官。*每个快路径都有边界*：vfork 借用在多线程父进程回退，ASID 耗尽回退兼容刷法，预读队列满了就丢——正确性从不押注在“负载总是友好”上。