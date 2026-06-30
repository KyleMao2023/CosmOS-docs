// 第三章：进程管理 —— 由 main.typ 在 `= 进程管理` 之后 #include。

本章讨论 CosmOS 的进程管理子系统。若说上一章的任务调度回答的是“哪个执行流获得 CPU”，那么进程管理回答的则是“这个执行流拥有哪些资源，以及这些资源在 fork、clone、exec、exit 和 wait 中如何转移”。在 CosmOS 中，任务是调度实体，进程是资源容器：一个进程拥有地址空间、文件描述符表、当前工作目录、凭据、信号处置、子进程集合、资源限制、定时器和若干线程；调度器只运行任务，而用户态观察到的进程语义主要由 `ProcessControlBlock` 维护。

进程管理的实现集中在 `os/src/task/process.rs`、`os/src/task/mod.rs`、`os/src/task/id.rs` 与 `os/src/syscall/process.rs`。`ProcessControlBlock` 管进程级资源，`TaskControlBlock` 管线程级执行状态，`TaskUserRes` 管每个线程在用户地址空间中的栈和 trap context，`PID2PCB` 与 `TID2TASK` 分别提供进程号和 Linux 可见线程号的查找入口。这样的拆分让进程生命周期可以沿着清晰的路径展开，也让线程、信号和调度之间的接口保持可控。

== 设计总览

传统 Unix 进程模型有一个很强的抽象：`fork` 复制当前进程，子进程从同一条指令之后继续执行；`exec` 保留进程身份但替换用户态映像；`exit` 只把进程变成 zombie，直到父进程 `wait` 后才真正回收。Linux 在此基础上又加入了线程组、`clone` 共享资源标志、pid/tid 分离、`CLONE_CHILD_CLEARTID`、pidfd、进程组、会话、capability 和各种 procfs 可见状态。CosmOS 的目标不是一次性实现 Linux 的全部细节，而是抽取其中对常见 libc、shell、测试套件和多线程程序最关键的语义。

因此，本内核采用了“进程资源容器 + 任务执行实体”的模型。进程本身不被调度；它通过 `tasks: Vec<Option<Arc<TaskControlBlock>>>` 持有一个或多个任务。主线程的 Linux 可见 tid 等于进程 pid，非主线程则从全局线程号分配器中取得独立 tid。调度器看到的是每个 `TaskControlBlock`；系统调用层则根据调用语义在进程号、线程号和进程内 tid 索引之间转换。

整个进程生命周期可以概括为：

```text
init:
    装载 /sbin/init ELF
    创建 PID、PCB、主线程、初始用户栈
    发布到 PID2PCB 与调度器

clone / fork:
    复制或共享地址空间
    继承文件表、cwd、凭据、信号处置等上下文
    创建子 PCB 与主线程，设置子返回值为 0
    发布到 PID2PCB 与调度器

exec:
    解析 ELF 或 shebang
    替换当前进程地址空间
    重建主线程用户栈与 trap context
    保留 PID、父子关系和未关闭的 fd

exit:
    标记任务或进程为 zombie
    清理等待队列、futex、timer、fd、地址空间等资源
    唤醒父进程 wait 队列

wait:
    在父进程 children 中查找 zombie
    编码退出状态
    从 PID2PCB 移除并最终释放 PCB
```

这一章沿着这几条路径展开，而不是单独罗列系统调用。原因在于，进程管理的正确性主要来自生命周期阶段之间的顺序：什么时候可以发布给调度器，什么时候还不能释放内核栈，什么时候必须先把 fd 表项移出锁外再 drop，什么时候 zombie 还要保留在父进程的 children 中。

== 进程控制块

=== PCB 外壳与内部状态

`ProcessControlBlock` 的外层只保存少量不可变或跨锁访问的字段：

```rust
pub struct ProcessControlBlock {
    pub pid: PidHandle,
    pub clone_exit_signal: u32,
    fd_table_generation: AtomicUsize,
    inner: SpinNoIrqLock<ProcessControlBlockInner>,
    pub wait_exit_queue: Arc<WaitQueue>,
}
```

`pid` 是进程号句柄，拥有 PID 生命周期；`clone_exit_signal` 记录该进程退出时应投递给父进程的信号，普通 fork-like 子进程通常是 `SIGCHLD`；`fd_table_generation` 用于让依赖 fd 表结构的路径感知 fd 表变化；`wait_exit_queue` 是父进程阻塞在 `wait4` / `waitpid` 时使用的等待队列。

真正庞大的进程资源都在 `ProcessControlBlockInner` 中。它包含地址空间、虚拟内存布局、父子关系、文件描述符表、资源限制、信号处置、线程表、当前工作目录、根目录、环境变量、umask、凭据、CPU 计时、interval timer、robust list、SysV 共享内存附件等。它的角色可以理解为“用户态进程上下文的内核镜像”。

#figure(
  table(
    columns: (1.4fr, 2.8fr),
    [资源类别], [PCB 中的代表字段],
    [地址空间], [`memory_set`、`vm_layout`、`shm_attachments`],
    [父子关系], [`parent`、`children`、`exit_reason`、`wait_exit_queue`],
    [文件上下文], [`fd_table`、`cwd`、`root`、`umask`、`fd_table_generation`],
    [信号上下文], [`pending_signals`、`pending_siginfo`、`signal_actions`],
    [线程集合], [`tasks`、`task_res_allocator`],
    [身份与限制], [`cred`、`resource_limits`、`oom_score_adj`、`keyrings`],
    [时间统计], [`user_time`、`kernel_time`、`child_user_time`、`itimer_*`],
  ),
  caption: [进程控制块中的主要资源],
)

这里有一条重要纪律：可能触发阻塞或复杂析构的资源，不应在持有进程自旋锁时直接销毁。例如关闭文件描述符可能触发文件同步、块设备等待或 inode 回写；退出和 exec 路径都会先把 fd 表项从 PCB 中取出，释放进程锁后再 drop。这个做法与第六章等待队列中“锁内收集、锁外唤醒”的纪律类似，目的都是避免在不可睡眠的临界区中执行可能重入或阻塞的动作。

=== PID、TID 与线程表

CosmOS 同时维护三个编号概念。

进程号 pid 来自 `pid_alloc()`，用于 `PID2PCB` 全局表和用户态 `getpid`、`waitpid`、`kill(pid, sig)` 等接口。进程内 tid 是 `tasks` 数组的下标，由每个进程自己的 `RecycleAllocator` 分配，用来定位该进程内的任务槽。Linux 可见 thread id 则用于 `gettid`、`tgkill`、`CLONE_PARENT_SETTID` 等接口：主线程的 thread id 等于进程 pid，非主线程从全局 `thread_id_alloc()` 分配，并登记到 `TID2TASK`。

`TaskUserRes` 把这几者联系起来：

```rust
pub struct TaskUserRes {
    pub tid: usize,
    pub thread_id: usize,
    pub thread_id_handle: Option<ThreadIdHandle>,
    pub ustack_base: usize,
    pub process: Weak<ProcessControlBlock>,
}
```

每个线程在用户地址空间中拥有独立的 trap context 映射和一段用户栈。主线程创建时通常分配完整用户资源；Linux `CLONE_VM` 线程由用户态提供栈，内核只为它分配 trap context，因此使用 `TaskUserResAlloc::TrapOnly`。这样既符合 pthread 创建线程时“用户栈由 libc 管理”的习惯，又保证每个线程都有独立的 trap frame 可供内核保存用户态寄存器。

线程加入进程分两步：先通过 `create_task` 构造 `TaskControlBlock`，再通过 `attach_task` 写入 `tasks[tid]` 并登记 `TID2TASK`。只有当 trap context、返回值、TLS、用户栈等字段都设置完成后，任务才会被 `add_task` 发布给调度器。这条顺序非常关键：在 SMP 环境下，一旦任务进入运行队列，就可能立刻在另一个 hart 上运行；如果发布早于 trap context 修补，fork 子进程可能看不到正确的返回值 0。

== 初始进程

系统启动后，`INITPROC` 负责创建第一个用户进程。它打开 `/sbin/init`，解析 ELF 或脚本解释器，建立用户地址空间，分配 PID，并初始化根用户凭据。init 的 `sid` 和 `pgid` 都设置为自己的 pid，使它成为会话首领和进程组首领；这符合 Linux 语义，也避免后续 fork 出来的 shell 或用户程序继承非法的 0 号会话/进程组。

init 进程的文件描述符表由 `new_stdio_files()` 构造，默认 cwd 为 `/root`，root 为 `/`，环境变量包含 `HOME`、`PATH`、`SHELL`、`PWD` 等最小用户态环境。随后内核创建主线程，在用户栈上按 Linux ELF ABI 写入 `argc`、`argv`、`envp` 和 auxv，初始化 trap context，并在 PCB 完全构造后执行两个发布动作：

```text
insert_into_pid2process(init.pid, init)
add_task(init_main_thread)
```

这个顺序体现了进程管理和调度器之间的边界：进程只有在地址空间、用户栈、文件表、PID 表项和主线程都准备好之后，才能进入调度器。调度器不负责判断一个进程是否“半初始化”；发布前的完整性由进程管理模块保证。

== clone 与 fork

=== clone 请求解析

Linux 把 `fork`、`vfork`、线程创建和部分命名空间创建都压进了 `clone` / `clone3`。CosmOS 在系统调用层先把 legacy ABI 或 `clone3` 参数统一解析为 `CloneRequest`，再根据标志位选择“线程分支”或“进程分支”。

`clone3` 的解析会进行一批 Linux 兼容的合法性检查：`CLONE_SIGHAND` 必须配合 `CLONE_VM`，`CLONE_THREAD` 必须配合 `CLONE_SIGHAND`，`CLONE_FS` 不能与 `CLONE_NEWNS` 同时出现，`stack` 与 `stack_size` 必须同时为 0 或同时非 0，`exit_signal` 不能超过最大信号编号。`set_tid` 数组和部分高级 cgroup 语义当前不完整支持，遇到不支持组合时返回相应错误。

系统调用层识别两条主要路径：

```text
CLONE_THREAD && !CLONE_VFORK:
    在线程组内创建新 TaskControlBlock
    共享当前 ProcessControlBlock

否则:
    创建新的 ProcessControlBlock
    复制或按标志共享部分资源
```

=== 进程分支：fork-like 创建

进程分支由 `ProcessControlBlock::clone_process` 实现。它当前面向 fork-like 语义，要求父进程只有一个线程；若多线程进程尝试走该分支，内核返回 `EINVAL`。这个限制是有意的：多线程 fork 需要处理其他线程持有的用户态锁、robust futex、信号掩码和异步取消状态，若没有完整协议，很容易产生子进程继承半锁定状态的问题。

进程创建的第一步是处理地址空间。普通 fork 使用 `MemorySet::from_existed_user` 复制父地址空间，并通过 COW 和 TLB shootdown 维护父子页表一致性；带 `CLONE_VM` 的 process-style clone 则使用共享 VM 的构造路径。随后内核复制虚拟内存布局、凭据、信号处置、cwd/root、exec_path、umask、资源限制、时间命名空间偏移、网络命名空间标记和共享内存附件等状态。

文件描述符表按表项克隆。`FdEntry` 本身区分 fd 表项标志与底层 `FileDescription`，克隆 fd 表时复制表项并共享底层打开文件描述，从而保留文件偏移和文件状态标志的常见 Unix 语义。若后续 `exec` 遇到 `FD_CLOEXEC`，则只关闭对应 fd 表项。

父子关系由 `parent` 和 `children` 维护。普通 clone 把新进程挂到当前进程的 children；若指定 `CLONE_PARENT`，则挂到调用者的父进程下。子进程的 `clone_exit_signal` 记录低 8 位退出信号，供退出时唤醒或通知父进程。

创建子 PCB 后，内核还要创建子主线程。这里不能立即发布给调度器，而要先修补继承来的 trap context：子进程系统调用返回值设为 0，父进程返回子 pid；若用户传入 `child_stack`，则子进程从指定用户栈继续；若指定 `CLONE_SETTLS`，则设置 TLS 寄存器。完成这些修补、写入 parent/child tid 指针、登记文件映射后，才执行：

```text
insert_into_pid2process(child_pid, child)
add_task(child_main_thread)
```

`CLONE_VFORK` 当前被模拟为 fork-like process clone。若指定 vfork，父进程会在自己的 `wait_exit_queue` 上等待子进程变成 zombie，再继续执行。这没有实现完整的“父子共享地址空间且父阻塞直到 exec/exit”的 Linux vfork 内部细节，但足以给依赖 vfork 等待语义的用户态提供保守行为。

=== 线程分支：共享 PCB 的任务创建

线程分支处理 musl pthread 常用的 `CLONE_VM | CLONE_THREAD | CLONE_SIGHAND` 子集。它不会创建新的 PCB，而是在当前进程的 `tasks` 表中增加一个 `TaskControlBlock`。新线程继承当前任务的调度属性、CPU 亲和性和信号掩码；trap context 则从当前线程复制，再修补内核栈、系统调用返回值、用户栈和 TLS。

与进程分支不同，线程的用户栈通常由用户态传入。若 `clone3` 提供 `stack` 和 `stack_size`，内核把子线程用户栈指针设为 `stack + stack_size`；legacy clone 则直接使用 `stack`。线程只分配 trap context 映射，不为用户栈另建内核管理的 VMA。

`CLONE_PARENT_SETTID` 和 `CLONE_CHILD_SETTID` 会把新线程的 Linux 可见 tid 写入指定用户地址；`CLONE_CHILD_CLEARTID` 则把清理地址记录到 `clear_child_tid`。线程退出时，内核会把该地址写 0 并执行 futex wake，这是 pthread join 和线程列表锁能够正常工作的关键。

== exec：替换用户态映像

`execve` 的语义与 fork 相反：它不创建新进程，也不改变 PID 和父子关系，而是在当前进程身份下替换用户态程序。CosmOS 的 `sys_execve` 先从用户地址空间读取 path、argv 和 envp；如果 envp 为空，则继承 PCB 中保存的环境变量。随后进入 `resolve_exec_image` 解析执行目标。

执行目标可能是 ELF，也可能是带 shebang 的脚本。解析器先读取文件前缀判断 ELF 魔数；若遇到 `#!`，则提取解释器绝对路径和一个可选参数，按 Linux 规则重写 argv：

```text
interpreter [optional-arg] script-path original-argv[1..]
```

解释器递归最多 4 层，避免脚本循环依赖。最终得到 ELF 字节、重写后的 argv 和绝对 exec_path 后，`ProcessControlBlock::exec` 才开始替换进程映像。

当前 exec 路径要求进程只有一个线程。它先装载新 ELF，构造新的 `MemorySet` 和 `ProcessVmLayout`，然后在 PCB 锁内用新地址空间替换旧地址空间，并更新 exec_path 和 environment。POSIX 要求 exec 后用户自定义信号处理函数恢复为默认处置，而显式忽略的信号保持忽略；内核按这一规则重置 `signal_actions`，并清空进程级 pending signals。

随后，旧地址空间不能在持锁状态下直接销毁。内核把旧 `MemorySet` 转成 deferred reclaim 批次，必要时对已加载旧地址空间的 hart 做 TLB 处理，再释放旧用户页。带 `FD_CLOEXEC` 的 fd 表项也先从表中取出，释放锁后统一 drop。SysV 共享内存附件在 exec 中被 detach。

最后，内核重新为主线程分配用户栈和 trap context，把 argv、envp、auxv、随机字节和字符串按 Linux ELF ABI 放到新用户栈上，重建 trap context，使用户 PC 指向新程序入口，用户 SP 指向初始栈。`execve` 成功后通过普通 trap 返回路径返回 0；用户态实际看到的是新程序从入口点开始执行。

== exit 与资源回收

进程退出路径位于 `exit_current_and_run_next_inner`，它同时处理单线程 `exit`、线程退出和 `exit_group`。退出的第一步总是从调度器的 `Processor.current` 取走当前任务，记录 exit code，把任务标记为 `Zombie`，清除调度状态，并停止当前进程的 CPU 计时。

若当前任务设置了 `clear_child_tid`，内核会先向该用户地址写入 0，再对该地址执行 futex wake。随后清理信号等待、futex 等待和非 futex 定时器，并从 `TID2TASK` 移除 Linux 可见线程号。这里的顺序服务于 pthread 语义：用户态 joiner 可能正阻塞在 child_tid futex 上，它必须在线程资源被完全回收前得到唤醒。

如果退出的是非主线程，且不是 `exit_group`，内核只处理该线程。带 `clear_child_tid` 的线程会从进程任务表中摘除并回收用户资源；传统 `sys_waittid` 语义下的线程则可暂时保留 zombie 任务，等待同进程其他线程回收。无论哪种情况，当前内核栈都必须等上下文切换完成后才能释放，因此退出任务引用会交给 `stop_task` 延迟释放。

如果退出的是主线程，或调用的是 `exit_group`，整个进程进入 zombie 状态。内核会把 `ProcessControlBlockInner.is_zombie` 置真，记录 `exit_reason`，然后处理几类资源：

```text
1. 将所有线程标记为 Zombie，移除等待队列句柄和 TID2TASK 表项
2. 对仍在其他 hart 上运行的线程发送 reschedule IPI，并等待 on_cpu 清除
3. 回收每个线程的 TaskUserRes，包括用户栈和 trap context
4. 取走全部 fd 表项，清空 tasks 表
5. deferred reclaim 用户地址空间
6. 释放 keyring、detach SysV 共享内存、写进程 accounting
7. 把子进程 reparent 到 init
8. 唤醒父进程 wait 队列，必要时 autoreap
```

reparent 是 Unix 进程模型中的重要语义。一个进程退出时，它还没被 wait 的子进程不能失去父进程；CosmOS 把这些子进程的 parent 改成 `INITPROC`，并加入 init 的 children。若其中已经有 zombie，init 会收到退出通知；若父进程对 `SIGCHLD` 设置了忽略或 `SA_NOCLDWAIT`，则内核可以自动回收该 zombie。

退出路径里还有一处与 clone 兼容相关的处理：如果进程是带共享资源标志创建的，退出时会把部分共享状态同步回父进程，例如 fd 表、cwd 和信号处置。这是当前实现对 process-style clone 共享标志的兼容折中；真正的线程共享资源则通过同一个 PCB 自然成立。

== wait 与 zombie 回收

`wait4` / `waitpid` 的对象不是任意进程，而是当前进程的 children。系统调用根据传入 pid 选择匹配规则：`pid == -1` 等待任意子进程，`pid == 0` 等待同进程组子进程，`pid > 0` 等待指定 pid，`pid < -1` 等待指定进程组。若没有匹配子进程，返回 `ECHILD`。

如果找到匹配 zombie，内核从 children 中移除它，按 Linux wait status 编码退出原因：正常 exit 把低 8 位退出码放在 status 的高 8 位；被信号杀死时，低 7 位记录信号编号，若该信号默认动作会 core dump，则置上 `0x80`。随后父进程累加子进程 CPU 时间，从 `PID2PCB` 删除子进程，注销文件映射，最终 drop PCB。

若有匹配子进程但尚未退出，且用户设置了 `WNOHANG`，返回 0；否则当前任务阻塞在自己的 `wait_exit_queue` 上，等待子进程退出时唤醒。阻塞前会检查是否存在会中断等待的信号；被唤醒后则重新扫描 children。这里刻意让“子进程退出状态”优先于 EINTR：如果一次唤醒同时带来了 SIGCHLD 和可回收 zombie，wait 应该先返回子进程状态，而不是丢给用户一个 `EINTR`。

线程等待走另一条较小的接口 `sys_waittid`。它按进程内 tid 索引查找同一 PCB 中的任务，禁止等待自身；若目标线程尚未退出，返回 `EAGAIN`；若已经有 exit code，则从 `tasks[tid]` 取出任务，移除 `TID2TASK`，并在释放进程锁后 drop 用户资源。这一接口比 Linux pthread join 更原始，但为教学用户库提供了直接的线程回收机制。

== 进程上下文接口

除了生命周期系统调用，PCB 还承载了一批进程上下文接口。`getpid` / `getppid` 从 PCB 与 parent 关系中读取；`getpgid`、`setpgid`、`setsid` 操作 `Credentials` 中的 `pgid` 和 `sid`，服务于 shell 作业控制的最小需求；`umask` 更新文件创建掩码；`getuid`、`setuid`、`getgid`、`setgid` 和 capability 相关系统调用操作 `Credentials`，当前默认 init 以 root 凭据启动。

资源限制也存放在 PCB 中。文件描述符分配通过 `nofile` 限制检查可用 fd 槽；地址空间扩展通过 `address_space` 限制检查新增 VMA 大小；`getrlimit`、`setrlimit`、`prlimit64` 等接口在此基础上提供 Linux 兼容查询与设置。进程的 CPU 时间统计由 `enter_user`、`enter_kernel`、`pause_cpu_accounting` 和 `times_snapshot` 协作维护，wait 时还会把已回收子进程的 user/kernel 时间累加到父进程的 child 统计中。

这些接口看似零散，但设计上都遵循同一原则：只要状态属于“进程资源上下文”，就放在 PCB；只要状态属于“某个线程当前执行现场”，就放在 TCB。这样 `fork`、`exec` 和 `exit` 才能明确知道哪些字段应继承、哪些字段应清空、哪些字段应在线程退出时回收。

== 小结

CosmOS 的进程管理以 `ProcessControlBlock` 为中心，把地址空间、文件表、父子关系、信号处置、凭据、资源限制、时间统计和线程集合统一收拢到一个资源容器中。任务调度器只运行 `TaskControlBlock`，而进程管理负责在 `clone`、`exec`、`exit` 和 `wait` 中维护这些任务背后的资源归属。

这一章最重要的设计边界有三条。第一，进程创建必须在 PCB、主线程 trap context、PID 表项和用户栈都准备好之后，才能把任务发布给调度器。第二，exec 替换的是用户态映像，不替换 PID、父子关系和未关闭 fd，但会重置信号处置、清理旧地址空间和重建主线程用户现场。第三，exit 并不等于立即释放 PCB；进程先进入 zombie，保留退出状态供父进程 wait，真正资源回收发生在 wait 或 autoreap 路径中。后续内存管理、文件系统和信号章节都会继续依赖这些生命周期约束。
