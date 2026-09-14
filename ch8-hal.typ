// 硬件抽象层：保留跨架构边界及两种分页实现的关键差异。

== 三层边界

HAL 将硬件依赖分成接口契约、架构实现和平台实例。hal/traits 定义中立的陷阱原因、页表标志、定时器、上下文及中断接口；arch/riscv 与 arch/loongarch64 提供寄存器、汇编入口和分页操作；platform 层负责 QEMU virt 设备、中断路由、时钟与多 hart 启动。

内核主体调用统一 trait，不直接读写某一架构的陷阱寄存器或页表控制寄存器。新增架构时，必须实现同一接口契约，但不需要复制调度、VFS、网络和进程管理主体逻辑。

#figure(image("assets/hal-circle.svg", width: 64%), caption: [HAL、架构实现与平台模块的目录边界])

== 关键架构差异

#[#set text(0.9em)
#figure(
  table(
    columns: (1.3fr, 2fr, 2fr),
    [能力], [RISC-V 64], [LoongArch 64],
    [分页控制], [Sv39 与 satp；sfence.vma 维护翻译一致性], [页表遍历配置与 invtlb 操作],
    [陷阱上下文], [由 trap 汇编保存通用/特权状态], [由对应入口保存 ERA、异常状态和通用寄存器],
    [内核映射], [高半区共享映射与物理 direct map], [DMW 直接映射窗口与架构页表映射协作],
    [平台职责], [时钟、中断控制器、VirtIO 与 SMP 启动], [对应平台设备、中断与 SMP 启动],
  ),
  caption: [RISC-V 与 LoongArch 的差异及共同接口],
)
]

#figure(image("assets/hal_pagingarch.pdf", width: 100%), caption: [PagingArch 对不同硬件页表语义的封装])

跨架构抽象不是抹平硬件差异，而是把差异限制在可验证的实现边界内。页表遍历、陷阱恢复和 TLB 操作仍由各架构实现，通用内存管理只依赖统一语义；同一套内核主体因此可以在两种 QEMU 架构目标上复用。

陷阱入口由架构汇编保存寄存器帧，TrapMachine 将不同异常寄存器规范化为统一原因和故障地址；SyscallAbi 提供系统调用号、参数与返回值访问，SignalAbi 提供用户信号帧布局。策略字段与系统调用分发仍由共享内核维护，减少两套架构之间的语义漂移。

平台与 ISA 也保持正交：trap 编码、PTE 语义和指令属于 arch；时钟源、中断控制器、VirtIO 槽位和次级 hart 启动属于 platform。RISC-V 平台经 SBI 配置时钟/IPI，LoongArch 平台使用自身中断控制器及 IOCSR 路径。该边界允许相同 ISA 适配不同板级启动和设备布局，而无需把这些差异塞入通用调度器或 VFS。
