// 文件子系统：缓存分工、后台预读、完成 worker 与可复现实测。

== 文件通路与缓存分工

文件系统由 VFS/多后端、统一文件对象、Page Cache 与块设备访问组成。文件、目录、管道、终端和套接字通过文件描述符及 File 接口接入系统调用；设备与后端的差异收敛在 VFS 和块设备层。

#figure(image("assets/filesystem_stack_bluegreen.drawio.pdf", width: 88%), caption: [文件通路与五级缓存])

#[#set text(0.9em)
#figure(
  table(
    columns: (1.0fr, 1.6fr, 2.5fr),
    [层次], [缓存对象], [作用],
    [Stat cache], [inode 属性快照], [减少重复属性查询，修改时显式失效],
    [Dentry cache], [目录项与负查找], [加速路径分量解析，缓存不存在的名字],
    [Inode cache], [文件对象身份], [复用同一 inode 与其挂载的运行时状态],
    [Page Cache], [文件数据页], [承载映射、读写、脏页与回写],
    [Block cache], [磁盘块], [缓存文件系统元数据及其他块级访问],
  ),
  caption: [缓存层次与职责],
)
]

决赛读路径将文件数据页直接经 Page Cache 接入块设备读取，避免同一文件数据同时驻留 Page Cache 和 Block Cache；Block Cache 因而主要服务块级元数据。缓存各自有失效、回收和旁路边界，减少跨层重复保存同一数据。

=== 缓存键、失效与回收

Stat cache 保存 inode 属性快照；create、unlink、truncate 和扩展写会显式使相关快照失效。Dentry cache 以文件系统、父目录 inode 和名字为键，同时缓存正向结果与确认不存在的名字；rename、unlink、rmdir 更新对应目录项。Inode cache 复用同一文件对象身份，使 Page Cache 和属性状态能跨 open、硬链接等路径共享。

dentry 与 inode 缓存按父目录分桶，并以读写锁分离并发查找与变更；热查找不必争用一个全局 BTreeMap。两者采用 CLOCK 二次机会回收和 16,384/12,288 的高低水位；inode 只有在缓存自身持有唯一 Arc 引用时才可淘汰。Block Cache 以 512 B 块为键，容量上限 8,192 项，被借用的块不参与淘汰。

Page Cache 的回收水位随可用内存调整，而非固定占满一段容量。CachePage 的 pin_count 与 map_count 分别保护 I/O 使用页和映射页；脏页先回写，LOADING、WRITEBACK 或 EVICTING 状态通过每页等待队列串行化，防止并发缺页重复读、回收与写回互相踩踏。文件数据页 direct-read 后，块缓存继续服务元数据而不保留第二份文件内容。

== 并发读路径与后台工作

CachePage 以 LOADING/UPTODATE/DIRTY/WRITEBACK/EVICTING 等状态协调装页、回写与回收。同一页首次缺失时由一个任务发起 I/O，后续任务在该页等待队列上休眠；装入完成后共享同一页，避免重复读取。正在映射、I/O 或回写的页不会被直接回收。

顺序访问触发有界窗口预读。前台满足当前需求并装入窗口前段，剩余相邻页交给低优先级 kreadahead worker；后台任务可合并相邻范围，队列设上限，压力过大时丢弃投机任务而不阻塞需求读取。命中页可直接映射，连续物理页还可合并为较少的块设备传输。

VirtIO 块设备的中断路径只登记完成工作并唤醒全局 block I/O worker。worker 在任务上下文中分批泵取完成项；仍有工作时让出 CPU 后继续处理，无工作时进入等待队列。完成项按请求令牌归还缓冲并唤醒对应等待者。异步提交与完成处理是内核内部机制，文件系统对上仍提供同步读取语义。

从系统调用到设备的典型读路径是：fd 表取得 FileDescription，用户缓冲区被翻译为可访问页段，Page Cache 查找对应文件页；未命中时一个装载者申请物理页并提交块请求，其他读取同页的任务等待该 CachePage。块设备中断只记录完成并唤醒 worker，worker 取回令牌、完成页状态更新并唤醒等待者；上层再复制或映射到用户页。缓存命中则跳过块设备路径，单页小缓冲走专用快速路径。

pipe 是构建 jobserver 的另一条关键 I/O 路径。读写端共享有界环形缓冲区，空/满时复用普通等待队列，状态改变后同时通知 poll source；关闭最后一个写端后读侧观察 EOF。它绕过磁盘 VFS 与 Page Cache，却与普通文件、套接字共享 fd 和事件接口。

== 代表性性能结果

#[#set text(0.9em)
#figure(
  table(
    columns: (1.5fr, 2fr, 2fr),
    [负载与条件], [关闭相关缓存], [启用后的结果],
    [iozone 顺序读，64 MiB / 4 KiB], [约 4,943 KB/s], [约 111,371 KB/s，约 22 倍],
    [iozone 顺序写，64 MiB / 4 KiB], [约 2,558 KB/s], [约 88,171 KB/s，约 34 倍],
    [5,000 文件目录树热遍历], [约 15.6 s], [约 0.021 s，约 740 倍],
    [目录树创建], [约 245 s], [约 80 s，约 3 倍],
  ),
  caption: [Page Cache 与 Block Cache 的代表性对照结果],
)
]

数据说明了不同缓存的作用边界：Page Cache 主要提升具有局部性的文件数据访问；Block Cache 对目录树创建和重复元数据遍历更敏感。所有对照均需使用相同镜像、负载和缓存状态，并结合 io_perf 命中计数解释收益。

#figure(image("assets/fs_page_cache_iozone.svg", width: 82%), caption: [iozone 顺序与随机访问的 Page Cache 对照])
#figure(image("assets/fs_block_cache.svg", width: 82%), caption: [Block Cache 对目录树创建和遍历的影响])
