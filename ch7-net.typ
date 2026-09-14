// 网络栈：展示协议推进 worker、VirtIO 完成令牌与统一事件等待。

== 协作式协议栈与 deferred worker

CosmOS 以 smoltcp 提供 TCP/IP 状态机，并通过 VirtIO-net 与 Loopback 接入设备。协议栈由统一的 NET_STACK 锁保护；硬中断不执行完整协议处理，而是设置待处理状态并调度网络 worker。net_poll_worker 在任务上下文中处理驱动延后工作并推进 smoltcp，随后将 socket 可读/可写变化通知等待队列和 poll/epoll。

#figure(image("assets/net_stack.svg", width: 84%), caption: [套接字、smoltcp、设备适配与 VirtIO-net 的分层])

定时器根据协议栈给出的下一次截止时间安排推进；有设备事件时立即唤醒，没有待处理事件且尚未到期时 worker 休眠。这样既避免在中断上下文执行重活，也避免无事件时持续空转。

#figure(image("assets/net_poll_wakeup.svg", width: 88%), caption: [中断、定时器与网络 worker 的协同])

== VirtIO 完成与套接字等待

VirtIO 发送请求以描述符令牌标识。非阻塞路径提交后延迟回收；阻塞路径按令牌进入键控等待队列。完成处理只唤醒对应令牌的任务，避免完成乱序时唤醒错误等待者。接收缓冲预先投递并在取帧后回补，维持接收环可用。

#figure(image("assets/net_wait.svg", width: 88%), caption: [VirtIO-net 发送完成与令牌化唤醒])

接收环预先向设备投递固定数量的缓冲；完成一个接收项后，驱动取出帧并回补该槽，缩短设备无可写接收缓冲的窗口。发送侧区分 smoltcp 使用的非阻塞提交和内核任务使用的等待完成路径：前者由后续 worker/中断回收，后者保存令牌对应的缓冲与等待状态，完成乱序时仍按令牌精确唤醒。

套接字实现统一 File 接口，可被 read/write、超时、信号和多路等待共同管理。NET_STACK 单锁简化了 smoltcp 单线程推进的正确性；代价是并发连接共享串行点。协议层、设备完成和用户态阻塞之间的边界由 worker、等待 key 与 poll source 明确连接。

TCP 监听连接采用握手中与已就绪两级队列。协议推进观察到握手完成后，把连接迁入 accept 可取走的队列并唤醒监听者；用户关闭但仍处于协议关闭阶段的连接暂存为 orphan，待协议栈完成关闭后再回收，避免过早释放其 socket 状态。

#figure(image("assets/tcp2.svg", width: 95%), caption: [TCP 监听、accept 与连接回收生命周期])
