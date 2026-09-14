// BAIS：面向 fork-join AI 工作负载的干扰分散调度。

== 设计动机与目标

并行 AI 算子通常由多个 worker 执行同一 phase，并在 barrier 处汇合。phase 的完成时间由最晚到达的 worker 决定，可写成 $T_"phase" = max_i T_i$，其中 $T_i = C_i + S_i + I_i$：$C_i$ 是有效计算时间，$S_i$ 是缺页、内存控制和系统调用等同步服务时间，$I_i$ 是硬中断、设备 completion 与普通任务带来的异步干扰。传统负载均衡只观察可运行任务数和 CPU 负载，不知道多个 worker 是否处于同一个 barrier，也无法判断额外工作会不会继续拖慢关键路径上的 laggard。少量且分布不均的 OS 工作因而可能被 $max$ 放大成整个 phase 的尾延迟。

BAIS（Barrier-Aware Interference Spreading）的目标，是在 AI worker 仍使用全部可用 hart、且不预留 system core 的前提下，把可调度的 OS 工作放到预计更早完成的 worker 所在 hart。它并不替代 CFS 或实时调度类，而是在普通 CFS 任务入队选核之前增加一个带应用语义的放置层；关闭 BAIS、没有已注册 workload、任务不属于 `SCHED_OTHER`，或 BAIS 无法给出合法目标时，仍回退到原有调度路径。

#figure(image("assets/bais-scheduler-design.svg", width: 100%), caption: [BAIS 从 phase 提示到任务放置的决策路径])

== Phase 提示与状态模型

BAIS 采用显式提示而不是根据进程名、CPU 利用率或指令流猜测 AI 任务。用户态通过系统调用 480 报告粗粒度 phase 信息；内核以注册进程的 PID 识别该进程中的 AI worker，当前只维护一个注册 workload。

#figure(
  table(
    columns: (0.8fr, 1.6fr, 3fr),
    [操作值], [提示], [内核动作],
    [1], [`REGISTER`], [记录 PID 与 worker 数量，并初始化 phase 状态],
    [2], [`PHASE_START`], [清空进度、到达位图、phase 计账与 reservation，并通知其他在线 hart 重新调度],
    [3], [`PROGRESS`], [按 0～1000 的协议约定，单调更新当前 hart 的进度],
    [4], [`ARRIVED`], [把当前 hart 标为已到达 barrier，进度置为 1000],
    [5], [`UNREGISTER`], [注销 workload，并清除尚未兑现的放置 reservation],
  ),
  caption: [BAIS 用户态提示协议],
)

调度器为每个 hart 维护 phase 内 AI 与 non-AI 运行时间、IRQ 时间、同步服务时间、worker 进度、barrier 到达状态以及待执行的放置 reservation。任务切入和切出时更新 AI/non-AI 运行时间；trap 路径分别记录硬中断，以及 AI 进程发生的缺页、内存控制、设备控制与其他系统调用。所有热路径状态均以原子变量维护，选核时读取的是一个近似快照：它避免引入跨 hart 全局大锁，同时允许统计值存在短暂的不一致。

== AI worker 的稳定映射

注册进程中的普通调度类线程按 TID 映射到其 affinity 允许的 hart 集合。映射使用 `TID mod 可用 hart 数` 对应的第 n 个 hart，因此相同的 TID 与 affinity 会得到稳定目标。空闲 hart 尝试从其他运行队列窃取任务时，也只允许 AI worker 回到自己的 home hart。该约束减少 worker 迁移、缓存失效和多个 worker 偶然扎堆，但不会减少 AI 可使用的 hart 数量；CPU affinity 和在线 hart 掩码始终是选核的硬边界。

稳定映射还让“每 hart 进度”能够近似表示“对应 worker 的进度”。若任意迁移 worker，运行时间、进度和干扰债务会失去稳定的归属，预计完成时间便难以解释。BAIS 因此只改变任务放置，不改变本地运行队列内 CFS 的 vruntime 公平性，也不越过实时类优先级。

== 基于预计完成时间的干扰分散

对 hart $i$，设当前 phase 已执行的 AI 时间为 $A_i$，应用上报进度为 $P_i in [0, 1000]$。尚未计入账本的当前运行片段会在读取时补入 $A_i$。当 $0 < P_i < 1000$ 时，BAIS 用线性外推估计剩余时间：

$ R_i = A_i dot (1000 - P_i) / P_i $

已到达 barrier 的 worker 令 $R_i = 0$；进度或运行时间仍为零时，剩余时间记为未知的大值，避免凭空断言该 worker 最早完成。non-AI 任务唤醒时，仅选择 affinity 允许的 hart，并比较：

$ F_i = R_i + Q_i dot E_"non-ai" $

其中 $Q_i$ 是已经选择该 hart、但尚未开始运行的 non-AI 任务数，$E_"non-ai"$ 是最近 non-AI 运行片段成本的指数移动平均。实现以 100 µs 初始化该成本，将样本限制在 20～500 µs，并按 $E' = (7E + "sample") / 8$ 更新。选核函数在返回前立即增加 $Q_i$，任务真正开始运行时再消费一次 reservation。这样，并发唤醒者能看到前一个选择的预计成本，不会全部涌向当前 $R_i$ 最小的 hart。

若多个 hart 的 $F_i$ 相同，BAIS 再选择 phase 干扰债务 $D_i$ 更小者。$D_i$ 汇总该 hart 上的 non-AI 运行、硬中断，以及 AI 任务自身经历的缺页、内存控制、设备控制和其他系统调用时间。这个 tie-break 不改变“优先干扰更早完成者”的主目标，只在预测相同的情况下避免持续偏向已经承受较多 OS 工作的 hart。

== 将 completion 变成可调度工作

选核只能影响调度器能够看见的任务，无法搬迁已经在 hard IRQ 上下文中执行的代码。为扩大可控制范围，VirtIO 块设备和网络路径把主要 completion 处理下沉到 `SCHED_OTHER` 内核线程：top half 只确认事件并唤醒 worker，worker 再在任务上下文中完成队列回收、协议栈轮询和等待者唤醒。此类 worker 每次入队都经过 BAIS 的 non-AI 放置决策，因此可以随最新 phase 进度改变执行 hart。

块设备 worker 单次最多处理 16 个 completion；仍有积压时主动切回调度器并重新入队，既限制一次 bottom half 的占用时间，也让 BAIS 重新评估目标。网络 deferred worker 同样处于调度器可见的任务上下文。中断到达 hart 与 deferred worker 实际运行 hart 会分别计数，以便确认下沉工作是否发生跨 hart 放置。

这里的边界是明确的：hard IRQ 的确认仍发生在中断实际到达的 hart，DMA 也不受 BAIS 调度；在 QEMU PLIC 环境中，硬中断仍可能集中到 bootstrap hart。BAIS 移动的是线程化的主要 completion，而不是声称实现了 IRQ 或设备级 steering。

== 调度路径与并发约束

BAIS 接入 `select_target_hart` 的公平类分支，并位于常规 CFS 负载比较之前。其决策流程如下：

+ 实时任务直接遵循原有 FIFO/RR 语义，BAIS 不参与放置；
+ AI 任务在有效 affinity 中计算稳定 home hart；
+ non-AI 公平任务用预计完成时间、reservation 与干扰债务选择 hart；
+ 返回目标不合法或状态不足时，继续使用 preferred hart 与 CFS 负载分数；
+ 任务进入目标 hart 的本地运行队列后，仍由 CFS 的 vruntime 决定实际运行次序。

#figure(
  table(
    columns: (1.5fr, 3.5fr),
    [实现位置], [职责],
    [`sched/bais.rs`], [phase 状态、完成时间预测、reservation、计账与诊断输出],
    [`sched/runqueue.rs`], [入队选核钩子与 AI worker 窃取限制],
    [`syscall/sched.rs`、`fs/procfs.rs`], [提示系统调用与 `/proc/bais` 控制面],
    [`trap/mod.rs`], [硬中断、缺页及同步系统服务计账],
    [`drivers/block`、`drivers/net`、`net`], [调度器可见的 block/network deferred worker],
  ),
  caption: [BAIS 的内核集成位置],
)

phase 开始会重置短期统计，并向其他在线 hart 发送重新调度请求，使新的 phase 边界尽快被各核看到。状态发布使用 Acquire/Release 原子次序；计数类数据使用 Relaxed 次序，因为其用途是近似预测和诊断，不承担任务状态机的正确性。BAIS 不修改 `on_cpu`、`on_rq`、上下文切换安全点等 SMP 不变量，任务迁移安全仍由通用调度器保证。

== 控制、观测与适用边界

`/proc/bais` 是策略控制与诊断入口。写入 `bais`（或 `on`、`1`）启用机制，写入 `off`（或 `0`）关闭机制，写入 `reset` 清空累计统计；未知命令返回错误。读取该文件可获得当前策略、注册 PID、worker 数和 phase、到达位图、AI/non-AI 选核次数、fallback、hint 数、completion 迁移、EWMA 成本，以及每 hart 的进度、reservation、预计剩余时间和各类服务时间。

BAIS 的收益依赖于 fork-join 结构、足够准确的进度提示，以及可被线程化的干扰。当前实现不会自动识别任意 AI 应用，只支持一个显式注册 PID；线性外推也是假设进度与剩余计算量大体相关的启发式模型。对于没有 barrier、进度不可比、主要瓶颈来自不可迁移 hard IRQ/DMA，或实时语义优先的负载，BAIS 会受限或绕过。因而，设计目标应表述为降低“干扰不均被 barrier 放大”的风险，而不是保证所有工作负载的吞吐量或每一种尾延迟指标都改善。
