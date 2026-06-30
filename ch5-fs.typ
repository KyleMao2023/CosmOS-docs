// 第五章：文件子系统 —— 由 main.typ 在 `= 文件子系统` 之后 #include。

文件子系统是本内核中分层最细、性能优化空间也最大的部分。它跨越两个 crate：独立的 `fs` 库提供磁盘文件系统与 VFS（支持 easyfs、ext4、fat32 三种后端），内核侧 `os/src/fs` 提供 fd 与 `File` 抽象、page cache，以及 devfs/procfs/sysfs/tmpfs 等特殊文件系统。贯穿这两层的，是一组*分工明确*的缓存——从最顶层的 stat 属性快照，到最底层的磁盘块缓存，共五级。本章先给出整体架构，再依次讨论 VFS 与多后端、五级缓存的分工、以 iozone 为代表的读写性能优化与实测，最后着重讨论这套分工的一个结构性局限——page cache 与 block cache 对文件数据的*双重缓存*。

== 总体架构

整个文件子系统的数据通路自上而下穿过五层。用户态的系统调用经 fd 表落到 `File` 抽象上；`File` 或走内核原生的特殊文件系统，或经 page cache 到达 VFS 层的 `Inode`；`Inode` 包装着某个磁盘后端的 `VfsNode`，最终经 block cache 访问块设备，如下图所示。

#figure(image("assets/fs_call_overview.pdf", width: 100%), caption: [文件子系统的调用与数据通路示意图])

在整个子系统中，有很多基于内存的缓存加速访问，如下图所示：

#figure(image("assets/filesystem_stack_bluegreen.drawio.pdf", width: 100%), caption: [文件子系统的五级缓存通路示意图])

这条通路上的五级缓存各司其职，可以归纳为下表。它们的设计遵循同一种骨架——以一张 `BTreeMap` 为核心表、配一个简化的 CLOCK 二次机会队列与高/低水位回收——只是键、缓存对象与粒度不同。

#[
#set text(0.9em)
#figure(
  table(
    columns: (1.0fr, 2fr, 0.8fr, 0.6fr, 1.25fr),
    [缓存], [缓存对象], [粒度], [所在层], [feature 开关],
    [Stat cache], [`Inode` 的 `VfsAttrs` 属性快照], [整个 inode], [VFS], [`no_stat_cache`],
    [Dentry cache], [`(fs_id, parent_ino, name)` → 子 inode], [路径分量], [VFS], [`no_dentry_cache`],
    [Inode cache], [`(fs_id, ino)` → `Arc<Inode>` 身份复用], [inode], [VFS], [`no_inode_cache`],
    [Page cache], [文件数据页], [4 KB], [内核], [`no_page_cache`],
    [Block cache], [磁盘块（元数据 + 数据）], [512 B], [磁盘 FS], [`no_block_cache`],
  ),
  caption: [五级缓存的分工与独立旁路开关],
)
]
这套分工的总体收益是清晰的关注点分离：元数据访问（路径解析、`stat`）由上面三级“小而热”的缓存兜住，文件数据由 page cache 兜住，而对块设备的全部访问统一收口在最底层的 block cache。下面几节先看 VFS 与后端，再逐一展开这五级缓存。

== VFS 层与多后端

VFS 的中心抽象是 `VfsNode` trait，三种磁盘后端（easyfs、ext4、fat32）以及各种特殊文件系统都实现它。在它之上，`Inode` 是一个*稳定*的内存包装：持有 `inner: Arc<dyn VfsNode>` 与一份可变运行时状态 `InodeState`，后者正是 stat cache 的宿主，以及 page cache 的挂载点。

`Inode` 的构造统一经过 inode cache：`Inode::from_vfs_node` → `get_or_create_inode`，保证同一个 `(fs_id, ino)` 在内核中只对应一个 `Arc<Inode>`。这一*身份复用*是上方几级缓存得以共享的前提——只有同一文件始终对应同一个 `Inode`，挂在它上面的 page cache 与 stat 快照才能在不同路径（例如硬链接、或重复 `open`）之间自然复用。

路径解析则串起 dentry cache 与 inode cache。`Inode::find(name)` 先查 dentry cache（`(fs_id, parent_ino, name)` → 子 inode），命中即返回；未命中才回落到后端的 `inner.find()`，把结果经 inode cache 包装后，再补登记进 dentry cache。于是第一次解析走完整磁盘路径查找，此后同一分量名全部命中内存。挂载层（`rootfs.rs`）在这之上提供了 `mount`/`umount` 与名字绑定，使 ext4 根文件系统可以与 procfs、tmpfs 等并存于同一棵命名树。

== 磁盘IO：五级缓存与性能实测

=== 五级缓存的设计

+  Stat / Dentry / Inode：元数据三级缓存

   最顶层的 *stat cache* 最朴素也最划算：每次 `stat`/`fstat` 都要读 inode 的元数据（mode、size、nlink、时间戳），而元数据在一次打开期间极少变化。`Inode` 因此缓存最近一次读到的 `VfsAttrs` 快照，任何修改（`create`/`unlink`/`truncate`/`write` 扩容）都会调用 `invalidate_stat_cache` 使其失效，下一次 `stat` 再重新填充。这把重复 `stat` 的代价从“读一次磁盘 inode”降到一次内存读取。

   *Dentry cache* 以 `(fs_id, parent_ino, name)` 为键缓存“名字 → 子 inode”的解析结果，高/低水位 4096/2304，同样采用 CLOCK 回收。它*强持有*子 inode 的 `Arc`，使得即便 inode cache 因自身水位试图回收某 inode，只要它仍被一条热 dentry 指着，就不会被真正释放——这避免了“热路径上的 inode 被反复重建”。`unlink`/`rmdir`/`rename` 会显式失效对应 dentry。

   *Inode cache* 以 `(fs_id, ino)` 为键强持有 `Arc<Inode>`，高/低水位 2048/1536。它的首要职责不是“省磁盘读”，而是*身份去重*：确保同一文件在全内核只有一个 `Inode` 实例。回收采用二次机会：仅当 cache 自身是唯一持有者（`strong_count == 1`）且访问位已清时才真正丢弃，否则给第二次机会。

+ Page cache：文件数据缓存

   Page cache 是体积最大、对 iozone 类负载影响最显著的一级。每个可缓存的 inode 拥有一个 `PageMapping`——一棵以文件内页号为键、`CachePage` 为值的映射，承载文件实际数据的 4 KB 物理页框。每个 `CachePage` 带一组状态位（`UPTODATE`/`DIRTY`/`WRITEBACK`/`LOADING`/`EVICTING`）、一个用于 CLOCK 回收的访问位、以及一条专用的等待队列，用于并发装页/回写时的同步。

   读取走 `read_mapping`：若读取范围落在一页之内、且该页已 `UPTODATE`，就走 `read_mapping_single_page_hit` 这条*单页命中快速路径*，免去整段循环与重复加锁；否则按页逐段装入。写入走 `write_mapping`：把数据拷进对应页、标记 `DIRTY`，并按需把不足一页的写入先用 `ensure_page_uptodate` 补齐。脏页并不立即落盘，而是由 `sync` 或全局回收触发批量回写（`MAX_WRITEBACK_BATCH_PAGES = 32`），这让缓冲写在多数情况下以接近内存的速度完成。

+ Block cache：最底层的块缓存

   Block cache 是所有磁盘访问的收口，缓存粒度为 `BLOCK_SZ = 512` 字节，容量 8192 项，以 `(device_id, block_id)` 为键、FIFO 地回收那些当前未被借用的项。它的两项关键优化直接决定了 iozone 与目录遍历的性能，将在下一节展开。

=== 并发正确性：状态位与每页等待队列

五级缓存不止是一组数据结构，它们还必须在一个多核、随时可能发生并发缺页与回写回收的内核里保持*正确*。上一节列出了 `CachePage` 的状态位与那条“专用等待队列”，这里展开它们究竟如何把本会相互踩踏的并发操作串行化。

每个 `CachePage` 除了承载 4 KB 数据，还带状态位（`UPTODATE`/`DIRTY`/`WRITEBACK`/`LOADING`/`EVICTING`）、一个 CLOCK 访问位、`pin_count`/`map_count` 两个引用计数，以及*一条自己的等待队列*。状态位与等待队列配合，把“装页、回写、回收”这三类操作互斥起来：

+ *并发缺页去重。* 当一个页未命中时，第一个走入的线程置 `LOADING` 并向下发起 I/O；在此期间再有线程缺到同一页，看到 `LOADING` 即在该页的等待队列上入睡，而不是各自再发一次 I/O。装入完成后，装载者置 `UPTODATE` 并 `wake_all`，入睡者醒来直接复用刚装入的页。这一“页锁”模式既避免了重复 I/O，也避免了惊群。
+ *回写与回收互斥。* 正在回写的页置 `WRITEBACK`，回收扫到它便跳过；反之正在回收的页置 `EVICTING`，回写也不再碰它。脏页只有在被 `flush_page` 写干净之后才允许被真正丢弃。
+ *在用页不可回收。* 只要某页 `pin_count > 0`（正被一次 I/O 持有）或 `map_count > 0`（已被映射进某页表，预留给 `mmap(MAP_SHARED)`），回收一律跳过。

同样的“二次机会”骨架（访问位 + 高/低水位 + CLOCK 队列）也复用在 inode 与 dentry 缓存上。其中 inode 缓存多了一条跨层协调规则：仅当某 inode 的 `Arc::strong_count == 1`（即 cache 自身是唯一持有者）时才允许回收，否则给它第二次机会——这保证只要一条热 dentry 仍指向某 inode，该 inode 就不会被释放。block cache 同理：被“借出”（`strong_count > 1`）的块不会被淘汰。这里反复出现的同一个手法——*把 `Arc::strong_count` 当作跨层的“是否在用”信号*——是整套缓存得以安全共享 inode / 页 / 块身份的纪律。

最后，page cache 还参与到*全局*内存回收中：物理页框分配器在分配失败时会回调 `fs::reclaim_if_needed()`，把 page cache 当作一个 shrinker 拉进回收路径（与第四章的内存子系统衔接）。与 inode / dentry 缓存的固定水位不同，page cache 的水位是*动态*的（约 `min(总页数/4, 空闲页/2)`），随内存压力自适应收缩——这使它在内存紧张时主动让出页框，而不是僵在固定阈值上。

=== 读写性能优化与实测

读写性能是本章的重点。我们用 feature flag 逐级旁路每一级缓存，在相同负载下对照“启用 / 关闭”的耗时或吞吐，从而把性能收益精确归因到具体某一级缓存。所有实验均在重启清缓存后进行冷启动测量，随后连续重复以观察热态稳定值；启用 `io_perf_counters` 后还可经 `/proc/io_perf` 读取各级命中数交叉验证。

+ Page cache：iozone 吞吐

   以 `iozone -s 64m -r 4k` 衡量 page cache 对文件数据吞吐的影响。启用 page cache 后，热态的顺序读几乎完全命中内存：

   #figure(image("assets/fs_page_cache_iozone.svg", width: 100%), caption: [Page cache 对 iozone 各项吞吐的影响（64 MB 文件、4 KB 记录，KB/s，对数刻度）。])

   数字相当悬殊。顺序读从约 4943 KB/s 跃升到约 111371 KB/s（约 *22 倍*），重读、`fread`、`freread` 同量级；顺序写从 2558 跃升到 88171 KB/s（约 *34 倍*），这主要得益于脏页的延迟批量回写——写操作只更新内存页便返回，落盘被推迟与合并。值得注意的是*随机读 / 随机写*的提升只有约 3 倍与 2.2 倍：随机访问击穿了顺序预取与页装填的局部性，page cache 的收益自然回落，这恰恰说明前面的高倍数来自局部性，而非缓存本身有什么魔法。

+ Block cache：目录创建与遍历

   Block cache 的价值在元数据密集的负载上最为明显。我们构造一棵 50 层子目录、每层 100 个文件（共 5000 个文件）的目录树，分别测量“创建”与 `tree` 遍历的耗时，并在创建与遍历之间重启以清空缓存：

   #figure(image("assets/fs_block_cache.svg", width: 100%), caption: [Block cache 对目录树创建与遍历的影响（耗时，秒，对数刻度）。])

   创建耗时从约 4 分 05 秒（245 s）降到 1 分 20 秒（80 s），约 *3 倍*——这里 block cache 主要省下的是对 inode 表块、位图块、间接索引块的重复读写。`tree` 遍历的对比则更为戏剧性：冷遍历从约 15.8 s 降到 0.358 s，而热态的第二、三遍从约 15.6 s 直降到 *0.021 s*，快了约两个数量级——遍历反复触碰同一批目录块与 inode 块，block cache 使热态遍历几乎变成纯内存操作。这级缓存之所以放在最底层、覆盖元数据与数据两类块，正是因为目录遍历的开销几乎全在对磁盘块的反复读取上。

+ Inode cache + Dentry cache：重复路径统计

   用 `du -sh /mnt/musl`（测试镜像中的musl libc目录）连续执行 5 次，对照同时启用 / 关闭 inode cache 与 dentry cache 的表现：

   #figure(image("assets/fs_inode_dentry_cache.svg", width: 92%), caption: [Inode + Dentry cache 对重复目录统计 (`du`) 的影响（连续 5 次，第 1 次为冷启动）。])

   第 1 次为冷启动（需填充各级缓存），两者耗时接近，启用缓存甚至略慢——这是 cache 填充本身的开销。但从第 2 次起，热态稳定值从约 *1.0 s* 降到约 *0.29 s*（约 *3.4 倍*）：重复遍历同一棵目录树时，绝大多数路径分量都命中 dentry cache、绝大多数 inode 命中 inode cache，省下了海量后端 `find()` 与 inode 重建。

+ Stat cache：重复列目录

   最后看 stat cache。用 `ls -al` 列一个约 2000 项的目录，连续 5 次：

   #figure(image("assets/fs_stat_cache.svg", width: 92%), caption: [Stat cache 对重复列目录 (`ls -al`) 的影响（连续 5 次，第 1 次为冷启动）。])

   热态稳定值从约 *0.47 s* 降到约 *0.43 s*，提升约 *10%*。这并非 stat cache 设计不佳，而是因为 `ls -al` 的开销早已被上面三级（dentry、inode、block）缓存吸收掉绝大部分，留给 stat 快照去节省的、本需重新读取 inode 元数据的余量已经不多。它的真正价值在于那些“反复 `stat` 同一批文件、却不重新遍历目录”的场景（例如构建系统频繁探测文件时间戳），那里它的相对提升会显著得多。

=== 系统调用入口的微优化

前面几组对照衡量的是*缓存*的收益。但即便五级缓存全部命中，每一次 `read`/`write` 系统调用仍要付出三项*与缓存无关*的固定开销：把 fd 解析成 `FileDescription`（要锁进程的 fd 表）、把用户缓冲区翻译成内核可访问的段（要分配一个 `Vec`）、以及在 `PageMapping` 里定位目标页（一次 BTreeMap 查找）。对 iozone 这类每秒发起上百万次小读写的负载，这些固定开销会压过缓存省下的 I/O。为此，在这条系统调用入口路径上又加了三处微优化：

+ *fd 查找缓存。* 每个 task 本地缓存最近一次解析到的 `Weak<FileDescription>`，并配一个进程级的 `fd_table_generation`（`AtomicUsize`）版本号。命中时只做一次原子读比较、*完全不锁* fd 表；任何改动 fd 表的调用（`close`/`dup`/`open`/`fcntl` …）都会原子递增 generation 使缓存失效。
+ *单页零分配缓冲。* 当一次 I/O 不超过一页、且不跨页边界时，直接经页表 PTE 算出内核映射的物理页内指针返回，*省掉每次 syscall 的 `Vec` 分配*；4 KB 记录恰好整页命中。
+ *每描述符热页缓存。* 在打开文件描述里缓存最近访问的那一页，顺序读时跳过 `PageMapping` 的 BTreeMap 查找，同样以 generation 防过期。

三处优化各有一个单一的旁路点，用一个编译开关 `no_syscall_io_fastpath` 即可整体关停——每处都回落到优化前的原始正确路径，因此这是一个*纯性能、语义不变*的开关。我们在开关开启（快路径）与关闭（旁路慢路径）两种内核下分别构建并跑同一组 iozone，从而把这部分收益单独归因出来：

#[
#set text(0.9em)
#figure(
  table(
    columns: (100pt, 80pt, 80pt, 70pt),
    align: (left, right, right, center),
    [负载（记录 · 类型）], [关闭 KB/s], [开启 KB/s], [加速比],
    [1 KB · 顺序读], [31085], [38306], [1.23],
    [1 KB · 顺序写], [25820], [32705], [1.27],
    [1 KB · 随机读], [17412], [21011], [1.21],
    [1 KB · 随机写], [16270], [19413], [1.19],
    [4 KB · 顺序读], [116790], [144659], [1.24],
    [4 KB · 顺序写], [97778], [129447], [1.32],
    [4 KB · 随机读], [24253], [80547], [*3.32*],
    [4 KB · 随机写], [44577], [76076], [1.71],
    [64 KB · 顺序读], [375928], [373504], [0.99],
    [64 KB · 顺序写], [589278], [624467], [1.06],
    [64 KB · 随机读], [328514], [326111], [0.99],
    [64 KB · 随机写], [461833], [502851], [1.09],
    [256 KB · 顺序读], [928323], [947943], [1.02],
    [256 KB · 顺序写], [948163], [1085534], [1.14],
    [256 KB · 随机读], [883867], [880991], [1.00],
    [256 KB · 随机写], [918115], [1043283], [1.14],
  ),
  caption: [入口微优化开关对照（iozone `-s 64m`，KB/s；“关闭”=旁路慢路径，“开启”=优化快路径；加速比 = 开启 / 关闭）。],
)
]

#figure(image("assets/fs_fastpath_iozone.svg", width: 100%), caption: [入口微优化对 iozone 各项吞吐的影响（64 MB 文件，KB/s，对数刻度；红色标注为开启相对关闭的加速比）。])

数字呈现出一条与五级缓存*截然不同*的曲线。在 1 KB / 4 KB 小记录上，顺序读、顺序写普遍提升 20%–30%（4 KB 顺序写约 *1.32 倍*）；最戏剧性的是 4 KB 随机读，从约 24253 跃升到 80547 KB/s，约 *3.3 倍*——随机访问没有任何局部性可供预取与热页缓存摊薄，每一次随机读都付满一次完整 syscall 的固定开销，此时单页零分配缓冲省下的 `Vec` 分配在单次调用成本里占比最大，收益自然最显著。而一旦记录增大到 64 KB / 256 KB，固定开销被大批量数据摊薄（同样 64 MB 的文件，256 KB 记录只需 256 次 syscall，4 KB 记录却要 16384 次），且大缓冲必然跨页、不再命中单页快速路径，三处优化的收益便迅速回落到约 1.0 倍。这条“小记录受益、大记录无感”的曲线，正是入口微优化作用在*每 syscall 固定成本*而非 I/O 总量上的特征签名，与前面五级缓存“命中即省 I/O”的收益曲线相互补充、互不重叠。

=== 缓存分工的局限：数据块的双重缓存

五级缓存的清晰分工也带来了一个结构性的冗余，值得在这里坦率讨论：*文件数据被缓存了两遍*。

问题的根源在于 page cache 与 block cache 分属两层、且 page cache 位于 `fs` 库*之上*。当 page cache 发生缺页时，`ensure_page_uptodate` 通过 `inode.read_at(...)` 向下取数据；而 `inode.read_at` 属于磁盘 FS 层，最终经 `DiskInode` 调用 `get_block_cache` 读取一个个 512 字节的数据块。也就是说，装入一个 4 KB 页，会让其下的 8 个 512 字节数据块同时进入 block cache：

#figure(image("assets/read_mapping_pagecache_flow.drawio.pdf", width: 100%), caption: [page cache与block cache交互示意图])

结果是一份热文件数据同时占据两份内存：page cache 里的一个 4 KB 页，以及 block cache 里的 8 个 512 字节块（合计约 4 KB）。一旦页面驻留，block cache 中那 8 份数据块拷贝就成了“死重”——它们只在最初装入时派上用场，之后既不会被再次命中（因为读请求已在 page cache 截住），又白白占用着 block cache 的容量。相比之下，元数据块（inode 表、位图、间接索引块）只经 block cache 缓存、page cache 并不触及，这部分*没有*冗余，是 block cache 必须保留的职责。

主流 Linux 的做法是把二者*统一*：page cache 同时就是 block cache，块设备自身被建模为一个 `bdev` inode，它的数据页即为块缓存（早期以 buffer head 挂在页上，现代内核以 folio 为载体），从而保证任何磁盘块在内存中只有一份拷贝。本内核之所以保留两层独立的缓存，有历史与结构两方面的原因：`fs` 库源自 rCore 风格的 easyfs，自带一个独立的 block cache；page cache 是后来在内核层之上补加的，并未引入一个横跨两层的 buffer-cache 抽象。在两个 crate 之间做这种统一改动是侵入性较大的，因此当前的设计以*可接受的内存冗余*换取了分层上的清晰与可独立旁路、便于 benchmark 的好处。

== 特殊文件：pipe 与 tty

并非所有文件都落在磁盘栈上。pipe 与 tty 是两类*完全绕过* VFS 与各级缓存的特殊文件：它们没有磁盘 inode、不经过 page cache、也不触碰 block cache，而是直接在内存中实现 `File` trait，并复用第六章的等待队列与 poll 机制。

pipe 是内核中最基本的 IPC 原语，也是 shell 管道 `|` 的支撑。它由一对读 / 写句柄共享同一个 1 KiB 的环形缓冲区（`Arc<SpinNoIrqLock<PipeRingBuffer>>`）构成。其核心是 `read_nonblocking` / `write_nonblocking` 这对非阻塞操作：缓冲区空且仍有写端时读返回 `EAGAIN`，缓冲区满时写返回 `EAGAIN`，所有写端都关闭时读返回 0（即 EOF）。阻塞型的 `read` / `write` 在此之上循环，遇 `EAGAIN` 便在 `read_wait` / `write_wait` 上入睡，被对端的写 / 读唤醒后重试。poll 就绪检测同样落在这两个队列上，并在最后一个写端关闭时上报 `POLLHUP`；两端的 `poll_source_id` 都指向共享环形缓冲区的地址，因此任一端的状态变化都能经 `notify_poll_source` 唤醒关心它的等待者。pipe 的 `Drop` 会主动唤醒所有阻塞者并广播 `POLLIN | POLLOUT | POLLHUP`，避免对端永远阻塞。

#figure(image("assets/fs_pipe.svg", width: 100%), caption: [pipe 内部结构与常用方法示意图])

tty 则是控制终端与控制台背后的字符设备文件。`TtyCore` 包装一个底层字符设备驱动（NS16550A UART），由 `TtyFile` 暴露为 `File`，并实现一套与 POSIX `termios` 兼容的*行规程*。它的核心职责有四：其一，在*规范模式*下做行编辑——`VERASE` 退格、`VKILL`（`^U`）杀行、行缓冲至换行或 `VEOF`（`^D`）才可读，在*非规范模式*下则退化为立即就绪的原始字节流；其二，回显输入字符（控制字符按 `^X` 渲染）；其三，也是最关键的，把终端控制字符翻译成信号——`VINTR`（`^C`）→ `SIGINT`、`VQUIT`（`^\`）→ `SIGQUIT`、`VSUSP`（`^Z`）→ `SIGTSTP`，经 `deliver_foreground_signal` 投递给前台进程组（与第六章的信号投递衔接）；其四，维护控制终端的会话 / 进程组归属。读取在规范模式下会阻塞直到一整行就绪，输入由外部中断经 `console_receive` 推入——这把 tty 同时接入了第七章那种“中断设标志、统一推进”的事件模型与本章的 poll 就绪源体系。

== 虚拟文件系统

除了三种磁盘后端，内核还在内存中维护着一组*虚拟文件系统*。它们同样实现 `VfsNode`，却不占用任何磁盘空间，内容完全由内核动态生成，承担着设备访问、状态自省、内存暂存等职责：

#figure(
  table(
    columns: (1.0fr, 3fr),
    [虚拟文件系统], [职责],
    [`devfs`], [暴露 `/dev` 下的设备节点（块设备、字符设备、tty 等）],
    [`procfs`], [进程与内核状态自省：`/proc/[pid]/`、`/proc/io_perf` …],
    [`sysfs`], [设备与子系统的层级镜像],
    [`tmpfs`], [内存中的 RAM 文件，读写不落盘],
    [`cgroupfs`], [cgroup 层级与资源控制器接口],
    [`rootfs`], [VFS 命名空间与挂载根（详见下文）],
  ),
  caption: [内核中的虚拟文件系统及其职责],
)

这六者中最值得讨论的是 `rootfs`，因为它的“身份”与 Linux 主流语义*并不一致*。在 Linux 中，`rootfs` 是一种具体的文件系统*类型*（`ramfs` / `tmpfs` 的变体），用作早期启动时挂载 `initramfs` 的载体，本质是一个*存储*层；而挂载命名空间是由独立的 `vfsmount` 树、每挂载点的 superblock 与挂载选项来管理的另一回事。本内核则把这两件事*融合*在了一起：`rootfs.rs` 中的 `VirtualDirNode`（全局实例 `VIRT_ROOT`）是 VFS 命名空间的真正根，它本身*不存储任何数据*，只做两件事——维护一张显式的名字绑定表 `mounts`（支持按名栈式堆叠，模拟同一挂载点的多次叠加），以及持有一个可选的 `overlay`（被覆盖的真实文件系统根）。系统启动时，编译进内核的磁盘文件系统（ext4 / fat32 / easyfs）以*overlay* 的身份挂到 `VIRT_ROOT` 上，于是 `/bin`、`/etc` 等既有路径无需任何改动即可工作；procfs、sysfs、devfs 等则作为 `mounts` 绑定到对应子路径。

这样的设计是一次刻意的取舍。好处是显而易见的：挂载层极薄、完全内核内部化，命名树的组合只需要“查 mounts、再回落 overlay”两条规则，没有 per-mount superblock 与挂载选项机制的开销。代价则是它与 Linux 的术语和模型都有出入：这里的“rootfs”指的是命名空间 / 挂载根，而非一个 ramfs 实例；缺乏每挂载点的选项（如 `noatime`、`lazytime`）与用户态挂载 API，多挂载堆叠也只是朴素的按名栈。对于本内核“单一根盘 + 若干伪文件系统”的目标场景，这种简化是划算的；若要支撑更接近 Linux 的挂载语义，则需要把 superblock 与挂载点拆开。

== 基于 procfs 的性能计数器

第 5.3 节的缓存对照实验需要把性能收益*逐层归因*——每一次缓存命中、未命中、淘汰都要能被精确计数。最朴素的 instrumentation 方法是在热路径里直接 `info!` / `println!` 打日志，但这在本内核里恰恰不可行：串口输出是阻塞式的，在 115200 波特率下每个字节要花约 87 µs，一条约 40 字符的日志行就要耗去约 3.5 ms。而一次 block cache 命中或 page cache 装页本身只有亚微秒到微秒量级——在热路径里打印日志，会让*观测行为本身的代价*比被测操作高出三到四个数量级，彻底扭曲测量结果（典型的观察者效应），尤其是在 cache 命中这种会触发上百万次的热点上。

我们的解法是把计数与渲染*彻底解耦*，只有在必要的时候进行打印。每一个计数器都是一个静态的 `AtomicUsize`，在热路径上只用 `fetch_add(_, Ordering::Relaxed)` 做一次原子自增——这是一条无锁、无 I/O、无格式化的指令，开销在纳秒量级，对定时的扰动可以忽略。而这些原子量的*格式化与输出*，只发生在用户读取 `/proc/io_perf` 的那一刻：`ProcIoPerfNode` 的读取路径调用 `build_io_perf()`，把各层的 `render_perf_counters()` 拼接成一段可读文本返回。也就是说，UART 代价被推迟到一次 `cat` 上，永远不进入热路径；写入该节点则经 `reset_io_perf` 把所有计数器清零，便于在两次 benchmark 之间复位。

`/proc/io_perf` 聚合了整条栈的计数：`vfs`（dentry / stat 命中与未命中）、`block_cache`（命中、未命中、淘汰、平均查找步数）、`ext4`、块设备驱动、`page_cache`（页装入、写映射次数）等。这给出了一份逐层的命中 / 未命中 / 淘汰细目，正是 5.3 节各项对照得以交叉验证的依据。整套机制只在 `io_perf_counters` feature 之后编译进来：关闭时，`#[cfg]` 会同时抹去那些静态计数器与每一个 `perf_inc` 调用点，做到*真正的零开销*；开启时，它又以最小的扰动提供了远比日志精细、且不依赖串口的可观测性。这正是本章能做到“逐级旁路、逐级归因”的方法论基座。