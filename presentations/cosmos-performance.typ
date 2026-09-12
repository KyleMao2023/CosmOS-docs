#import "@preview/touying:0.7.4": *
#import themes.simple: *

// CosmOS performance-focused competition deck.
// The design document remains the source of detail; this file is intentionally
// short, visual, and independent from main.typ.
#show: simple-theme.with(aspect-ratio: "16-9")

#set text(
  font: ("Microsoft YaHei", "Arial"),
  lang: "zh",
  region: "cn",
  size: 18pt,
  fill: rgb("#102A43"),
)
#set par(leading: 0.85em, spacing: 0.7em, justify: false)
#set heading(numbering: none)

#let navy = rgb("#102A43")
#let blue = rgb("#1D4ED8")
#let teal = rgb("#0F766E")
#let green = rgb("#047857")
#let orange = rgb("#C2410C")
#let muted = rgb("#5B738B")
#let pale-blue = rgb("#EFF6FF")
#let pale-green = rgb("#ECFDF5")
#let pale-orange = rgb("#FFF7ED")
#let pale-gray = rgb("#F4F9F9")

#let asset(path, width: 100%) = image("../assets/" + path, width: width)
#let viz(path, width: 100%) = image("../visualize/" + path, width: width)

#let asset-full(path) = asset(path, width: 100%)
#let asset-height(path, height) = image("../assets/" + path, height: height)
#let viz-height(path, height) = image("../visualize/" + path, height: height)
#let viz-chart(path) = viz-height(path, 66mm)
#let asset-net(path) = asset-height(path, 78mm)
#let asset-arch(path) = asset-height(path, 78mm)

#let kicker(label, color: blue) = text(size: 10pt, weight: 700, fill: color)[#label]
#let small(label, color: muted) = text(size: 10pt, fill: color)[#label]

#let chip(label, color: blue) = box(
  fill: color.lighten(84%),
  stroke: 0.7pt + color.lighten(55%),
  radius: 4pt,
  inset: (x: 8pt, y: 4pt),
)[#text(size: 10pt, weight: 650, fill: color)[#label]]

#let card(title, body, color: blue, fill: pale-blue) = block(
  fill: fill,
  stroke: 0.7pt + color.lighten(55%),
  radius: 6pt,
  inset: 12pt,
)[
  #text(size: 14pt, weight: 750, fill: color)[#title]
  #v(5pt)
  #text(size: 12pt, fill: navy)[#body]
]

#let metric(value, label, color: blue) = block(
  fill: pale-gray,
  radius: 6pt,
  inset: (x: 12pt, y: 10pt),
)[
  #text(size: 28pt, weight: 800, fill: color)[#value]
  #v(3pt)
  #text(size: 10pt, fill: muted)[#label]
]

#let blue-card(title, body) = card(title, body, color: blue, fill: pale-blue)
#let teal-card(title, body) = card(title, body, color: teal, fill: pale-green)
#let orange-card(title, body) = card(title, body, color: orange, fill: pale-orange)
#let blue-metric(value, label) = metric(value, label, color: blue)
#let green-metric(value, label) = metric(value, label, color: green)

#let two-col(left, right, gutter: 18pt) = grid(
  columns: (1fr, 1fr),
  gutter: gutter,
  left,
  right,
)

#let three-col(a, b, c, gutter: 12pt) = grid(
  columns: (1fr, 1fr, 1fr),
  gutter: gutter,
  a,
  b,
  c,
)

#let flow-node(label, color: blue) = box(
  fill: color.lighten(84%),
  stroke: 1pt + color.lighten(45%),
  radius: 5pt,
  inset: (x: 8pt, y: 8pt),
  width: 100%,
)[#align(center)[#text(size: 11pt, weight: 700, fill: color)[#label]]]

#let blue-flow(label) = flow-node(label, color: blue)
#let teal-flow(label) = flow-node(label, color: teal)
#let orange-flow(label) = flow-node(label, color: orange)
#let green-flow(label) = flow-node(label, color: green)

#let arrow = text(size: 18pt, weight: 800, fill: muted)[→]

== 让真实负载跑起来

#align(center)[
  #v(0.7em)
  #text(size: 36pt, weight: 850, fill: navy)[让真实负载跑起来]
  #v(0.55em)
  #text(size: 17pt, fill: muted)[面向真实用户程序的跨架构 Linux 兼容内核]
  #v(1.1em)
  #line(length: 55%, stroke: 3pt + blue)
  #v(1em)
  #chip[真实负载]
  #h(8pt)
  #chip[性能闭环]
  #h(8pt)
  #chip[RISC-V 64 + LoongArch 64]
  #v(2.2em)
  #text(size: 12pt, fill: muted)[杭州电子科技大学 · CosmOS]
]

== 01 / 优化对象

#kicker[PERFORMANCE TARGET]
#text(size: 27pt, weight: 800, fill: navy)[真实构建把内核的固定成本全部放大]
#v(0.6em)

#three-col(
  blue-card[进程风暴][fork / exec / wait 数百次出现，生命周期成本被重复放大],
  teal-card[缺页风暴][rustc 映射大地址空间，代码页按需进入内存],
  orange-card[元数据 + IPC][openat / statx / pipe / epoll 共同决定构建节奏],
)

#v(0.8em)
#align(center)[
  #text(size: 15pt, weight: 700, fill: muted)[性能问题不是一个慢 syscall，而是多条热路径叠加]
]

== 02 / BuildStorm

#kicker[REAL WORKLOAD]
#text(size: 27pt, weight: 800, fill: navy)[一条 cargo 命令，穿过整个内核]
#v(0.7em)

#grid(
  columns: (1.2fr, 0.15fr, 1.2fr, 0.15fr, 1.2fr, 0.15fr, 1.2fr),
  blue-flow[glibc guest], arrow, teal-flow[cargo / rustc], arrow,
  orange-flow[内核热路径], arrow, green-flow[ArceOS 产物],
)

#v(1em)
#two-col(
  blue-card[负载特征][大量子进程、懒加载代码页、海量小文件、管道与多路等待],
  teal-card[为什么有代表性][它同时检验兼容性、并发、内存、文件系统和调度，不是孤立微基准],
)

#v(0.65em)
#small[数据来源：cosmos_docs/ch9-buildstorm.typ；真实入口位于公共 RISC-V 测试镜像的 /glibc/buildstorm_testcode.sh]

== 03 / 观测闭环

#kicker[MEASURE BEFORE OPTIMIZE]
#text(size: 27pt, weight: 800, fill: navy)[先画像，再优化]
#v(0.45em)

#two-col(
  blue-card[/proc/io_perf][统计读写、缓存、预读、回写和块设备事件；解释“快在哪里”],
  teal-card[/proc/syscalls_count][记录 count / total_ns / avg_ns；解释“时间花在哪里”],
)

#v(0.7em)
#align(center)[#viz-chart("syscalls_count_top15_total_us.svg")]
#small[注意：累计时间包含阻塞等待，wait4 / futex / ppoll 的高值不能直接等同于纯实现开销。]

== 04 / Trap 热路径

#kicker[TRAP PATH]
#text(size: 27pt, weight: 800, fill: navy)[先削固定成本，再动架构]
#v(0.45em)

#two-col(
  asset-full("buildstorm_trap_sweep.svg"),
  [
    #blue-card[四级软件缓存][current task、进程身份、返回工作、trap context]
    #v(8pt)
    #teal-card[架构级收尾][共享内核高半区，减少陷入时的页表切换；ASID 降低无谓 TLB 刷新]
    #v(8pt)
    #small[目标：把“每次 syscall 都付一次”的成本从路径中移走。]
  ],
)

== 05 / fork 与 exec

#kicker[PROCESS LIFECYCLE]
#text(size: 27pt, weight: 800, fill: navy)[把重复工作延后、批量化]
#v(0.6em)

#grid(
  columns: (1fr, 0.18fr, 1fr, 0.18fr, 1fr),
  blue-card[懒 ELF 装载][只先读头部与程序头表；代码页在首次执行时经 page cache 进入内存],
  arrow,
  teal-card[批量 COW][连续页合并成 range，减少逐页页表遍历],
  arrow,
  orange-card[vfork 快路径][共享地址空间直到 exec / exit；不满足安全条件时回退普通路径],
)

#v(1em)
#align(center)[
  #text(size: 19pt, weight: 750, fill: navy)[进程创建的优化，本质是减少“复制—再覆盖”的浪费]
]

== 06 / 文件数据路径

#kicker[FILE DATA PATH]
#text(size: 27pt, weight: 800, fill: navy)[page cache 把磁盘访问变成内存访问]
#v(0.35em)

#two-col(
  asset-full("fs_page_cache_iozone.svg"),
  [
    #blue-metric[22×][顺序读：约 4,943 → 111,371 KB/s]
    #v(8pt)
    #green-metric[34×][顺序写：约 2,558 → 88,171 KB/s]
    #v(8pt)
    #small[随机读 / 写的收益回落到约 3× / 2.2×，符合局部性预期。]
  ],
)

== 07 / 元数据与小 I/O

#kicker[METADATA HOT PATH]
#text(size: 27pt, weight: 800, fill: navy)[缓存命中之后，固定成本仍然值得优化]
#v(0.45em)

#two-col(
  asset-full("fs_fastpath_iozone.svg"),
  [
    #blue-card[路径解析][规范绝对路径走借用快路径；长字符串按页复制，避免逐字节翻译]
    #v(8pt)
    #teal-card[元数据缓存][dentry 分桶 + RwLock + 负缓存；inode cache 复用文件身份]
    #v(8pt)
    #orange-card[用户缓冲][单页小对象直接翻译，跨页对象回退通用路径]
  ],
)

== 08 / 网络栈

#kicker[NETWORK]
#text(size: 27pt, weight: 800, fill: navy)[网络栈：让 I/O 事件进入同一套等待模型]
#v(0.6em)

#two-col(
  asset-net("net_stack.svg"),
  [
    #blue-card[协议核心][smoltcp + VirtIO-net，内核负责 poll socket 与定时推进]
    #v(8pt)
    #teal-card[统一对象][socket 实现 File trait，天然接入 fd、poll 和等待队列]
    #v(8pt)
    #small[中断只留下需要推进的标志，协议处理放到可控的 polling 路径。]
  ],
)

== 09 / 事件机制

#kicker[IPC AND WAITING]
#text(size: 27pt, weight: 800, fill: navy)[cargo 的等待，也需要低开销的统一机制]
#v(0.5em)

#three-col(
  blue-card[管道][jobserver 令牌、消息回传、非阻塞读写],
  teal-card[epoll][边沿触发、eventfd、signalfd 接入同一就绪通知],
  orange-card[futex][按用户地址等待；与信号和超时协同],
)

#v(0.9em)
#align(center)[
  #text(size: 19pt, weight: 750, fill: navy)[统一 File + poll + WaitQueue，让不同 I/O 对象共享一条语义路径]
]

== 10 / 跨架构复用

#kicker[PORTABILITY]
#text(size: 27pt, weight: 800, fill: navy)[同一套优化，落在两种架构上]
#v(0.45em)

#two-col(
  asset-arch("cosmos_process_vm_layout_rv_la.svg"),
  [
    #blue-card[公共层][调度、进程、VMA、COW、page cache、VFS、poll]
    #v(8pt)
    #teal-card[架构层][trap、paging、PTE 编码、TLB、timer、syscall ABI]
    #v(8pt)
    #small[RISC-V / LoongArch 的硬件事实被压到 trait 和 arch 实现，不扩散到优化主线。]
  ],
)

== 11 / 优化方法

#kicker[ENGINEERING LOOP]
#text(size: 27pt, weight: 800, fill: navy)[性能优化不是猜测，而是一条可复现的工程循环]
#v(0.7em)

#grid(
  columns: (1fr, 0.16fr, 1fr, 0.16fr, 1fr, 0.16fr, 1fr),
  blue-flow[采样], arrow, teal-flow[定位], arrow,
  orange-flow[单变量改动], arrow, green-flow[回归验证],
)

#v(1em)
#two-col(
  blue-card[证据来源][内部计数器、耗时探针、相同镜像、相同 QEMU、明确成功标记],
  teal-card[展示原则][只讲能解释的数字；把噪声、阻塞等待和环境差异留在备注中],
)

#v(1em)
#align(center)[
  #text(size: 21pt, weight: 800, fill: navy)[让每一次优化都能回答：为什么有效？代价是什么？如何复现？]
]

== 总结

#align(center)[
  #v(0.7em)
  #text(size: 34pt, weight: 850, fill: navy)[CosmOS]
  #v(0.4em)
  #text(size: 23pt, weight: 800, fill: blue)[用真实负载驱动内核演进]
  #v(1.2em)
  #three-col(
    blue-card[真实][面向 cargo / rustc 等复杂用户程序],
    teal-card[系统][从 trap 到文件、事件和网络的协同优化],
    orange-card[可解释][用观测闭环把性能数字落回具体机制],
  )
  #v(1.6em)
  #text(size: 16pt, fill: muted)[谢谢 · 欢迎提问]
]
