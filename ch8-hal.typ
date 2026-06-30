// 第八章：硬件抽象层 —— 由 main.typ 在 `= 硬件抽象层` 之后 #include。

硬件抽象层（HAL）是本内核能够在两套截然不同的指令集架构上以同一份核心代码运行的根基。内核同时面向 RISC-V 64 与 LoongArch 64 两种架构，二者在寄存器组、页表编码、异常与中断入口、TLB 语义乃至中断控制器上都差异巨大。HAL 的任务，就是把这些差异封装在一组*纯粹的 trait 接口*与若干体系结构相关的汇编桩之后，使调度器、内存管理的多级页表遍历器、文件系统、网络栈、信号子系统与系统调用分发等“内核主体”完全感受不到自己跑在哪一种 CPU 上。本章先给出 HAL 的分层与选择机制，再依次讨论中断与陷阱抽象、分页抽象、hart 与浮点抽象、平台（板级）抽象，最后总结这一设计带来的解耦收益与权衡。

== 设计目标与分层

HAL 把硬件相关性切成三层。最底层是 `hal/traits.rs`，它只定义接口与若干架构中立的值类型——`PTEFlags`（页表项语义位 V/R/W/X/U/G/A/D）、`TrapCause`（归一化的陷阱原因）、`TrapInfo`（陷阱原因加故障地址）、`CloneArgs`（归一化的 `clone` 参数）、`NamedReg`（带名字的寄存器，用于故障转储），以及一整套 trait：`InterruptControl`、`TrapMachine`、`TrapContextAbi`、`SyscallAbi`、`SignalAbi`、`HartId`、`PagingArch`、`Timer`、`HartCtrl`。这一层没有任何实现，是 HAL 的“契约”。

中间层是 `arch/` 目录下的两套具体实现：`arch/riscv` 与 `arch/loongarch64`，各自提供上述 trait 的具体类型（如 `Sv39Paging`、`RiscvTrapMachine`、`LoongArchPaging`），以及一段极薄的汇编（`trap.S` / `entry.S` / `switch.S`）。最上层是 `platform/` 目录下的板级抽象：`platform/riscv/qemu_virt` 与 `platform/loongarch/qemu_virt`，负责内存布局常量、MMIO 与 virtio 槽位、时钟、设备实例化、中断路由、SMP 启动与 IPI。

把这三层粘合起来的，是一个基于编译目标的别名机制。`hal/mod.rs` 用 `#[cfg(target_arch = "...")]` 把当前架构的具体类型重新导出为一组*稳定的别名*：

```rust
#[cfg(target_arch = "riscv64")]
pub use crate::arch::riscv::{
    RiscvHartId as ArchHart, RiscvInterruptControl as ArchInterrupt,
    RiscvTrapMachine as ArchTrapMachine, RiscvTrapContextAbi as ArchTrapContextAbi,
    RiscvSignalAbi as ArchSignalAbi, RiscvSyscallAbi as ArchSyscallAbi,
    Sv39Paging as ArchPaging,
};
#[cfg(target_arch = "loongarch64")]
pub use crate::arch::loongarch64::{
    LoongArchHartId as ArchHart, LoongArchInterruptControl as ArchInterrupt,
    LoongArchTrapMachine as ArchTrapMachine, /* ... */ LoongArchPaging as ArchPaging,
};

pub use crate::platform::PlatformImpl as Plat;
```

内核主体从不直接引用 `RiscvTrapMachine` 或 `LoongArchPaging` 这类带架构前缀的符号，而是统一使用 `ArchTrapMachine`、`ArchPaging`、`Plat` 这些别名，或者更常用的是 `crate::hal::` 下的一组薄封装函数（如 `hal::hartid()`、`hal::activate_address_space()`、`hal::flush_tlb()`）。这样一来，“当前架构”是一个编译期常量，所有跨架构的分发都在编译期完成，没有任何运行时开销，也没有虚函数表。

HAL 对外暴露的能力可以归纳为下表：

#figure(
  table(
    columns: (1.5fr, 2.4fr, 1.3fr),
    [能力], [典型方法], [实现方],
    [中断控制], [启用/禁用 timer/external/software、切换陷阱入口], [架构层],
    [陷阱机器], [读陷阱原因、返回用户态、系统调用指令长度], [架构层],
    [陷阱上下文], [读写寄存器/PC/SP、导出信号 GPR 与浮点状态], [架构层],
    [分页], [构造/解析 PTE、激活地址空间、刷 TLB、多级索引], [架构层],
    [hart 与浮点], [读 hart 号、开关本地中断、使能 FPU、空闲等待], [架构层],
    [时钟], [读单调时间、设定下次中断], [平台层],
    [hart 生命周期], [启动次级 hart、发送 IPI], [平台层],
  ),
  caption: [HAL 对外暴露的能力及其实现归属],
)

这里有一个关键的划分：凡是只取决于*指令集*的能力（寄存器、页表编码、陷阱帧、浮点）由*架构层*实现；凡是取决于*板级与固件*的能力（定时器设备、中断控制器、核间中断、SMP 启动）由*平台层*实现。同一种架构可以搭配不同的板子，因此把后者从架构层剥离出去是必要的。

#figure(image("assets/hal-circle.svg", width: 60%), caption: [各目录文件约定示意图])

== 中断、陷阱与上下文抽象

`InterruptControl` 抽象的是每 hart 的中断开关与陷阱入口切换。在 RISC-V 上，它映射到 `sie`（supervisor 中断使能）的 timer/external/software 位、`sip` 的软件中断挂起清除，以及 `stvec` 的陷阱入口；在 LoongArch 上，它映射到 `ECFG` 的中断使能位、`ESTAT` 的挂起清除，以及 `EENTRY` 的异常入口。其中“切换陷阱入口”有一个跨架构一致的语义：在内核态运行时把入口指向 `__trap_from_kernel`，准备返回用户态时再切回 trampoline 入口，这一对操作被封装为 `set_kernel_trap_entry` / `set_user_trap_entry`，使调度器无须知道入口究竟写进了哪个 CSR。

`TrapMachine` 抽象的是陷阱的解读与返回。`read_trap_info` 把架构特定的原因寄存器归一化为统一的 `TrapCause`——RISC-V 解码 `scause`，LoongArch 解码 `ESTAT` 的 ecode/esubcode（SYS、各类页错误、地址错 ADEF/ADEM、中断）——并把故障地址统一从 `stval` 或 `badv` 读出。`return_to_user` 完成从内核返回用户态的最后一步：两套架构都采用一个共享的 *trampoline 页*，把入口/恢复汇编 (`__alltraps` / `__restore`) 以相对偏移安放进 trampoline，返回时跳到 `__restore` 在 trampoline 中的对应位置，并把陷阱上下文用户地址与地址空间 token 经由第一、第二参数寄存器传入。差异只在细节：RISC-V 在跳转前发 `fence.i` 同步指令缓存，LoongArch 发 `ibar 0`。`syscall_instruction_len` 与 `rt_sigreturn_trampoline` 则把“系统调用指令多长”与“`rt_sigreturn` 跳板的机器码”这两项架构事实暴露给第六章的信号重启逻辑。

最体现设计 seam 的是陷阱上下文。`TrapContext` 是一个 `#[repr(C)]` 结构，它的前半部分是架构拥有的寄存器帧 `ArchTrapContextAbi::Frame`（由 trampoline 汇编直接读写），后半部分是几个架构中立的字段：

```rust
pub struct TrapContext {
    pub arch: <ArchTrapContextAbi as TrapContextAbi>::Frame, // 架构拥有的寄存器帧
    pub in_syscall: bool,        // 本次陷阱是否源自系统调用
    pub orig_a0: usize,          // 系统调用覆写 a0 之前的原始第一参数
    pub restartable_syscall: bool, // 被打断的调用是否可经 SA_RESTART 重启
}
```

架构只负责自己那片寄存器帧的字节布局，并提供一组访问器（读写通用寄存器、`PC`、`SP`、`ra`、TLS、系统调用号与参数、信号用的 32 项 GPR 导入导出、浮点状态的拷出与恢复、故障转储用的命名寄存器）。而“是否处于系统调用中、原始 a0、是否可重启”这些*策略性*字段，连同它们支撑的 `SA_RESTART` 重启机制，完全是架构中立的——这正是第六章能在两套架构上共用一套信号栈帧与重启逻辑的原因。

== 地址空间与分页抽象

`PagingArch` 是 HAL 中最具匠心的一个 trait，因为它是一个*常量泛型 trait*：把物理地址宽度、虚拟地址宽度、页表级数、每级索引位数都作为关联常量暴露。内核内存管理子系统的多级页表遍历器就是对这个 trait 泛型的，因此“逐级取索引、向下走表、命中叶子”这一整套逻辑只写一遍，两种架构共享同一份遍历器。两种架构恰好都是 3 级、9 位索引、39 位虚拟地址，但抽象并不依赖这一巧合——它支持任意级数与位宽。

PTE 的语义位用架构中立的 `PTEFlags` 表达，由 `make_pte` / `pte_flags` 在两种编码间翻译。下表对比了两套实现：

#figure(
  table(
    columns: (1.25fr, 1.9fr, 1.9fr),
    [维度], [RISC-V Sv39], [LoongArch],
    [地址空间 token], [`MODE=8 << 60 | ppn`（写入 `satp`）], [`ppn << 12`（写入 `PGDL`）],
    [激活与 TLB 刷新], [`satp` 写 + `sfence.vma`], [`PGDL`/`ASID` 写 + `invtlb`，配 `dbar`/`ibar`],
    [叶子 PTE 编码], [`ppn << 10 | flags`], [`ppn << 12`，含 PLV/MAT 位],
    [读写执行权限], [R/W/X 位“置位即允许”], [GNR/GNX 位“置位即*禁止*”（反相语义）],
    [目录项], [复用叶子编码（带 V 位）], [*裸下一级表指针*（不得带权限位）],
    [页表遍历], [硬件按 `satp` 模式隐式遍历], [由 `PWCL`/`PWCH` 配置的硬件遍历器 + TLB 重填处理],
  ),
  caption: [两种架构的分页实现对比],
)

两处差异尤其值得玩味。其一是 LoongArch 的*反相权限语义*：它没有直接的“可读/可执行”位，而是用 `GNR`/`GNX`（全局不可读/不可执行）来表达——要禁止读或执行，就把对应位置 1。`make_pte` 因此写成“若 `!R` 则置 `GNR`，若 `!X` 则置 `GNX`”，与 RISC-V“置位即允许”的直觉完全相反，是一个极易写反的陷阱。其二是目录项：LoongArch 的硬件页表遍历器把非叶子目录项当作“下一级表的物理地址”直接消费，*不得*带上任何叶子式的权限位（否则会被误判为叶子）。为此 trait 提供了一个可覆盖的 `make_dir_entry`，默认实现复用叶子编码，而 LoongArch 重写为裸指针，并在接口注释里明确点名了这条约束。这两处正是 HAL 通过“默认实现 + 按需覆盖”来吸收架构差异的典型范例。

#figure(image("assets/hal_pagingarch.pdf"), caption: [`PagingArch` 中RV与LA的差异封装示意图])

== hart、本地中断与浮点

`HartId` 抽象的是每个 hart 的本地身份与状态。读 hart 号在两套架构上有本质区别：RISC-V 没有直接的 hart-id 寄存器，内核在启动时由软件把 hart 号存入 `tp` 寄存器，此后 `current()` 即读 `tp`；LoongArch 则直接从 `CPUID` CSR 读取，`init()` 因此是个空操作。浮点的使能同样分道扬镳：RISC-V 写 `sstatus.FS`，LoongArch 写 `EUEN.FPEN`。本地中断的开关与检测，RISC-V 用 `sstatus.SIE`，LoongArch 用 `CRMD.IE`；空闲等待一个用 `wfi`，一个用 `idle 0`。这些差异都被收拢到一组统一的方法名之下。

其中本地中断的开关尤为要紧，因为它是 SMP 正确性的基石。HAL 提供了一个 RAII 守卫 `LocalIrqSave`：构造时记录中断是否开启并关闭之，析构时（包括上下文 `__switch` 之后隐式恢复调用者时）还原原状。第六章论述的那段“唤醒/阻塞竞态”之所以能被关闭，靠的正是把 `take_current_task` 到 `schedule` 的过渡关在这个守卫之内，使同 hart 的硬中断无法观察到半阻塞状态。换句话说，`LocalIrqSave` 不仅仅是个便利封装，它直接承载了一个关键的 SMP 不变式。

浮点状态还经由 `TrapContextAbi` 的 `copy_fp_state_to` / `restore_fp_state` 进入信号栈帧，与第六章的信号投递衔接。需要留意的是，当前用户态二进制是纯标量的，因此 64 位浮点上下文的保存已足够；但 LoongArch LA464 拥有 LSX/LASX 向量扩展，未来若启用向量代码，浮点状态的保存范围需要相应扩展。

== 平台层与板级抽象

平台层与架构层的分工，体现了“指令集”与“板子”是两个正交的维度。`platform/` 不是一个 trait，而是一个按编译目标选择的扁平模块，它提供一组成型的常量与函数：内存布局（`TRAMPOLINE`、`KERNEL_ADDR_OFFSET`、`KERNEL_HEAP_BASE`、`USER_STACK_BASE`、`USER_MMAP_BASE`）、MMIO 与 virtio 槽位（`VIRTIO_MMIO_BASE` / `_IRQ_BASE` / `_SLOTS` / `_STRIDE`）、时钟频率 `CLOCK_FREQ`、块设备与字符设备的具体类型（`BlockDeviceImpl` / `CharDeviceImpl`），以及一个 QEMU 退出句柄。

平台层还实现了 `Timer` 与 `HartCtrl` 这两个 trait——它们之所以放在平台层而非架构层，是因为它们依赖的是*板级与固件*设施：定时器设备、中断控制器、核间中断与 SMP 启动协议。在 RISC-V 上，这些经由 SBI 固件调用完成（`start_hart` 走 SBI 的 hart 启动扩展，`send_ipi` 走 SBI 的 IPI 扩展，时钟由 SBI 的 timer 服务设定）；在 LoongArch 上，则直接操作 EXTIOI 中断控制器与 IOCSR 的 IPI 寄存器，时钟由 `TCFG`/`TICLR` 倒计数。`platform::init()` 依次完成 RTC 初始化、外部中断路由配置与平台设备探测，`init_local_hart()` 与 `clear_ipi()` 则处理每 hart 的本地 IPI 状态。SMP 的次级 hart 启动（`start_secondary_harts`）也由平台层负责——同一架构、不同板子的启动方式可能完全不同，这正是把它归入平台层的理由。

== 贯穿全内核的解耦收益

HAL 的价值，最终体现在它让“内核主体”与“硬件”彻底解耦。前几章描述的所有机制——第六章的信号投递、栈帧构造与系统调用重启，调度器的唤醒/阻塞竞态防护，第七章整个网络栈的软中断驱动，以及内存管理的页错误处理与系统调用分发——都是架构中立的，它们通过 `crate::hal::` 的封装与 `Arch*` 别名间接使用硬件能力，从不直接触碰任何架构寄存器。

一个直接的佐证是 LoongArch 的引入本身。内核最初只有 RISC-V 后端；在 HAL 已就位的前提下，新增 LoongArch 64 支持被收敛为一项有界的、近乎机械的工作：实现 `PagingArch`、`TrapMachine`、`TrapContextAbi`、`InterruptControl`、`HartId`、`SignalAbi`、`SyscallAbi` 这一组 trait，移植三段汇编桩（陷阱入口、上下文切换、初始入口），再补一个 `platform/loongarch/qemu_virt` 平台模块。内核主体一行未改，便在第二套架构上跑通了多 hart、网络与全套用户态测试。这正是一个设计良好的 HAL 应有的样子：移植的边界清晰，移植的工作量可预估。