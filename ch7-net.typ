// 第七章：网络栈 —— 由 main.typ 在 `= 网络栈` 之后 #include。

网络栈是本内核中体量最大、也最依赖前一章“阻塞—唤醒”基础设施的子系统。它在用户态暴露一套完整的 BSD 套接字接口（`socket` / `bind` / `listen` / `accept` / `connect` / `sendto` / `recvfrom` / `sendmsg` / `recvmsg` / `setsockopt` …），在内核态则构建在一套*协作式*的协议栈之上。本章先给出整体架构，再自顶向下地依次讨论协议栈的驱动模型、收发数据通路、VirtIO-net 驱动、套接字层与阻塞模型，以及它与多路等待、信号子系统的集成。

== 总体架构

内核没有从零实现 TCP/IP 协议栈，而是引入了 smoltcp —— 一个原本面向嵌入式与用户态、无堆分配、单线程协作式的协议栈，并在其 `phy::Device` 抽象之下接上自己的 VirtIO-net 驱动。这一选择的根本原因在于：smoltcp 把“何时处理一个包”的决定权完全交给调用者，它本身既不拥有线程，也不会被中断主动驱动，只有在被显式调用 `iface.poll()` 时才向前推进。因此，内核网络栈的*核心设计问题*并不是协议本身，而是*如何在不引入独立内核线程的前提下，把硬件中断、定时器与用户系统调用三条事件源，统一汇入对 smoltcp 的一次推进*。

整套网络栈按下面的层次组织：

#[
   #set text(0.95em)
#figure(
  table(
    columns: (0.6fr, 2fr, 2.1fr),
    [层次], [职责], [关键结构 / 接口],
    [套接字层], [`File` trait 的各类套接字文件，接系统调用], [`TcpSocketFile` / `UdpSocketFile` / `UnixSocket`],
    [协议栈], [TCP/UDP/ICMP/ARP/IPv4/IPv6 状态机], [smoltcp `Interface` / `SocketSet`],
    [设备适配], [在 VirtIO 与回环之间路由帧], [`MultiDevice` + `RxToken` / `TxToken`],
    [网卡驱动], [描述符环、收发缓冲、中断应答], [`VirtIONetDevice`（令牌化完成）],
  ),
  caption: [网络栈的分层与各层职责],
)
]


#figure(image("assets/net_stack.svg"), caption: [网络栈的总体架构示意图])

这一架构最值得注意的特征是：除 AF_UNIX 外，所有阻塞、唤醒与就绪通知都复用了第六章的同一套原语。套接字的收发阻塞落在每套接字的 `read_wait` / `write_wait`（普通 `WaitQueue`）与 socket 超时注册表上；网卡发送的完成等待落在一条以令牌为键的 `WaitQueueKeyed<u16>` 上；而每一次协议栈状态变化，都通过 `notify_poll_source` 汇入 poll 注册表。换言之，网络栈是第六章那套“槽注册表 + 键控等待队列”机制最大的消费者，它的正确性很大程度上是*继承*来的，而非重新发明的。

== 协议栈的驱动模型：软中断式 Polling

smoltcp 的协作式本质决定了它必须被*反复轮询*才能前进。内核持有唯一的协议栈实例，并从两条事件源驱动它。

第一条是网卡中断。当 VirtIO-net 产出一个中断时，陷阱处理进入外部中断路径，先扫描中断源并分发，其中网卡分支执行 `dev.handle_irq()`（应答设备中断并回收已完成的发送描述符），紧接着调用 `net::notify_irq()`。`notify_irq` 做的事情极小却极关键——它只把一个全局的 `NEED_POLL` 原子标志置位、并把“下次软超时”清零，然后立即返回。真正的协议栈推进发生在分发之后的 `net::poll()` 调用里。这种“中断只设标志、延迟到安全上下文再推进”的做法，本质上是一种*软中断*（softirq）：硬中断越短越好，重活留给中断返回前的统一处理。

#figure(image("assets/net_poll_wakeup.svg", width: 95%), caption: [网络栈的软中断式 Polling 驱动模型示意图])

第二条事件源是*定时器*。TCP 的重传、保活、TIME-WAIT 等都依赖时间推进，而它们在 smoltcp 内部表现为一个“最早需要被再次轮询的时刻” `poll_at`。每次 `poll_once` 结束时，`refresh_poll_deadline` 把这个时刻写入全局的 `NEXT_POLL_DEADLINE_US`；周期性的定时器滴答路径 `poll_timer_tick` 据此判断：若没有 `NEED_POLL`、也没有到期的软超时，就直接返回，绝不空转。这样就形成了一个*双触发*的驱动模型——事件来了立即推进（`NEED_POLL`），没有事件时也能在恰好需要的时刻被定时器唤醒推进，二者都不浪费 CPU。

`poll_once` 在调用 `iface.poll` 之后，会遍历所有 UDP 与 TCP 套接字状态，把“可读 / 可写 / 对端关闭”等变化翻译成两类动作：直接唤醒挂在相应 `read_wait` / `write_wait` 上的阻塞任务，以及通过 `notify_poll_source` 通知 poll 注册表（这样正在 `ppoll` 该 fd 的任务也会被唤醒）。TCP 套接字还会经由 `observe_state_change` 记录状态迁移，供监听套接字与孤儿回收使用。

为了在“低延迟”与“不霸占 CPU”之间取得平衡，`poll_with_budget` 采用了一种*自适应预算*。一次 `poll()` 最多连续执行 `poll_once` 若干轮，只要回环队列非空、或 `NEED_POLL` 在过程中被重新置位（说明又来了新事件），就再跑一轮，直到预算耗尽。更进一步，当用户系统调用主动请求推进某个套接字时（`poll_socket_work_for`），内核会根据*当前活跃的 TCP 连接数*调节预算：连接很少（不超过 2 条）时给予很深的预算（64 轮），让单次调用尽量把数据推进到位；连接很多时则先给一个轻量预算（8 轮），并仅在发送队列未能有效排空时再追加一个“追平”预算（32 轮）。这一启发式避免了在大量连接下、每次系统调用都付出 $O(N)$ 的轮询代价。

== 收发数据通路

接收路径的核心是*预投递的接收缓冲*。VirtIO-net 驱动在初始化时就把全部 16 个描述符对应的接收缓冲通过 `receive_begin` 投递给设备（`rx_slots`），此后设备每写入一帧就占用一个描述符。smoltcp 侧的 `MultiDevice::receive` 调用驱动的 `try_recv`：它取出一个已完成的帧，把载荷拷出，然后*立刻*把同一块缓冲重新投递回去。这样接收环上始终挂满空闲缓冲，接收侧不存在“先取走再补投”的窗口，也就不会因为补投不及时而丢帧。

发送路径的关键是*按目的地址路由*。`MultiDevice` 同时包装了 VirtIO 设备与一个内核自带的 Loopback 设备，二者挂在同一个 smoltcp 接口上。在 `TxToken::consume` 里，内核先生成帧，再嗅探以太网帧的 ethertype 与目的 IP：若是 IPv4 的 `127.x.x.x`、IPv6 的 `::1`（及 solicited-node）、或目标为回环地址的 ARP，就直接压入 Loopback 队列；否则走 VirtIO 的 `try_send`。接收侧则*优先*尝试 Loopback，使本地通信获得更低的延迟。这一设计把“外部网络”与“本机回环”统一在一个接口之下，却又让回环流量完全不经过真实网卡。

需要指出一个明确的取舍：在 smoltcp 的 `RxToken` / `TxToken` 边界上，内核仍为每一帧分配一个 `Vec<u8>`（接收侧 `RX_BUF_LEN` 为 32 KiB，发送侧按帧长分配）。这是为了适配 smoltcp “借用切片”的接口契约而付出的拷贝代价。它在正确性上无懈可击，但在高吞吐场景下会成为瓶颈，是后续可优化的方向之一。当 VirtIO 发送队列暂时排满时，`try_send` 返回 `Ok(false)`，内核选择*丢弃这一帧*并记录 trace，同时置位 `NEED_POLL` 以保证随后再来一轮——这对应真实网卡在队列满时的丢包语义，避免发送路径阻塞整个协议栈。

== VirtIO-net 驱动与令牌化完成

网卡驱动是网络栈里最具特色的一处工程。它围绕一个大小为 16 的描述符环组织收发，但真正体现设计含量的是它的*发送完成模型*。

驱动提供两条发送路径。其一是非阻塞的 `try_send`，供 smoltcp 的 `TxToken` 使用：它把帧缓冲存入 `tx_slots[token]`，立即返回，完成后再由 `reclaim_tx_completions` 懒回收。其二是阻塞的 `send`，它会在投递后*等待这一帧的发送完成*。难点在于：描述符环上的完成通知并不保证按请求顺序到来，若用一个 FIFO 等待队列，先发送的任务可能被后到达的完成错误地唤醒。

驱动的解法正是第六章的键控等待队列 `WaitQueueKeyed<u16>`，*以描述符编号（令牌）为键*：

#figure(image("assets/net_wait.svg", width: 95%), caption: [VirtIO-net 驱动的令牌化完成模型示意图])

当 `reclaim_tx_completions` 从环上窥视到一个已完成的令牌时，它区分两种情况：若该令牌属于非阻塞路径，就回收其缓冲并继续排空队列；若属于阻塞路径，则把 `tx_done[token]` 置位，并调用 `wake_selected(token)`——这一句只会唤醒*恰好阻塞在这个令牌上*的那一个任务，绝不误伤他人。被唤醒的任务随后自行调用 `transmit_complete` 真正归还缓冲。

这里有一处精妙的*顺序约束*。`poll_transmit` 是只窥视、不消费的：在阻塞等待者通过 `transmit_complete` 真正归还该描述符之前，它会一直停在环的头部。因此 `reclaim_tx_completions` 在遇到一个阻塞令牌时*立即返回*，不再继续向环的更深处窥视，避免把尚未被等待者消费的令牌“看花”。这种“窥视—标记—交还消费者”的分工，使得非阻塞的批量回收与阻塞的精确唤醒可以在同一个环上安全共存，既不会双重释放缓冲，也不会丢失完成通知。

中断处理同样有一处从实战中得来的细节。在外部中断分发里，内核对每一个中断源*先做 EOI（结束中断）再运行其处理函数*。早期的“先处理后清除”顺序会丢失 VirtIO 完成中断：若在设备应答（位于处理函数内部）与随后的“写 1 清除”之间，又一帧完成到达，它刚刚置上的中断位会被那次清除动作一并抹掉，于是阻塞的工作任务将永远等不到唤醒。先 EOI 则保证：处理过程中任何重新置位的中断都能留下一个存活的新位，在中断返回后再次触发。

== 套接字层与阻塞模型

每一类套接字都实现 `File` trait，从而可以像普通文件一样占据一个 fd、被 `read` / `write` / `ppoll` / `ioctl` 操作。内核提供了完整的 BSD 套接字系统调用面：`socket`、`socketpair`、`bind`、`listen`、`accept` / `accept4`、`connect`、`sendto` / `recvfrom`、`sendmsg` / `recvmsg`、`shutdown`、`setsockopt` / `getsockopt`、`getsockname` / `getpeername`。

每个套接字都关联一个*套接字状态*对象（如 `TcpSocketState` / `UdpSocketState`），它持有一对 `read_wait` / `write_wait` 等待队列、一个用于 poll 集成的 `source_id`，以及（TCP）一个 `orphaned` 孤儿标志与到监听者的弱引用。阻塞型的收发遵循第六章的三段式范式：以 UDP 接收为例，循环里先锁住 `NET_STACK`、向 smoltcp 推进并尝试 `recv`；若不可读，则释放锁，在 `read_wait` 上以 `wait_with_reason_or_skip` 阻塞，其 `should_skip` 闭包会复查“现在可读了吗 / 是否已超时 / 是否有未屏蔽信号”三者之一。醒来后分别处理信号中断（`EINTR`）、超时（`EAGAIN`，对应 `SO_RCVTIMEO`）与正常就绪。

`SO_RCVTIMEO` / `SO_SNDTIMEO` 的超时机制本身，是第六章“槽注册表 + 代计数器”范式的*第四个实例*（继 poll、futex、信号之后）。`socket_timeout` 模块维护一个 `SOCKET_WAIT_REGISTRY`：接收前 `register_socket_wait` 领取一个带代的句柄并把它绑到一个绝对截止时间的定时器上；定时器到期回调 `handle_socket_wait_timeout` 校验代号后把状态置为超时并唤醒；任务醒来后用 `socket_wait_state` 判定是被数据唤醒还是被超时唤醒。同一套防 ABA、防丢失唤醒的纪律，使得套接字超时与 poll、futex、信号一样可靠。

TCP 的监听—接受采用了*两级队列*。`TcpListenerShared` 维护两张表：`passive` 收纳处于握手过程中（尚未 ESTABLISHED）的套接字，`pending` 收纳已完成握手、可供 `accept` 取走的连接。`poll_once` 在巡视到某个 passive 套接字进入 ESTABLISHED 时，通过 `queue_listener_connection_if_ready` 把它从 `passive` 摘下、推入 `pending`，并唤醒监听者的 `accept_wait`；`accept` 则从 `pending` 弹出一个连接返回给用户。当用户关闭一个仍有数据的套接字时，它被标记为 `orphaned` 而不立即销毁，直到 smoltcp 把它彻底关闭，`poll_once` 的孤儿回收才会真正移除它——这避免了在 TIME-WAIT 等阶段提前释放协议栈资源。整个TCP连接的生命周期如下图所示：

#figure(image("assets/tcp2.svg", width: 95%), caption: [TCP 套接字的生命周期示意图])

除基于 smoltcp 的 TCP/UDP 外，内核还实现了若干*内核原生*的套接字族：AF_UNIX 提供流式与数据报两种本地套接字，并支持 `SCM_RIGHTS` 文件描述符传递与 `SCM_CREDENTIALS` 凭证传递；Raw IPv6 套接字（`AF_INET6` / `IPPROTO_ICMPV6`）配合 ICMPv6 过滤器，服务于邻居发现等;此外还有一组为兼容 iproute2 等工具而设的 netlink-route、packet、ifreq 套接字，以及 `AF_ALG` 加密套接字。这些兼容层使标准的 Linux 诊断工具能在本内核上运行。

== 与多路等待、信号的集成

网络栈与第六章的另两个子系统的衔接，体现在两个方向上。

向*多路等待*的方向，每个套接字都通过 `poll_source_id` 暴露自己的就绪源身份，并实现 `poll(events)` 做电平检测。因此一个任务完全可以像 `ppoll` 一个管道那样，`ppoll` 一组套接字 fd：当 `poll_once` 让某套接字变为可读时，`notify_poll_source` 会经 poll 注册表把对应的等待键标记就绪并唤醒。换句话说，套接字在事件驱动模型中的地位与管道、终端完全平等——这正是统一 poll 机制的价值。

向*信号*的方向，套接字的每一次阻塞接收 / 发送都在 `should_skip` 闭包里、以及醒来之后，检查 `has_unmasked_pending_signal`。一旦有一个会被采取行动的信号到达，阻塞立即被打断并返回 `EINTR`；若设置了超时且确实超时，则返回 `EAGAIN`。结合第六章描述的“信号唤醒分流”——处于活跃 poll 等待的套接字任务由 `notify_poll_signal_pid` 经 poll 通道唤醒，其余由各自的 `current_wq_handle` 摘队唤醒——一次 `Ctrl+C` 既能把阻塞在 `accept` 上的服务端拉出来，也能把阻塞在 `ppoll` 上的客户端拉出来。

把这一切串起来的，是那个唯一的 `NET_STACK` 自旋锁。smoltcp 不是可重入的，因此无论事件来自硬中断、定时器还是用户系统调用，所有对协议栈的访问都被*串行化*在这一把 `SpinNoIrqLock` 之下。这是一项重要的简化：它用一个明确的串行点换来了无需细粒度锁的正确性，也使得前述“中断只设标志、统一推进”的软中断模型成为可能。其代价是多连接下的锁竞争，这正是自适应预算试图缓解、也是未来可改进之处。

== 权衡与展望

回顾网络栈的设计，最核心的选择是*以 smoltcp 为协议核心、以软中断式 polling 为驱动模型*。这一组合带来了三个好处：协议实现成熟可靠（直接复用经过广泛验证的 smoltcp）；无需为每个连接或每个套接字创建内核线程，调度压力小；所有阻塞与唤醒复用第六章的统一原语，正确性可推导。`NEED_POLL` 标志与 `poll_at` 软超时构成的*双触发*机制，则在“事件到达即推进”的低延迟与“无事件时不空转”的低开销之间取得了平衡。

代价与可改进之处同样清晰。首先，全局单一的 `NET_STACK` 锁是多连接吞吐的主要瓶颈，自适应预算只是缓解；未来可考虑将协议栈推进移入一个专用的网络内核线程或更细粒度的软中断上下文，让用户系统调用仅负责触发与等待。其次，在 smoltcp 的 `RxToken` / `TxToken` 边界上仍有逐帧的 `Vec` 分配与拷贝，未来可引入缓冲回收或与驱动描述符直接绑定的零拷贝路径。再次，第六章提到的 epoll 尚未实装，当前的事件驱动并发完全由 `ppoll` 承担，在大规模网络服务的场景下会成为扩展性短板。最后，IPv6 / ICMPv6 与 netlink 的覆盖仍偏最小，TCP 拥塞控制直接沿用 smoltcp 的实现，Raw IPv4 套接字也尚未提供——这些都是在不改变现有驱动模型与阻塞模型的前提下，可以渐进补全的方向。
