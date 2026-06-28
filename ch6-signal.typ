// 第六章：信号、等待队列与 Polling 子系统 —— 由 main.typ 在 `= 信号...` 之后 #include。

本章关注内核中三个紧密耦合的子系统：信号 (signal)、等待队列 (wait queue) 与多路等待 (polling)。它们共同构成了用户态进程与内核之间的“阻塞—唤醒”基础设施——任何一次阻塞型系统调用 (`read`、`wait`、`ppoll`、`futex`、`sigsuspend`)，其本质都是“把当前线程挂到某个等待对象上，直到一个外部事件（数据到达、超时、信号）将它唤醒”。因此，将三者放在同一章中讨论，不仅因为它们共享同一套底层机制，更因为它们的正确性高度依赖于同一组竞态防护。在多 hart (SMP) 环境下，这些防护正是内核设计中最典型、也最易出错的挑战，本章将在最后单辟一节集中论述。

== 设计总览

传统 Linux 用一套“`poll_table` + 每 fd 一条 `wait_queue`”的机制把等待者钉在文件对象上，再用一套与之无关的信号投递机制处理异步通知，二者通过 `signal_pending()` 在每一次可中断睡眠处显式缝合。我们的内核没有照搬这套庞杂的结构，而是提炼出一个统一的设计范式，并用它同时承载信号等待、futex 与 poll 三类需求。

这一范式可以概括为“固定容量的槽注册表 (slot registry) + 代计数器 (generation) + 按键唤醒的等待队列 (keyed wait queue)”。注册表本身是一个静态数组，每个等待申请占用其中一个槽，槽内记录等待者身份、关注的事件以及一个单调递增的代计数器；唤醒路径（驱动、定时器、信号）通过查表找到受影响的槽，把它标记为就绪，再经由全局的 `WaitQueueKeyed` 把对应任务拿出睡眠。代计数器的作用是防止槽复用引发的 ABA 误唤醒：一个已经失效的旧等待，即便它的槽被新的等待重新占用，也会因为代号不匹配而被安全地丢弃。

我们为这一范式实现了三个并行的实例，它们共享几乎相同的结构骨架，却服务于截然不同的语义：

#figure(
  table(
    columns: (1.3fr, 1.7fr, 1.5fr),
    [阻塞场景], [槽注册表], [关注的事件],
    [`ppoll` / `pselect6`], [`POLL_REGISTRY`（fd 行 × poll key 列）], [一组 (fd, 事件) 的就绪],
    [`FUTEX_WAIT`], [`FUTEX_WAIT_REGISTRY`], [某用户字地址的值变化],
    [`rt_sigtimedwait`], [`SIGNAL_WAIT_REGISTRY`], [信号集合中的某个信号到达],
  ),
  caption: [三类“阻塞—唤醒”机制共用同一套槽注册表范式],
)

更一般的、无键的阻塞（管道、终端读、纳秒睡眠、条件变量）则直接落在 `WaitQueue` / `WaitQueueKeyed` 这两个底层原语上。这样的分层带来两个好处：其一，所有阻塞点共用同一条 `block_current_and_run_next` 归宿与同一个 `wakeup_task` 唤醒入口，竞态防护只需在这一层做对一次；其二，信号投递无须了解受害线程具体睡在哪一种队列里，只需借助一个类型擦除的唤醒句柄即可统一处理。

== 等待队列与阻塞原语

=== 数据结构：FIFO 与按键两种等待队列

最底层的 `WaitQueue` 是一个由自旋锁保护的 `VecDeque<Arc<TaskControlBlock>>`，提供 FIFO 的 `wake_one` / `wake_up_to` / `wake_all`。它适合那些“谁先醒并不重要”的场景：管道缓冲区可写后，唤醒排在最前面的那个写者即可。

当唤醒必须*精确命中某个特定等待者*时，例如，Block Device请求中，响应未必按照请求顺序到来，不遵守FIFO的规则。我们使用 `WaitQueueKeyed<T>`。它维护两张表：一个记录等待顺序的键队列，以及一个从键到任务的映射。等待者入队时领取一个键（可以是自动分配的 `u16`，也可以是由调用方指定的选定键），随后 `wake_selected(key)` 便能把这一个键对应的任务、且仅仅这一个任务唤醒。Poll 与 futex 的全局等待队列都是以 `u16` 为键的 `WaitQueueKeyed`，其键被编码为 `generation << 8 | index`，从而把注册表的代计数器与队列的唤醒键绑在一起。

=== 类型擦除的唤醒句柄

信号投递面临一个结构性难题：当一个信号到达时，受害线程可能正睡在管道队列、终端队列、poll 全局队列或 futex 队列中的任意一个上，而这些队列的泛型参数各不相同。若让任务控制块直接持有这些队列的引用，势必引入 trait 对象或把泛型污染到任务结构里。

我们的解法是一个类型擦除的句柄 `WaitQueueHandle`，它只保存一个裸指针与两个函数指针：

```rust
pub struct WaitQueueHandle {
    ptr: *const (),
    wake_fn:   fn(ptr: *const (), task: &Arc<TaskControlBlock>),
    remove_fn: fn(ptr: *const (), task: &Arc<TaskControlBlock>),
}
```

任务入睡时，把所在队列生成的句柄记录在 `current_wq_handle` 字段上；信号投递时，无论受害者睡在何处，都能调用 `handle.wake_waiter(task)` 让该队列“把这个任务从队中摘下并唤醒”，调用 `remove_waiter` 则只摘下不唤醒。这种设计把“谁在哪条队列上”的知识完全留在等待队列模块内部，对外只暴露一对与类型无关的操作，既避免了运行时多态的开销，也让信号路径与等待队列的具体实现彻底解耦。

上述数据结构可以表示为下面的示意图：

#figure(image("assets/wait_queue.svg", width: 90%), caption: [等待队列与唤醒句柄示意图])

=== 防丢失唤醒：注册、复查、取消三段式

阻塞型同步最经典的 bug 是“丢失唤醒”：等待者检查条件发现尚未就绪，正要入睡之际，唤醒者恰好抢先发出了通知，于是这一次通知被丢弃，等待者永远沉睡。我们用一个“先把自己入队，再复查条件，最后决定是否真的切换”的三段式流程关闭这一窗口：

```rust
pub fn wait_with_reason_or_skip<F>(&self, reason, should_skip: F) {
    let task = self.prepare_to_wait(reason); // 入队，状态置 Interruptible
    if should_skip() {                        // 复查：条件是否已满足
        self.cancel_prepared_wait(&task);  // 已就绪：留在本 hart 继续运行
        return;
    }
    self.block_prepared(task, reason);        // 仍未就绪：才真正交出 CPU
}
```

`prepare_to_wait` 把任务状态置为 `Interruptible` 并记下等待原因与句柄，然后才入队。关键在于 `should_skip` 这个闭包总是在入队*之后*才被调用，因此无论唤醒者在哪一个瞬间到达，它要么看到任务已在队列中（从而正确唤醒），要么等待者本身的复查会捕获到已就绪的条件（从而取消睡眠）。这一模式被同时用于通用 `WaitQueue`、键控 `WaitQueueKeyed`、poll 以及信号等待，是整套机制正确性的基石。

为防止强制退出与多条唤醒路径竞争时在队列里残留过期的强引用，所有清理操作（如 `remove_waiter_by_ptr`）都被设计成幂等的：重复移除同一个任务不会出错，从而保证队列在任何竞态下都不会泄漏。

=== 批量迁移与 requeue 的锁序

Futex 的 `FUTEX_REQUEUE` / `FUTEX_CMP_REQUEUE` 需要把一批等待者从一条队列唤醒，剩余的原子地搬到另一条队列。这涉及对两条队列同时加锁，若顺序不一致便会死锁。我们在 `wake_and_requeue` 中强制按队列地址的固定顺序获取两把锁（地址较小者先锁），从而把一个潜在的锁环彻底拆掉。同时，被迁移任务的 `current_wq_handle` 也被原子地切换到目标队列的句柄，保证后续的信号唤醒仍然能正确定位。

== 信号子系统

=== 信号表示与两级挂起

内核用一个 64 位位图 `SignalBit` 表示信号集合，第 `n` 号信号对应位 `1 << (n - 1)`，与 Linux 的 `sigset_t` 低 64 位布局完全一致。每个信号携带一个 `SigInfo`，其 `si_signo`、`si_code`（区分 `SI_USER` / `SI_TKILL` / `SI_KERNEL`）、`si_pid`、`si_uid` 等字段按 64 位 Linux ABI 的偏移摆放，固定 128 字节，以兼容 glibc和musl。`SignalAction` 则记录一个信号的处置：

```rust
pub struct SignalAction {
    pub handler:     usize, // 用户处理函数地址，或 SIG_DFL / SIG_IGN
    pub sa_flags:    u32,  // SA_SIGINFO / SA_RESTART / SA_NODEFER / ...
    pub sa_restorer: usize,
    pub sa_mask:     u64,   // 处理函数执行期间额外屏蔽的信号
}
```

挂起 (pending) 的信号分两级存放：进程级 `pending_signals` 与每个线程的 `pending_signals`，各自配一份 `pending_siginfo` 数组。投递到“进程”的信号进入进程级集合，由抢先到达trap返回点的任一未屏蔽线程取走并执行处理函数；投递到“线程”的信号（`tkill` / `tgkill`）只进入该线程的集合。每个线程还维护一个 `signal_mask` 屏蔽字与一个 `signal_mask_backup` 备份字，后者服务于 `sigsuspend` 与 `rt_sigreturn` 对掩码的原子切换与还原。与 Linux 一致，`SIGKILL` 与 `SIGSTOP` 被视为不可屏蔽，任何试图把它们设入掩码的操作都会被 `without_unblockable()` 静默剔除。

=== 投递入口：kill 家族与终端信号

所有用户态投递入口——`kill`、`tkill`、`tgkill`、`pidfd_send_signal`——最终都汇聚到两个核心函数：`add_signal_to_process_with_siginfo` 与 `add_signal_to_task_with_siginfo`。它们的职责是置位挂起位、填入 siginfo，然后唤醒那些“当前能收到该信号”的线程。一个被屏蔽的信号不会唤醒任务，它只是静静地挂起，等待未来某次 `sigprocmask` 解除屏蔽后再被投递。

终端产生的信号走另一条路径。终端行规程在识别到 `Ctrl+C`、`Ctrl+\`、`Ctrl+Z` 等控制字符时，调用 `deliver_foreground_signal`，经 `send_signal_to_pgrp` 把 `SIGINT` / `SIGQUIT` / `SIGTSTP` 投递给控制终端的前台进程组。这正是 shell 中一次 `Ctrl+C` 能中断整个前台任务的机制。`kill(-pgrp, sig)` 的负 pid 语义也复用同一条 pgrp 广播路径，并且，与 Linux 一致，1 号进程 (init) 被特别保护：除存在性探测 (signal 0) 外，它不会被 `kill` 杀死。

下面的流程图展示了一个进程把信号投递给另一个进程的一般路径：

#figure(image("assets/signal_add.pdf"), caption: [信号投递路径示意图])

=== 投递策略与 EINTR 判定

信号的“投递”并不发生在它被置位的那一刻，而是发生在受害线程下一次准备返回用户态时。在trap处理的尾部，内核调用 `check_signals_of_current` 扫描挂起集合，按照处置分三类处理：`SIG_IGN` 直接清位丢弃；`SIG_DFL` 下的致命信号触发进程终止（并在 `wait` 状态中置上 core-dump 位），非致命的默认处置则清位跳过；只有装设了用户处理函数的信号，才被取出并转入栈帧构造。

阻塞型系统调用被信号中断后应否返回 `EINTR`，是一个微妙的语义问题。我们实现了 `has_interrupting_signal` 这个谓词，严格对齐 Linux `signal_pending()` 对可重启调用的判定：只有“确实会被采取行动”的信号才构成中断——即装设了用户处理函数的信号，或默认处置为终止 / 停止的信号；而那些默认处置为“忽略”的信号（`SIGCHLD`、`SIGURG`、`SIGCONT`、`SIGWINCH`），或被显式 `SIG_IGN` 的信号，即便处于挂起状态也不会把阻塞读取打断成 `EINTR`。这个谓词正是终端行规程把一次 `Ctrl+C` 引发的唤醒转化为读取错误返回的依据。

=== 信号栈帧与体系结构抽象

装设了用户处理函数的信号，由 `handle_signals` 在用户栈上构造一个 Linux 风格的信号帧。该函数备份当前trap上下文，在用户栈上依次预留 `ucontext_t` 及（若设置了 `SA_SIGINFO`）`siginfo_t`，把备份的机器现场与旧掩码写入 `ucontext_t`，最后改写trap上下文：把用户 `PC` 指向处理函数，把返回地址 (`ra`) 指向用户提供的 `sa_restorer` 或内核 vDSO 中的 `rt_sigreturn` 跳板，并按 `SA_SIGINFO` 与否决定传入一个或三个参数。进入处理函数前，当前信号会被临时并入掩码（除非设置了 `SA_NODEFER`），`sa_mask` 指定的信号也一并屏蔽。`rt_sigreturn` 则完成反向操作：从栈上读回 `ucontext_t`，还原寄存器与掩码。

值得强调的是，整个栈帧构造把“字节布局”与“投递策略”刻意分开：通用代码拥有掩码、挂起、EINTR、重启等一切策略，而每种体系结构只通过 `SignalAbi` trait 提供自己的 `ucontext_t` 与 `rt_sigaction` 的字节布局，以及构造、还原上下文的钩子。这使得 RISC-V 与 LoongArch64 两套截然不同的信号 ABI 得以共用一套经过充分测试的投递逻辑。

=== 系统调用重启

请看下面这一个示例用户态程序：

```rust
#[macro_use]
extern crate user_lib;
extern crate alloc;

extern "C" fn on_alarm(_sig: i32) {
    println!("got SIGALRM");
}

#[no_mangle]
fn main() {
    let mut fds = [0i32; 2];
    if pipe(&mut fds) < 0 {
        println!("pipe failed");
        return;
    }

    let action = SignalAction {
        handler: on_alarm as usize,
        sa_flags: 0x1000_0000, // SA_RESTART
        sa_mask: 0,
    };

    if sigaction(SIGALRM, Some(&action), None) < 0 {
        println!("sigaction failed");
        return;
    }

    let pid = fork();
    if pid == 0 {
        println!("Child: sleeping for 2 seconds before writing");
        sleep(2000);
        println!("Child: writing to pipe");
        let n = write(fds[1] as usize, b"ok");
        println!("Child: write returned {}", n);
        return;
    }

    let timer = Itimerval {
        it_value: TimeVal { sec: 1, usec: 0 },
        it_interval: TimeVal { sec: 0, usec: 0 },
    };
    let _ = setitimer(ITIMER_REAL, Some(&timer), None);

    let mut buf = [0u8; 8];
    println!("Parent: going to read");
    let n = read(fds[0] as usize, &mut buf);
    println!("read returned {}", n);
}

```

在这个例子中，父进程的 `read` 预计在子进程醒来、完成写入以后才能完成（预计在2s以后），但是它在阻塞等待的过程中会被1s的timer打断。但因为设置了`SA_RESTART`，所以父进程的 `read` 应该在处理完 `SIGALRM` 信号后自动重启，而不是返回 `-EINTR`，直到正确读取到子进程写入的数据。

当一个被 `SA_RESTART` 标记的处理函数打断了一次本可重启的系统调用时，内核不应让用户态看见 `EINTR`，而应在处理函数返回后自动重新发起该调用。我们的实现利用trap上下文中预存的两条信息完成这件事：原始的第一参数 `orig_a0`，以及“本次trap是否处于系统调用之中”的标志。若发现当前返回值恰为 `-EINTR` 且调用本身被标记为可重启，便在写入 `ucontext_t` 之前把保存的 `PC` 回退一条 `ecall` / `syscall` 指令的长度，并把 `a0` 还原为 `orig_a0`；于是 `rt_sigreturn` 之后，用户态将“重新踩中”那条系统调用指令，从而实现透明重启。

=== sigsuspend 与 sigtimedwait

`sigsuspend` 原子地替换信号掩码并挂起，直到有信号抵达，它必然以 `-EINTR` 返回。这里有一处刻意的设计：它不把自己排入与 `waitpid` 共享的等待队列，而是直接以 `Interruptible` 状态阻塞。原因在于，若共享队列，则子进程退出时发出的 `wake_one` 会被 `sigsuspend` 偷走，反而让真正的 `waitpid` 等待者错失唤醒。

`rt_sigtimedwait` 的语义更强：它不仅等待，还要*同步消费*一个挂起的信号。它在 `SIGNAL_WAIT_REGISTRY` 中注册一个槽，关注用户给出的信号集合，随后阻塞；任何向该进程投递的、落入集合的信号，都会经 `notify_signal_wait_pid` 把槽标记为就绪并唤醒。任务醒来后调用 `take_pending_signal_in_set` 真正从挂起集合中*摘除*该信号并把其 siginfo 回交给用户，从而实现“等到并取走”的语义，而非让它走普通的处理函数路径。

== Polling 子系统

Poll的基本语义是：用户态提供一组 (fd, 事件) 兴趣，表示希望监听某些fd的事件变化，内核阻塞等待，直到其中任意一个 fd 就绪或超时。它的特点在于“一对多”的映射：如果要精准唤醒，只要多个条件中的任意一个满足即触发。下面我们将详细介绍这一机制。

=== 二维位图注册表

多路等待的实现是本内核中最具特色的部分。传统做法是让每个被等待的文件对象各自持有一条等待队列，`poll` 时把等待者钉到所有关心的 fd 的队列上，这样既需要为每种文件类型内嵌队列，又难以在一处统一管理，“移除其他fd队列中包含的等待标记”是一个难点。我们没有采用这种分散式结构，而是用一个固定容量的二维位图注册表 `POLL_REGISTRY` 集中描述所有的等待关系：

```rust
struct PollRegistry {
    kernel_slots: [KernelFdSlot; 128], // 每个 (pid, fd, source_id) 兴趣占一行
    key_slots:    [PollKeySlot;  128], // 每次 ppoll 等待占一个 key 列
}
struct KernelFdSlot {
    source_id:   usize,
    key_bits:    u128, // 哪些 key 在等待本 fd（任意事件）
    key_bits_in: u128, // 哪些 key 关心可读
    key_bits_out:u128, // 哪些 key 关心可写
}
struct PollKeySlot {
    generation: u8,
    state:      PollKeyState, // Free / Active / Ready / TimedOut
    task_ptr:   usize,
    rows_mask:  u128,         // 本 key 关心哪些 fd 行
}
```

注册表的两个维度分别是“fd 行”和“poll key 列”。一次 `ppoll` 调用对应一个 key，它关心若干个 (fd, 事件) 兴趣；每个兴趣占据一个 fd 行，行内用三个 `u128` 位图标记有哪些 key 在等它、其中哪些等可读、哪些等可写。反过来，每个 key 用一个 `rows_mask` 记录自己挂在哪些行上。这样一来，“某个数据源就绪了，该唤醒谁”就退化成一组位与运算：扫描属于该 source 的所有行，把命中的 key 位收集起来，标记就绪并唤醒即可。整个结构全部静态分配，配一把全局自旋锁，既没有 per-fd 的队列分配，也不需要遍历链表。下面的示意图展示了注册表的二维位图结构：

#figure(image("assets/poll_bitmap.svg", width: 100%), caption: [二维位图注册表示意图])

=== 事件源标识与 File::poll

注册表用 `source_id` 把一个 fd 与它背后的“就绪源”绑定。每个实现了 `File` trait 的对象都提供两个方法：`poll(events)` 做一次电平检测（此刻是否可读 / 可写），返回已就绪的事件子集；`poll_source_id()` 返回该对象作为事件源的身份。后者的缺省实现就是对象自身的地址 `self as *const Self`，这样既唯一又无需额外分配 id；管道则把读写两端的 source 都指向共享环形缓冲区的 `Arc` 指针，使得任一端的状态变化都能唤醒关心它的等待者。当驱动、文件系统或协议栈改变了某个对象的就绪状态时，它们只需调用一句 `notify_poll_source(source_id, ready_mask)`，剩下的查表、标记、唤醒全部由注册表统一完成。

=== 注册、就绪通知与超时

`notify_poll_source` 是整个机制的唤醒入口。它在锁内扫描属于该 source 的行，按就绪类型（可读、可写、错误 / 挂起）取出相应的 key 位图，把这些 key 标记为 `Ready` 并收集它们的等待键；随后*释放锁*，再用收集到的键逐个调用 `wake_selected`。“先收集、后在锁外唤醒”是一条重要的纪律：它把可能触发调度与重入的唤醒动作挪出自旋锁临界区，既缩短了持锁时间，也避免了唤醒路径反向重入注册表导致的死锁。

超时由定时器子系统配合完成。`ppoll` 注册等待时会领取一个携带代计数器的 `PollTimerTag`，把它绑在一个绝对截止时间的定时器堆项上。定时器到期时回调 `handle_poll_timeout`：若该 key 仍有效、仍属于本任务、且仍处于 `Active` 态，便将其置为 `TimedOut` 并唤醒，同时清掉它在各 fd 行上的位。代计数器保证了即便一个早已注销的旧定时器迟到，也会因为代号不匹配而被安全忽略。

=== ppoll / pselect6 主循环与回退路径

整个 `ppoll` 由一个紧凑的循环驱动：先用 `scan_pollfds` 做一轮电平扫描，若已有 fd 就绪则直接返回计数；若发现未屏蔽的挂起信号则返回 `EINTR`；若已过截止时间则返回 0；否则才注册等待、武装定时器、阻塞。醒来后根据 `PollWakeState` 区分是被就绪唤醒还是超时，然后回到循环顶部重新扫描——这一次重扫描是必要的，因为电平触发的语义要求我们以 *当前* 的实际就绪状态为准，而不是信任唤醒通知。

注册表的容量是有上限的（128 行、128 列）。当并发的 `ppoll` 过多致使键或行耗尽时，我们不选择直接失败，而是落入一条回退路径：以 `Interruptible` 状态进行一次短周期的定时睡眠，醒来后重新扫描 fd 集合。这样既避免了把 `ENOSPC` 这种内部容量限制暴露给用户态，也没有引入忙等。`pselect6` 在内核中被翻译成等价的 pollfd 数组走同一条循环，并且支持在等待期间临时替换信号掩码——这一“原子地屏蔽—等待—还原”的能力正是 `pselect` 相对“先 `sigprocmask` 后 `select`”的全部价值所在。

=== poll的规模限制与 epoll 的范围取舍

正如上面所说，注册表的容量是有限的：每个进程最多 128 个 fd，每个 fd 最多 128 个等待者。对于大多数 shell、终端、协议栈等工作负载，这个规模已经足够；作为一种权衡，bitmap法具有很快的线性扫描速度，并且当前规模下占用空间十分可控。对于更复杂的polling功能，使用扩展位图亦或是其他数据结构，仍然有待研究。

我们实现了完整的 `poll` / `ppoll` / `pselect6`，但 `epoll` 家族中只提供了 `epoll_create1`：它仅分配一个匿名 fd 以取悦 glibc 的初始化路径，而 `epoll_ctl` / `epoll_wait` 背后那套“兴趣集 + 边沿 / 电平 + 就绪队列”的机器并未实装。这是一个明确的范围取舍：在本内核面向的工作负载下，基于二维位图注册表的 `ppoll` 已经足以高效地支撑事件驱动（例如协议栈的收发与终端输入），而 epoll 的主要收益（海量连接下的 $O(1)$ 就绪通知）在当前规模下并不兑现，却要引入与现有注册表重叠的第二套兴趣机制。因此我们选择把 `poll` 一条路做深做对，把 epoll 留作未来工作。

== 子系统协同：信号如何打断阻塞

三个子系统的真正力量，在于它们协同完成了“异步信号打断同步阻塞”这一 POSIX 的核心承诺。考虑一个正阻塞在终端读取上的 shell：用户按下 `Ctrl+C`，终端中断抵达，行规程识别出中断字符，调用 `deliver_foreground_signal` 向前台进程组投递 `SIGINT`。`add_signal_to_process_with_siginfo` 置位挂起位后，做三件事：通知信号等待注册表（以便唤醒可能正在 `sigtimedwait` 的线程）；调用 `notify_poll_signal_pid` 唤醒该进程所有活跃的 poll key（以便把阻塞在 `ppoll` 上的线程拿出来）；最后调用 `wake_signal_waiters`，借助每个受害线程的 `current_wq_handle` 把它从各自的等待队列里正确摘下并唤醒。

那个阻塞在终端读取上的线程由此被唤醒。它醒来后并不立即返回，而是回到读取路径的条件复查：行规程调用 `has_interrupting_signal`，发现确有一个“会被采取行动”的挂起信号，于是把这次读取转成 `-EINTR` 返回。与此同时，trap返回点的 `handle_signals` 注意到挂起的 `SIGINT`，构造信号帧，把控制权交给用户注册的处理函数。对于设置了 `SA_RESTART` 的场景，栈帧中的重启机制还会在 `rt_sigreturn` 之后让被打断的调用透明地重来。一次按键，便这样贯通了终端、信号投递、等待队列与栈帧构造四个模块。

这里有一处体现分层纪律的细节：`wake_signal_waiters` 在遍历受害线程时，会特意跳过那些正处于“活跃 poll 等待”的线程。因为这些线程的唤醒已经由前一步的 `notify_poll_signal_pid` 经过 poll 自己的键控队列完成了，再用通用句柄唤醒一次既属冗余，也可能干扰 poll 注册表自身的代计数器记账。对其余线程，则优先用 `current_wq_handle` 走“正确摘队”的路径（适用于 futex、管道、条件变量等），只有当线程没有句柄、单纯处于 `Interruptible` 态（如 `sigsuspend`、`nanosleep`）时，才退而使用直接的 `wakeup_task`。这种“按子系统分流”的唤醒策略，确保每条路径都走自己最干净的清理流程。

== SMP 并发与竞态消解

前述的一切——槽注册表、代计数器、三段式等待——在单 hart 下已经足够正确；而真正的设计含量，几乎全部集中在多 hart 下的竞态消解上。我们的内核最多支持 8 个 hart，并以 `cyclictest`（实时延迟基准）与 `iozone`（并发文件 I/O）等典型负载对 SMP 路径进行了反复验证。下面几个竞态是开发过程中实实在在遇到、并被逐一修复的，它们集中体现了本章子系统的设计权衡。

=== 唤醒与阻塞之间的竞态

阻塞与唤醒并非两个原子操作。当一个线程决定阻塞时，`take_current_task` 会先清除“本 hart 当前任务”这个字段，但它的 `on_cpu` 标志要等到 `__switch` 真正保存完寄存器、本 hart 回到 idle 循环后，才由 `finish_pending_task_release` 清除。于是存在一个“半阻塞”窗口：`processor.current` 已经为空，但 `on_cpu` 仍然为真，而此刻该任务的上下文还没保存完毕。若一个远程 hart 在此窗口内调用 `wakeup_task`，把这个尚未保存完的任务入队，便可能让另一个 hart `__switch` 进入一个半损坏的上下文——这就是经典的 SMP 唤醒 / 阻塞竞态。

#figure(image("assets/race_condition_1.svg", width: 95%), caption: [唤醒与阻塞之间的竞态示意图])

我们的解法是“锁无关自旋 + 重验证”：远程唤醒者发现 `on_cpu` 仍为真时，不入队，而是用 `Acquire` 序持续自旋，直到与 `finish_pending_task_release` 中的 `Release` 写入配对、观察到 `on_cpu == false`（此时上下文已安全保存），才把任务入队；入队例程还会在运行队列与任务锁下重新校验 `on_rq` / `on_cpu`，从而安全吸收“自旋期间任务又被别人唤醒或重新投运”这类并发变化。`on_cpu` 之所以被设计成一个独立的无锁原子量，正是为了让远程唤醒者能在不持有任务内部锁的前提下观察这个过渡。

=== 中断原子化的阻塞窗口

上述自旋方案对 *跨 hart* 的唤醒是正确的，却在一个特殊场景下自我死锁：唤醒者与阻塞者是同一个 hart。具体而言，若阻塞窗口没有关中断，那么在 `take_current_task` 之后、`__switch` 之前，一个定时器硬中断可能抢入。中断处理会调用 `wakeup_task` 去唤醒这个正在半阻塞的本地任务，而它发现 `on_cpu` 为真且 `last_cpu` 就是本 hart，于是开始自旋——可悲的是，唯一能清除 `on_cpu` 的 `finish_pending_task_release`，必须等本 hart 回到 idle 循环才执行，而本 hart 此刻正钉死在硬中断里的自旋循环中，永远到不了 idle。结果是一个 100% CPU 的死锁。这正是 `cyclictest` 在调试中暴露的问题。

#figure(image("assets/race_condition_2.svg"), caption: [中断原子化的阻塞窗口示意图])

修复的关键是用 `LocalIrqSave` 守卫，把从 `take_current_task` 到 `schedule` 的整个过渡关在本地中断关闭之内，使得这段期间不可能有同 hart 的硬中断观察到半状态。守卫在析构时（包括任务被重新唤醒之后）还原中断状态。与此同时，我们在 `wakeup_task` 中保留了一道“绊线”：若发现 `last_cpu` 恰等于本 hart 且 `on_cpu` 仍为真（理论上现在已不可达），则直接 `panic` 并打印详情，把一个本会静默挂死的 bug 变成可调试的显式失败。

=== 注册表的代计数器与 ABA

前面提到的三个槽注册表（poll、futex、signal）全部依赖代计数器抵御 ABA。任何“迟到的通知”——一个针对旧等待的超时定时器、一个在等待者已注销后才到达的就绪通知——都会先校验句柄里的代号与槽当前的代号是否一致，不一致便静默丢弃。这在 SMP 下尤其重要：注销与通知完全可以跨 hart 并发，没有代计数器，一个复用了旧槽的新等待就会被旧通知错误地唤醒。配合“先收集、后锁外唤醒”的纪律，整套机制在任意并发注册 / 注销 / 通知的交错下都保持确定性。

=== SpinNoIrqLock 与本地中断

所有的等待队列与注册表都由 `SpinNoIrqLock` 保护。与普通自旋锁相比，它在 `lock` 时额外关闭本地中断，在 `Drop` 时还原。这一选择并非偶然：等待队列的持有者往往会在临界区内修改任务状态，而任务状态又会被本地定时器中断的处理路径读写；若不关中断，一个在持锁期间抢入的硬中断反向重入同一把锁，便会立即自死锁。因此“关中断的自旋锁”不仅是一种优化，更是这套子系统正确性的前提。

=== futex 唤醒优先于挂起信号

`iozone` 这类高并发负载暴露过另一类丢失唤醒：一个正在 futex 上等待的线程，恰好同时收到了一个挂起信号与一次合法的 futex 唤醒。若信号路径抢先把任务拿走并让它走 `EINTR` 返回，那次本应成功的 futex 唤醒就被蚕食了，表现为上层偶发的“等锁等到超时”。我们的处理是让合法的 futex 唤醒优先：当一个 futex 等待槽已被标记为 `Ready` 时，即便此刻也有挂起信号，任务也会先消费这次唤醒，而不让信号把它强行中断。这体现了一条总原则：阻塞型同步的“正常唤醒”不应被异步信号静默吞噬。

== 权衡与展望

回顾整套设计，最核心的取舍在于用“集中式槽注册表 + 代计数器 + 键控等待队列”这一统一范式取代了传统的“每 fd 一条等待队列”。这带来了三个收益：所有阻塞点共享一条正确性经过充分验证的唤醒 / 阻塞通路；信号投递借助类型擦除句柄与任意等待队列解耦；三类并发等待（poll、futex、signal）复用同一套 ABA 防护。代价同样清晰：注册表的固定容量设定了并发等待数的上限（尽管我们用回退路径把这一限制对用户态隐藏了），并且这种集中式结构在海量连接下不及 epoll 的就绪队列高效。

在这一基础上，仍有若干可改进之处。首先，实时信号（32 号以上）目前在位图层面已预留，但 `SignalNum` 枚举尚未对其建模，siginfo 的联合体负载也只保留了发送方字段，未覆盖 `SI_TIMER`、`SI_SIGIO` 等内核来源的完整语义。其次，`sigaltstack`（备用信号栈）目前只接受并校验参数而未真正投入使用，`SA_ONSTACK` 的语义因此尚未兑现。再者，epoll 仅以 `epoll_create1` 占位，若未来工作负载转向大规模网络服务，可以复用现有的 `source_id` 与 `notify_poll_source` 接口，在注册表之上增设一层“兴趣集 + 就绪队列”来实装边沿 / 电平触发的 epoll。最后，`poll_source_id` 以对象地址为身份，虽然在文件生命周期内安全，但仍可考虑引入显式的代计数器或稳定 id，以在极端的地址复用场景下进一步收紧安全边界。这些都是在不动摇现有范式的前提下，可以渐进推进的方向。
