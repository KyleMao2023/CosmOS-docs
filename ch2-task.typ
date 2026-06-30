// 第二章：任务调度 —— 由 main.typ 在 `= 任务调度` 之后 #include。

本章关注 CosmOS 的任务调度子系统。调度器处在内核控制流的中心：用户程序通过 trap 进入内核，内核在系统调用、中断、阻塞等待或信号返回等节点上重新评估当前任务是否还能继续运行；一旦需要切换，调度器负责保存当前任务的内核态上下文，选择另一个可运行任务，并把 CPU 控制权交给它。换言之，调度器并不只是一个“队列选择算法”，它同时定义了任务生命周期、阻塞—唤醒语义、跨 hart 迁移和上下文切换的正确边界。

CosmOS 的调度实现位于 `os/src/sched/`，任务对象定义位于 `os/src/task/`。两者刻意分层：`task` 模块描述“任务是什么”，包括内核栈、trap 上下文、所属进程、等待原因和信号状态；`sched` 模块描述“任务如何被运行”，包括 per-hart 运行队列、调度策略、抢占请求和汇编上下文切换。这样的划分使进程管理、文件系统阻塞、futex、poll、信号与定时器都能复用同一套调度入口，而不需要各自实现私有的切换逻辑。

从策略上看，CosmOS 没有停留在最简单的 FIFO 调度器，而是实现了一个 Linux 风格的多调度类框架：实时任务支持 `SCHED_FIFO` 与 `SCHED_RR`，普通任务使用 CFS 风格的虚拟运行时间，用户态可以通过 `sched_*`、`setpriority` 和 `sched_setaffinity` 等系统调用改变调度属性。每个 hart 拥有一条本地运行队列，timer 与 IPI 只提出重新调度请求，真正切换统一发生在明确的安全点。

== 设计总览

传统的简易内核常把调度器写成一个全局就绪队列：任务阻塞时从队列中消失，唤醒时再放回队尾，时钟中断到来时取下一个任务运行。这种模型足以解释协作式调度，却难以支撑三个现实需求。第一，Linux 用户态要求 nice、实时优先级、时间片、CPU 亲和性等接口具有可观察语义；第二，多 hart 环境下，一个全局队列会让所有 CPU 在每次调度时争用同一把锁；第三，阻塞与唤醒可能发生在不同 hart 上，若没有清晰的“任务是否仍在 CPU 上”的状态，远端 hart 可能切入一个寄存器尚未保存完成的任务。

CosmOS 因此采用“per-hart 调度器 + 多调度类 + 延迟抢占”的结构。每个 hart 有一个 `Processor` 保存当前任务和 idle 上下文，有一个 `RunQueue` 保存该 hart 的可运行任务。实时任务进入按优先级划分的 FIFO 队列，普通任务进入以虚拟运行时间排序的 CFS 队列。timer 中断、软件中断和唤醒路径只设置 `resched_reason`，等当前 trap 即将返回用户态时再调用 `schedule_if_needed` 完成切换。

可以把整个调度循环概括为下面的路径：

#image("/assets/scheduler_path_bluegreen.png")

这一流程有一个重要特征：调度器自己的控制流是显式存在的。任务之间不是直接互相跳转，而是统一切回每个 hart 的 idle 调度上下文，再由 idle loop 选择下一项工作。这让任务退出、内核栈释放、阻塞取消和跨 hart 唤醒都更容易推理。

== 核心数据结构

=== Processor：每个 hart 的调度控制流

`Processor` 是每个 hart 独有的调度状态。它记录当前正在本 hart 上运行的任务、idle 调度上下文，以及一个用于延迟释放的任务引用：

```rust
pub struct Processor {
    current: Option<Arc<TaskControlBlock>>,
    pending_task_release: Option<Arc<TaskControlBlock>>,
    idle_task_cx: TaskContext,
}
```

`current` 是“任务正在 CPU 上运行”的权威归属。只要一个任务在某个 hart 的 `current` 中，它就不能同时出现在任何运行队列里。`idle_task_cx` 则是该 hart 的调度器栈帧：当前任务让出 CPU 时，`__switch` 把寄存器保存到任务自己的 `TaskContext`，然后恢复 `idle_task_cx`，于是控制流回到 `run_tasks` 循环。

`pending_task_release` 解决的是退出路径上的内核栈生命周期问题。一个任务调用 `exit` 时，当前 CPU 仍然运行在这个任务的内核栈上；如果此时立刻释放任务对象或内核栈，接下来的 `__switch` 就会踩在已经回收的栈上。因此，退出任务会被当前 hart 临时持有，等切回 idle 控制流、确认这条内核栈不再被执行后，再释放引用。

=== TaskControlBlock：调度实体

`TaskControlBlock` 是调度器看到的最小执行实体，也就是线程。它通过弱引用指向所属进程，拥有自己的内核栈和任务内部状态，并带有一个原子位 `on_cpu`：

```rust
pub struct TaskControlBlock {
    pub process: Weak<ProcessControlBlock>,
    pub kstack: KernelStack,
    inner: SpinNoIrqLock<TaskControlBlockInner>,
    pub on_cpu: AtomicBool,
}
```

`on_cpu` 是 SMP 阻塞—唤醒正确性的核心。任务被选中运行时，调度器把它设为 `true`；任务切出时，不能在调用 `__switch` 之前清除它，因为此时寄存器还没有保存到 `TaskContext` 中。只有当原 hart 已经回到 idle loop，确认保存动作完成后，才以 Release 语义清除 `on_cpu`。远端唤醒者若观察到 `on_cpu == true`，必须等待它变为 `false` 后再入队，从而避免把一个半保存的上下文交给另一个 hart 运行。

任务生命周期由 `TaskStatus` 描述：

#figure(
  table(
    columns: (1.2fr, 2.8fr),
    [状态], [含义],
    [`Running`], [正在某个 hart 上运行，是该 hart 的 `Processor.current`。],
    [`Runnable`], [可以运行，通常已经在运行队列中，或正在切出后等待重新入队。],
    [`Interruptible`], [可中断睡眠，等待普通事件、超时或信号唤醒。],
    [`Uninterruptible`], [不可中断睡眠，只应由等待事件本身唤醒。],
    [`Zombie`], [任务已经退出，不能再次被调度。],
  ),
  caption: [任务生命周期状态],
)

这里需要区分三个状态位的职责：`task_status` 描述任务语义状态，`sched.on_rq` 描述任务是否已经挂入某条运行队列，`on_cpu` 描述任务的寄存器现场是否仍归某个 hart 所有。三者共同构成调度器的不变量基础。

=== TaskSchedState：调度私有状态

任务的调度属性和运行队列状态集中在 `TaskSchedState` 中。它既包含用户态可见字段，也包含调度器内部字段：

```rust
pub struct TaskSchedState {
    pub last_cpu: usize,
    pub on_rq: bool,
    pub policy: SchedPolicy,
    pub linux_policy: i32,
    pub rt_priority: u8,
    pub time_slice_ticks: u32,
    pub remaining_slice_ticks: u32,
    pub nice: i32,
    pub weight: u64,
    pub vruntime_ns: u64,
    pub exec_start_ns: u64,
    pub cfs_slice_start_ns: u64,
    pub cfs_rq_key: Option<(u64, usize)>,
    pub resched_reason: Option<ReschedReason>,
    pub cpu_affinity_mask: usize,
}
```

`last_cpu` 是唤醒和定时器选择目标 hart 的默认依据；`on_rq` 防止重复入队；`resched_reason` 表示当前任务应在安全点离开 CPU；`cpu_affinity_mask` 用位图限制任务可以运行在哪些 hart 上。普通任务还维护 `vruntime_ns`、`weight`、`exec_start_ns` 等 CFS 统计字段，实时任务则主要使用 `rt_priority` 和 `remaining_slice_ticks`。

== 调度策略

CosmOS 当前支持三类可运行任务策略：`SCHED_FIFO`、`SCHED_RR` 与 `SCHED_OTHER`。内部还有一个 `SchedPolicy::Idle`，只表示 idle 调度上下文，不作为普通任务入队。

=== 实时调度类

实时任务的优先级范围是 1 到 99，数值越大优先级越高。每个 `RunQueue` 为实时调度类维护 100 个 `VecDeque`，并用 `highest_rt_prio` 缓存当前最高非空优先级。选择任务时，调度器总是先检查实时队列；只要存在实时任务，普通 CFS 任务就不会被选中。

`SCHED_FIFO` 的语义是“高优先级先运行，同优先级 FIFO”。一个 FIFO 任务一旦获得 CPU，不会因为时间片耗尽而被同优先级任务轮转；它只会在主动阻塞、主动让出、退出，或更高优先级任务进入运行队列时离开 CPU。timer tick 对 FIFO 任务只做一件事：检查本 hart 是否已有更高优先级实时任务可运行，若有则设置 `HigherRtPriority`。

`SCHED_RR` 在 FIFO 的基础上增加同优先级轮转。每个 RR 任务有 `remaining_slice_ticks`，默认时间片为 10 个周期 tick。timer tick 到来时，内核递减该字段；当时间片耗尽且本 hart 上存在同等或更高优先级实时任务时，当前任务以 `RrTimesliceExpired` 原因切出并重置时间片。如果没有竞争者，任务只重置时间片并继续运行。

实时调度还保留一个细节：任务重新进入实时队列时，默认插入队尾；但当调度属性变化需要维护 Linux 的优先级调整语义时，内核可以通过 `rt_enqueue_head` 让下一次入队插入队头。这避免了策略切换和优先级调整破坏实时队列的可预期顺序。

=== CFS 风格公平调度类

普通任务采用 CFS 风格的虚拟运行时间。每个 hart 的 CFS 队列是一个 `BTreeMap<(vruntime_ns, task_ptr), Arc<TaskControlBlock>>`，调度器总是选择最左侧，也就是 `vruntime` 最小的任务。把任务指针放进 key 中，是为了让两个任务拥有相同虚拟运行时间时仍有稳定的排序。

CFS 的直觉是：每个普通任务都在一条“公平时间轴”上前进，谁走得最少，谁就应该先运行。真实运行时间会按照 nice 权重折算成虚拟运行时间：

```text
delta_fair = delta_exec * NICE_0_LOAD / weight
vruntime  += delta_fair
```

nice 值越小，权重越大，同样运行 1ms 增加的 `vruntime` 越少，于是它更不容易被认为“已经用得太多”。CosmOS 使用 Linux 的 `prio_to_weight` 表，把 nice 限制在 `[-20, 19]`，nice 0 对应权重 `1024`。

调度器还维护几个 CFS 常量：

#figure(
  table(
    columns: (1.8fr, 1.2fr, 2.2fr),
    [常量], [当前值], [作用],
    [`CFS_TARGET_LATENCY_NS`], [`24 ms`], [期望一轮可运行普通任务都获得运行机会的目标窗口。],
    [`CFS_MIN_GRANULARITY_NS`], [`3 ms`], [单个任务的最小运行粒度，避免任务很多时频繁切换。],
    [`CFS_WAKEUP_GRANULARITY_NS`], [`1 ms`], [唤醒抢占的容忍窗口，避免 `vruntime` 很接近时反复抢占。],
    [`CFS_YIELD_PENALTY_NS`], [`3 ms`], [`sched_yield` 对普通任务追加的虚拟时间惩罚。],
  ),
  caption: [CFS 风格调度参数],
)

普通任务被唤醒时，调度器并不会简单沿用它很久以前的 `vruntime`。若睡眠时间很长，旧值可能远小于当前队列的 `min_vruntime`，直接入队会让该任务获得过大的补偿。CosmOS 使用如下规则放置被唤醒任务：

```text
placed_vruntime = max(old_vruntime, min_vruntime - CFS_WAKEUP_GRANULARITY_NS)
```

这相当于给短睡眠的交互型任务一点响应优势，但不允许长期睡眠任务无限“攒优先级”。当新唤醒任务的 `vruntime` 明显小于当前运行任务时，唤醒路径会设置 `CfsPreempt`，让当前任务在安全点切出。

=== Deadline 属性的兼容处理

Linux 还定义了 `SCHED_DEADLINE`，但它需要 EDF/CBS 一类更复杂的实时调度机制。CosmOS 当前并不实现 deadline 调度类；系统调用层只校验 `runtime <= deadline <= period` 等基本合法性，并把 deadline 相关字段保存为用户可读属性，实际执行仍落在普通公平调度类下。这样做的目的不是声称支持 deadline 实时性，而是让用户态兼容性测试能观察到合理的 `sched_getattr` 行为。

== 运行队列

每个 hart 的 `RunQueue` 同时保存实时队列和 CFS 队列：

```rust
struct RunQueue {
    rt_queues: [VecDeque<Arc<TaskControlBlock>>; RT_QUEUE_LEVELS],
    highest_rt_prio: Option<u8>,
    rt_nr_running: usize,
    cfs_tasks: BTreeMap<(u64, usize), Arc<TaskControlBlock>>,
    cfs_nr_running: usize,
    cfs_load: u64,
    min_vruntime_ns: u64,
    stop_task: Option<Arc<TaskControlBlock>>,
}
```

`pick_next_task` 的选择顺序非常直接：先从最高优先级实时队列取任务；若没有实时任务，再取 `vruntime` 最小的 CFS 任务；若本 hart 完全没有普通任务，则尝试从其他 hart 窃取一个亲和性允许的 CFS 任务。当前实现只窃取普通任务，不窃取实时任务，因为实时任务的优先级语义和唤醒延迟比负载均衡更重要。

入队时，`enqueue_task_on(task, preferred_hart)` 会根据任务的 CPU 亲和性和当前 online hart 集合选择目标 hart。实时任务倾向于留在 preferred hart；如果该 hart 已不在亲和性集合内，则选择集合中的第一个 hart。普通任务会做更积极的轻量负载分配：若 preferred hart 可用且为空，就直接使用；否则扫描允许的 hart，选择 `(cfs_load, cfs_nr_running)` 最小者。这里使用 `cfs_load` 而不只是任务数量，是因为 nice 权重不同的普通任务对 CPU 的需求并不相同。

跨 hart 唤醒依赖 IPI。若新入队任务的目标 hart 是当前 hart，调度器可以直接比较它与当前任务并设置 `resched_reason`；若目标 hart 是远端 hart，则调用 `send_ipi_mask` 唤醒远端。远端 hart 的软件中断处理函数并不直接切换，只清除 IPI 并设置重新调度请求。若远端 hart 正在 idle，它会被 IPI 从 `wfi` 中唤醒；若正在运行用户任务，则会在 trap 尾部进入调度判断。

== 上下文切换

CosmOS 的上下文切换分成两层：trap 层保存用户态完整现场，scheduler 层保存内核态 callee-saved 现场。用户寄存器、用户 PC、状态寄存器和完整浮点上下文保存在 `TrapContext` 中；任务在内核中主动切换时，只需要保存调用约定要求跨函数调用保持的寄存器，也就是 `TaskContext`：

```rust
pub struct TaskContext {
    ra: usize,
    sp: usize,
    s: [usize; 12],
    fs: [usize; 12],
}
```

真正的切换由架构相关汇编函数完成：

```rust
extern "C" {
    pub fn __switch(
        current_task_cx_ptr: *mut TaskContext,
        next_task_cx_ptr: *const TaskContext,
    );
}
```

RISC-V 版本保存 `ra`、`sp`、`s0..s11` 和 `fs0..fs11`；LoongArch64 版本保存 `$ra`、`$sp`、`$fp`、`$s0..$s8` 和 `$f24..$f31`。因为汇编按固定偏移访问字段，`TaskContext` 必须使用 `#[repr(C)]` 保持布局稳定。

新任务第一次运行时并没有“旧的内核现场”可恢复。用户任务的 `TaskContext` 被初始化为 `TaskContext::goto_trap_return(kstack_top)`，返回地址指向 `trap_return`；内核线程则使用 `TaskContext::goto_kernel_entry(entry, kstack_top)`，直接从指定内核入口开始执行。这样，新任务第一次被 `__switch` 选中后，也能沿用普通的寄存器恢复路径。

== 抢占与安全点

CosmOS 使用延迟抢占。timer 中断、软件中断和唤醒路径并不在任意位置强行切换当前任务，而是把原因写入 `sched.resched_reason`。当 trap 处理即将返回用户态时，内核调用 `schedule_if_needed`，再根据原因选择对应的切出方式。

#figure(
  table(
    columns: (1.5fr, 2.7fr),
    [原因], [含义],
    [`HigherRtPriority`], [更高优先级实时任务进入运行队列，当前任务应让出 CPU。],
    [`RrTimesliceExpired`], [`SCHED_RR` 时间片耗尽，需要同优先级轮转。],
    [`Yield`], [当前任务主动调用 `sched_yield`。],
    [`CfsPreempt`], [CFS 判断当前任务已运行足够久，或新唤醒任务更应运行。],
    [`Migration`], [CPU 亲和性或跨 hart 入队要求重新评估运行位置。],
  ),
  caption: [重新调度原因],
)

周期 timer 的路径如下：

```text
timer interrupt
  -> handle_timer_interrupt()
       处理本 hart 过期定时器
       判断周期 tick 是否到期
  -> on_timer_tick()
       更新当前任务运行时间
       必要时设置 resched_reason
  -> trap 尾部 schedule_if_needed()
       切回 idle 并选择下一个任务
```

这种设计把硬中断处理和上下文切换解耦。硬中断上下文中锁、栈和嵌套状态都更敏感，如果在任意中断点直接执行 `__switch`，调度器需要处理大量额外约束。延迟到 trap 尾部后，内核可以先完成系统调用返回值、信号检查、fatal signal 处理和进程退出检查，再在一个统一位置决定是否切换。

内核态 timer 中断也会调用 `on_timer_tick`，因此任务在内核中消耗的时间同样计入 RR 时间片和 CFS 运行时间。这比只统计用户态 tick 更接近 Linux “任务占用 CPU” 的语义。

== 阻塞与唤醒

阻塞和唤醒是调度器最容易出错的部分。一次典型的阻塞调用并不是简单地“把当前任务从运行队列移除”，因为当前任务本来就不在运行队列里，而是在某个 hart 的 `current` 中。阻塞路径要做的是：把任务挂入等待对象，将状态改为睡眠态，然后从当前 hart 的 `current` 切回 idle。

通用等待队列采用如下模式：

```text
prepare_to_wait:
    task_status = Interruptible
    wait_reason = Some(...)
    current_wq_handle = Some(...)
    将任务放入等待队列

block_current_and_run_next:
    从 Processor.current 取走当前任务
    确认任务仍应睡眠
    保存 TaskContext 并切回 idle

wakeup_task:
    从等待队列取出任务
    将任务重新放入目标 hart 运行队列
```

这里的关键竞态发生在“任务准备睡眠但尚未完成切换”的窗口。`take_current_task()` 已经把 `Processor.current` 清空，但 `on_cpu` 仍然为 true，因为寄存器保存要等 `__switch` 执行后才完成。若同 hart 的 timer hardirq 在这个窗口唤醒该任务，唤醒路径会等待 `on_cpu` 清除；而清除动作又必须等当前 hart 回到 idle 后执行，于是形成自等待。CosmOS 在 `block_current_and_run_next` 和 suspend 路径中用 `LocalIrqSave` 关闭本地中断，保证同 hart hardirq 不会观察到这个半状态。

跨 hart 唤醒则依赖 `on_cpu` 的发布语义。如果远端唤醒者发现任务 `on_cpu == true`，它会先判断该任务是否仍是 `last_cpu` 的当前任务。若仍是当前任务，说明它还没有真正睡下，唤醒只需把状态改回 `Runnable`，阻塞路径随后会发现状态已变并取消切换。若它已经不是 `current`，说明原 hart 正在切换途中，远端唤醒者必须自旋等待 `on_cpu` 以 Acquire 语义变为 false，再安全入队。与之配对的是原 hart 在 `finish_pending_task_release` 中以 Release 语义清除 `on_cpu`。

这套协议保证了两个重要性质：任务不会在寄存器半保存时被另一个 hart 运行；任务也不会因为阻塞和唤醒交错而同时存在于 `current` 与运行队列中。

== 用户态调度接口

调度相关系统调用集中在 `os/src/syscall/sched.rs`。这些接口的实现原则是：任何会改变运行队列排序的属性，都必须先把任务从队列中取下，修改状态后再重新入队；任何会影响正在运行任务的属性，都必须请求其所在 hart 重新调度。

`sched_yield` 的语义随策略变化。普通任务调用后进入 `yield_current_and_run_next`，内核给它追加 `CFS_YIELD_PENALTY_NS` 的虚拟运行时间，使它短期内不容易再次被选中。实时任务只有在本 hart 存在同等或更高优先级实时任务时才真正让出，否则继续运行，避免无意义切换。

`sched_setscheduler` 和 `sched_setattr` 可以改变任务的调度策略、实时优先级、nice 和 deadline 可见字段。若目标任务已经在运行队列中，内核先调用 `remove_task`，更新属性，再通过 `enqueue_task_on` 按新策略放回队列。若目标任务正在 CPU 上运行，则根据它所在 hart 设置 `Migration` 或发送 IPI，让它在安全点重新参与调度。

`setpriority` / `getpriority` 当前支持 `PRIO_PROCESS`。设置 nice 时，内核会更新进程内所有线程的 `nice` 与 `weight`。如果某个线程已经在 CFS 队列中，必须出队再入队，因为它的权重已经影响队列负载和后续虚拟时间计算。

`sched_setaffinity` 把用户传入的 CPU 集合与 online hart 集合求交。若交集为空，返回 `EINVAL`；若任务正在运行且当前 hart 不再属于新集合，内核设置 `Migration` 或向对应 hart 发送 IPI；若任务正在运行队列中，则先移除，再按新亲和性重新选择目标 hart。

== 正确性约束

调度器维护的是一组容器不变量，而不只是队列顺序。最核心的约束如下：

#figure(
  table(
    columns: (1.3fr, 3fr),
    [不变量], [说明],
    [唯一运行], [同一个任务最多只能是一个 hart 的 `Processor.current`。],
    [运行不入队], [正在 CPU 上运行的任务不能同时存在于任何 `RunQueue`。],
    [唯一入队], [同一个任务最多只能在一个运行队列中出现一次。],
    [退出栈安全], [退出任务的内核栈必须等切回 idle 后才能释放。],
    [唤醒安全], [远端唤醒不能在 `on_cpu` 清除前把任务重新放回运行队列。],
  ),
  caption: [调度器核心不变量],
)

为了捕获这类错误，内核提供了 `sched_invariant_checks` 调试特性。开启后，hart 0 会周期性快照所有 `Processor.current` 和所有运行队列，检查是否存在双重运行、运行中又入队、跨队列重复入队等问题。这些检查不进入普通构建路径，但它们反映了调度器设计中真正需要守住的边界。

锁的使用也围绕这些边界展开。`Processor`、`RunQueue` 和任务内部状态都由 `SpinNoIrqLock` 保护，持锁期间本地中断关闭，避免同 hart 中断重入观察到中间状态。唤醒路径尽量缩短临界区：在运行队列锁内完成状态修改，释放锁后再请求抢占或发送 IPI，避免调度动作反向重入同一组锁。

== 小结

CosmOS 的任务调度器可以概括为三层：最底层是架构相关的 `__switch`，负责保存和恢复内核态 callee-saved 上下文；中间层是 per-hart `Processor` 与 `RunQueue`，负责维护任务归属和选择下一个任务；上层是 Linux 风格的调度策略和系统调用接口，负责把 nice、实时优先级、时间片、亲和性等用户态语义映射到内核调度状态。

这一章最重要的结论是：调度正确性来自清晰的状态边界。一个任务要么属于某个 hart 的 `current`，要么属于某个运行队列，要么属于某条等待队列；切换过程中的短暂半状态必须用 `on_cpu`、本地关中断和 Release/Acquire 配对保护起来。后续的进程管理、信号、futex、poll、定时器和文件系统阻塞都建立在这套边界之上，因此调度器的设计直接决定了整个内核并发语义的可靠性。
