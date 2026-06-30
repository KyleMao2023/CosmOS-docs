// This file should be included in the `main.typ` file.

// 第四章：内存管理 —— 由 main.typ 在 `= 内存管理` 之后 #include。

内存管理是 CosmOS 中最靠近“内核骨架”的子系统之一。它一端连接启动阶段发现的物理内存，负责把可用页框纳入分配器；另一端连接进程管理、文件系统、信号与 SMP 调度，负责为每个进程建立独立的用户地址空间，并在缺页、`fork`、`exec`、`mmap`、`munmap`、`truncate` 等路径上维持页表、物理页、page cache 与 TLB 的一致性。因此，本章不会把内存管理仅仅看作“分配和释放页”的问题，而是把它视为贯穿整个内核的数据面：所有用户态可见的内存语义，最终都要落到这里的一组页表修改、页对象生命周期和跨 hart 同步协议上。

== 设计总览

#figure(image("assets/mm_overview.pdf", width: 96%), caption: [内存管理总体架构示意图])

// 图片生成说明：assets/mm_overview.svg
// 目标：画成三层总览图，与正文一致，突出“基础资源层 -> 地址空间层 -> 运行期机制层”的递进关系。
// 基础资源层：`bootinfo usable regions`、`BuddyFrameAllocator`、`FrameTracker`。箭头可标注“初始化可用页范围”“页框 RAII 封装”。
// 地址空间层：建议分成两个并列分支：
//   - `Kernel Address Space`: `KERNEL_SPACE / PageTable / kernel heap`
//   - `User Address Space`: `MemorySet / VMA + PageTable`
// 运行期机制层：分成两条主线：
//   - 缺页处理路径：`Page Fault` 分支到 `COW / lazy allocation` 和 `Page Cache`
//   - 并发与回收路径：`PageTable update` -> `TLB Shootdown` -> `Deferred Reclaim`
// 重点标注三句话：`VMA 保存语义，PageTable 是硬件状态`；`Page Cache 同时服务 read/write 与 file-backed mmap`；`旧页必须等 shootdown 后释放`。
// 风格：白底、浅色分层、箭头少而关键；不要列 API 或结构体字段。

CosmOS 的内存管理可以按三层来理解。最上面的*基础资源层*负责回答“物理页从哪里来”：启动阶段由 `bootinfo` 收集可用物理内存区间并剔除保留区域，`BuddyFrameAllocator` 将这些页框组织起来，向上提供由 `FrameTracker` 封装的页对象。这里的重点不是单纯分配页号，而是让后续页表页、用户私有页、page cache 页都从同一套物理页来源获得，并由 RAII 句柄表达所有权。

中间的*地址空间层*负责回答“虚拟地址如何被组织”。内核和用户都使用虚拟地址，也都需要页表，但二者的语义不同：`KERNEL_SPACE` 是全局内核虚拟地址空间，管理内核代码数据、direct map、kernel heap window、kernel stack 等长期存在或内核专用的映射；用户空间则是每个进程一份 `MemorySet`，其中 VMA 保存 ELF、heap、mmap、用户栈、trap context 等软件语义，`PageTable` 保存硬件实际可见的页表状态。也就是说，用户空间主要由 VMA 组织语义、由页表承载映射；内核空间同样有虚拟地址和页表，但不依赖用户进程那套 POSIX 风格的 VMA 语义。

最下面的*运行期机制层*负责回答“地址空间如何动态变化”。当用户访问尚未装页的合法地址时，page fault 会根据 VMA 类型进入 lazy allocation、COW 或 file-backed mmap 路径：匿名页、堆和栈通常物化为 `PrivatePage`，`fork` 后的私有页通过 COW 延迟复制，文件映射则接入 `Page Cache`。另一方面，任何会清除、降权或替换 PTE 的路径都不能立即释放旧页，而要先经过 TLB shootdown，再由 deferred reclaim 释放旧页对象。这正是图中把缺页处理和并发回收都放在运行期机制层的原因。

```rust
pub fn init() {
    frame_allocator::init_frame_allocator();
    heap_allocator::init_heap();
    KERNEL_SPACE.lock().activate();
    heap_allocator::init_kernel_heap_mapping();
    heap_allocator::init_heap_virtual_window();
}
```

在操作系统启动初期调用的`init`函数正好对应图中的层次递进：先初始化基础资源层的页框分配器，再建立内核堆所需的早期分配能力，随后激活 `KERNEL_SPACE`，最后补齐 kernel heap window 的按需映射。用户进程的 `MemorySet`、VMA、page fault 与 COW 不在 `mm::init()` 里一次性建立，而是在进程创建、`exec`、`mmap` 与缺页异常中逐步出现；page cache 和 TLB shootdown 也属于运行期路径。换言之，图中的三层不是三个互不相关的模块，而是同一批物理页和页表状态在启动期、地址空间构造期、运行期被不同机制接力管理。



== 地址、页表与体系结构抽象

地址类型与页号封装本身并不是 CosmOS 的特殊之处：几乎所有分页内核都会区分虚拟地址、物理地址、虚拟页号与物理页号。这里真正值得展开的是它们与 HAL 的关系。CosmOS 并没有把 RISC-V Sv39 的 PTE 格式、`satp` 编码、`sfence.vma` 指令散落在 `mm` 模块中，而是把“语义页表”与“架构编码”分成两层：`mm` 层只处理 `PTEFlags::R/W/X/U/V` 这样的语义权限、页表层数和页号索引；具体某一位该写到 PTE 的哪里、根页表 token 应该怎样写入硬件寄存器，则交给 `PagingArch` trait 的实现。

这种分层最先体现在地址构造上。`VirtAddr::from(usize)` 不直接保存用户传来的裸值，而是调用 `hal::normalize_virt_addr_input`；`usize::from(VirtAddr)` 又通过 `hal::canonicalize_vaddr` 转回当前架构期望的规范地址。对 RISC-V 来说，低 39 位地址需要按 Sv39 规则规范化；对 LoongArch64 来说，当前实现则保留输入形式并在页表 walker 配置中解释它。`USER_SPACE_END` 也不是写死的常量，而是由 `hal::virt_addr_bits()` 推导出低半区用户空间上界。这样一来，用户指针检查、`mmap` 自动选址和 `translated_*` 用户缓冲翻译都不需要知道底层地址宽度。

```rust
impl From<usize> for VirtAddr {
    fn from(v: usize) -> Self {
        Self(crate::hal::normalize_virt_addr_input(v))
    }
}

impl From<VirtAddr> for usize {
    fn from(v: VirtAddr) -> Self {
        crate::hal::canonicalize_vaddr(v.0)
    }
}
```

页表项的封装也遵循同样的原则。`PageTableEntry` 在内存中只保存一个 `usize bits`，但外部并不直接解析这些位。新建 PTE 时调用 `hal::make_pte`，读取物理页号时调用 `hal::pte_ppn`，读取权限时调用 `hal::pte_flags`。因此，`mm` 层看到的始终是同一组语义标志，而非某个架构的硬件位布局。

```rust
impl PageTableEntry {
    pub fn new(ppn: PhysPageNum, flags: PTEFlags) -> Self {
        PageTableEntry {
            bits: crate::hal::make_pte(ppn.0, flags),
        }
    }

    pub fn ppn(&self) -> PhysPageNum {
        crate::hal::pte_ppn(self.bits).into()
    }

    pub fn flags(&self) -> PTEFlags {
        crate::hal::pte_flags(self.bits)
    }
}
```

这层抽象在 LoongArch64 上尤其有价值。RISC-V 的非叶子页表项可以近似看作“指向下一级页表的有效 PTE”，默认用 `make_pte(ppn, V)` 就足够；但 LoongArch64 的硬件 walker 对非叶子目录项的解释不同，目录项必须是裸的下一级页表物理地址，不能复用叶子 PTE 的 GNR/GNX 等权限编码。CosmOS 为此在 HAL 中单独提供 `make_dir_entry`，通用页表遍历代码只负责“需要新建下一级页表”，而不负责判断这个目录项应该如何编码。

```rust
fn find_pte_create(
    &mut self,
    vpn: VirtPageNum,
) -> Result<Option<&mut PageTableEntry>, MmError> {
    let levels = crate::hal::page_table_levels();
    let mut ppn = self.root_ppn;
    for level in 0..levels {
        let idx = crate::hal::vpn_index(vpn.0, level);
        let pte = &mut ppn.get_pte_array()[idx];
        if level + 1 == levels {
            return Ok(Some(pte));
        }
        if !pte.is_valid() {
            let frame = frame_alloc_with_reclaim().ok_or(MmError::OutOfMemory)?;
            pte.bits = crate::hal::make_dir_entry(frame.ppn.0);
            self.frames.push(frame);
        }
        ppn = pte.ppn();
    }
    Ok(None)
}
```

这段代码是整个页表层跨架构复用的关键。循环次数来自 `page_table_levels`，每一级索引来自 `vpn_index`，目录项编码来自 `make_dir_entry`，叶子项编码来自 `make_pte`。也就是说，`PageTable` 不知道自己正在服务 Sv39 还是 LoongArch64；它只知道“沿着页号索引向下走，缺哪一级就分配一个页表页”。当前两个架构都使用 39 位虚拟地址、三级页表、每级 9 位索引，但这个事实被封装成 HAL 常量，而不是散落成魔数。若以后扩展到不同层级或不同地址宽度，`MemorySet`、`mmap`、COW、page cache fault 这些上层逻辑无需重写。

#figure(image("assets/mm_page_table.pdf", width: 92%), caption: [地址与页表的 HAL 分层示意图])

// 图片生成说明：assets/mm_page_table.svg
// 目标：画一张三层分层图，说明页表通用逻辑如何通过 HAL 适配不同架构。
// 建议布局：
//   上层：`PageTable / PageTableEntry / VirtAddr`
//   中层：`PagingArch trait`，在框内简要列出 4 组 API：
//     1. 地址参数：`VA_BITS / LEVELS / INDEX_BITS`
//     2. 地址空间 token：`make_token / activate_token / flush_tlb`
//     3. PTE 编解码：`make_pte / make_dir_entry / pte_ppn / pte_flags`
//     4. 页表遍历：`vpn_index / normalize_virt_addr_input / canonicalize_vaddr`
//   下层左右两块：`RISC-V Sv39` 与 `LoongArch64`
// 从上层到中层画箭头，表示通用 mm 代码只调用 HAL；再从 HAL 分别指向两种架构实现。
// 只需标出少量关键差异：token 激活方式不同、PTE 编码不同、LoongArch 需要单独的 `make_dir_entry`。
// 不要画完整多级页表细节；重点是“上层代码复用，架构差异下沉到 HAL”。

页表操作的另一个特点是“修改接口按语义拆开”。`map` 用于安装一个新映射，`clear` 返回被清除的旧 PTE，`update_flags` 只改权限位，`replace` 则同时替换物理页号和权限。这样的接口划分看起来只是工程整洁，实际上服务于后续的 COW、`mprotect`、`munmap` 与 TLB shootdown：调用方能够明确知道一次操作是“新增页”“降权”“拆映射”还是“换页”，从而决定是否需要保留旧页对象、是否需要延迟释放、是否需要向远端 hart 发起 shootdown。

```rust
pub fn update_flags(&mut self, vpn: VirtPageNum, flags: PTEFlags) -> bool {
    let pte = match self.find_pte(vpn) {
        Some(pte) if pte.is_valid() => pte,
        _ => return false,
    };
    let ppn = pte.ppn();
    *pte = PageTableEntry::new(ppn, flags | PTEFlags::V);
    true
}

pub fn replace(&mut self, vpn: VirtPageNum, ppn: PhysPageNum, flags: PTEFlags) -> bool {
    let pte = match self.find_pte(vpn) {
        Some(pte) if pte.is_valid() => pte,
        _ => return false,
    };
    *pte = PageTableEntry::new(ppn, flags | PTEFlags::V);
    true
}
```

最后，用户缓冲区翻译也受益于这套抽象。系统调用拿到的用户指针只是一段用户虚拟地址，内核不能直接解引用；`translated_byte_buffer` 会临时从目标进程 token 构造一个 `PageTable::from_token`，再逐页翻译成内核 direct map 中可访问的物理页切片。这里的 token 仍由 HAL 解析：RISC-V 从 `satp` 风格 token 中取 root PPN，LoongArch64 从 PGDL 风格 token 中取 root PPN。也就是说，即使是 `read(fd, user_buf, len)` 这样普通的系统调用，最终也仍然走“通用页表逻辑 + 架构 token 解释”的同一条路径。

== 物理页帧分配器

页帧分配器采用伙伴系统 (buddy allocator)，这一点并不特殊；特殊之处在于它不是在一个硬编码的 `[ekernel, MEMORY_END)` 区间上工作，而是以 `bootinfo` 解析出的可用物理内存为输入。启动阶段会从设备树中的 `memory` 与 `reserved-memory` 节点收集物理区间，在没有设备树信息时再退回平台 fallback。`init_from_bootinfo` 会把这些区间转换成页号范围，并剔除内核镜像占用的页框，最后把剩余页框按最大可对齐块切入 buddy 的 `free_list`。

```rust
pub fn init_frame_allocator() {
    extern "C" {
        fn skernel();
        fn ekernel();
    }
    FRAME_ALLOCATOR.lock().init_from_bootinfo(
        PhysAddr::from(skernel as usize).floor(),
        PhysAddr::from(virt_to_phys(ekernel as usize)).ceil(),
    );
}
```

这一设计让物理内存布局由平台描述驱动，而不是由内核配置常量单方面假定。它对后续移植很重要：同样的 buddy 代码既可以管理 QEMU 中连续的 DRAM，也可以管理被 firmware、设备 MMIO、保留内存切碎后的多个可用区间。分配器内部维护一个固定大小的 `PpnRegion` 数组，记录当前真正受管理的页号范围；释放时会再次检查目标页是否落在这些范围内，从而防止把内核镜像、设备保留区或未纳管物理页错误塞回空闲链表。

CosmOS 的 buddy 没有为每个空闲块额外分配元数据，而是把“下一空闲块”的页号写入空闲块起始页自身。`push_block` 把块头页加入对应 order 的单链表；`pop_block` 取出一块；`alloc_order` 找不到目标阶时向更高阶借块并逐级拆分；释放时则用 `ppn ^ (1 << order)` 找 buddy，若 buddy 当前也在同阶空闲链表中，就摘下并合并到更高阶。这个设计节省了早期内核最宝贵的常驻元数据开销，代价是只有空闲页可以承载链表指针，分配页在交给调用者前必须清零。

```rust
fn dealloc_order(&mut self, ppn: PhysPageNum, order: usize) {
    let mut ppn = ppn.0;
    let pages = 1usize << order;
    let mut current_order = order;
    while current_order + 1 < MAX_ORDER {
        let buddy = ppn ^ (1usize << current_order);
        if !self.is_managed_range(buddy, 1usize << current_order) {
            break;
        }
        if !self.remove_block(current_order, buddy) {
            break;
        }
        ppn = ppn.min(buddy);
        current_order += 1;
    }
    self.push_block(current_order, ppn);
    self.free_pages += pages;
    self.allocated_pages -= pages;
}
```

对上层而言，页框通常不是裸 `PhysPageNum`，而是 `FrameTracker`。它在创建时清零物理页，并在 `Drop` 时自动调用 `frame_dealloc`。这使得页表页、匿名页、page cache 页都能用 Rust 的所有权表达生命周期：谁持有 `FrameTracker`，谁就拥有这张物理页。对确实需要连续物理页的场景，则使用 `ContiguousFrames`，同样通过 RAII 归还整个连续区间。

== 内核地址空间与内核堆

内核地址空间由全局 `KERNEL_SPACE` 描述，它承担两类完全不同的映射：一类是启动后长期存在的内核代码、数据、trampoline、设备或 direct map；另一类是运行期会增长和回收的 kernel heap window。前者更接近“固定内核视图”，后者则是内核自身动态分配能力的基础。`mm::init()` 的顺序正是围绕这个依赖关系安排的：先有页帧，才能 bootstrap heap；先激活内核页表，才能把后续 heap 虚拟窗口映射成真正可访问的内存。

内核堆采用“两阶段”策略。早期 `init_heap` 只给 allocator 一小段 bootstrap heap，足够支撑后续元数据分配；等 `KERNEL_SPACE` 激活并且 kernel heap window 的页表子树预建完成后，`init_heap_virtual_window` 才启用按需增长。这里的关键优化是 `ensure_subtree_root_untracked`：内核 heap window 被约束在一个根页表项覆盖的范围内，初始化时预先创建这一棵子树的根页表页，后续增长只需要在这棵子树下安装叶子 PTE，不必反复持有全局 `KERNEL_SPACE` 锁从根页表重新走完整路径。

```rust
pub fn ensure_subtree_root_untracked(&mut self, vpn: VirtPageNum) -> PhysPageNum {
    let idx = crate::hal::vpn_index(vpn.0, 0);
    let pte = &mut self.root_ppn.get_pte_array()[idx];
    if !pte.is_valid() {
        let frame = frame_alloc().unwrap();
        pte.bits = crate::hal::make_dir_entry(frame.ppn.0);
        core::mem::forget(frame);
    }
    pte.ppn()
}
```

这段代码中的 `untracked` 并不是泄漏，而是刻意表达“永久内核页表页”的生命周期：它们和内核地址空间同生共死，不应该被某个临时 `PageTable` 的 `frames` 向量回收。对应地，用户地址空间的页表页则由 `PageTable.frames` 持有，随进程地址空间销毁而释放。这种生命周期区分，是内核空间和用户空间共用 `PageTable` 代码时必须保留的边界。

多 hart 下还需要注意一点：地址空间 token 是 per-hart 硬件状态。bootstrap hart 执行 `mm::init()` 后已经激活内核地址空间，但 secondary hart 启动后仍必须调用 `activate_kernel_space()`，把同一个 `KERNEL_SPACE` token 写入自己的硬件寄存器并执行本地 TLB flush。否则，它虽然共享内核代码，却没有共享已经建立好的内核页表视图。

// #figure(image("assets/mm_kernel_space.svg", width: 92%), caption: [内核地址空间与 kernel heap window 示意图])

// 图片生成说明：assets/mm_kernel_space.svg
// 目标：简要表达内核地址空间的组成，以及多个 hart 激活同一个内核页表。
// 建议布局：左侧 `KERNEL_SPACE`，中间一条内核虚拟地址条，右侧 `hart0/hart1/hart2`。
// 地址条只需标出三段：kernel text/data、direct map、kernel heap window。
// kernel heap window 下方画一个小放大框：bootstrap heap -> 预建 heap subtree -> 按需增长。
// 重点标注：内核永久页表页 untracked；每个 hart 都要单独 activate + flush。

== 用户地址空间与 VMA 模型

用户地址空间的核心对象是 `MemorySet`。它只保存三件事：硬件可见的 `PageTable`、软件可见的 VMA 集合，以及当前仍在用户态装载该地址空间的 hart 掩码。前两者分别对应“硬件现在能翻译什么”和“内核认为这段虚拟地址应该是什么”；第三者服务于后文的 TLB shootdown。

```rust
pub struct MemorySet {
    pub page_table: PageTable,
    pub vmas: BTreeMap<VirtPageNum, Vma>,
    loaded_user_harts: AtomicUsize,
}
```

VMA 是 CosmOS 用户内存管理的主元数据。它不仅记录虚拟页号区间和权限，还记录这段内存的语义来源：ELF 段、`brk` 管理的 heap、用户栈、trap context、匿名映射、共享匿名映射、文件映射或 vDSO。和许多简单教学内核不同，CosmOS 不再把“这段地址已经有哪些物理页”简单等同于 VMA 本身，而是在 VMA 内部分成两类页对象：`data_frames` 保存已经物化的私有页，`direct_cache_pages` 保存直接映射进用户页表的 page cache 页。这个划分是后续支持 `MAP_SHARED`、`MAP_PRIVATE` 首次只读共享、COW 与 truncate invalidation 的基础。

```rust
pub struct Vma {
    pub vpn_range: VPNRange,
    pub data_frames: BTreeMap<VirtPageNum, Arc<PrivatePage>>,
    pub map_perm: MapPermission,
    pub kind: VmaKind,
    pub file: Option<FileVma>,
    pub direct_cache_pages: BTreeMap<VirtPageNum, Arc<SpinNoIrqLock<CachePage>>>,
}
```

这套模型的优势在于：页表只是当前硬件状态，VMA 才是可恢复的语义状态。`mprotect` 可以拆分 VMA 并只改权限；`munmap` 可以裁剪或删除 VMA 并把已经 present 的页放入延迟释放批次；file-backed 缺页可以在没有 PTE 的情况下从 VMA 找到 inode、文件页号和共享属性；`fork` 可以根据 VMA 类型决定是共享匿名页、降权私有页，还是继承 direct cache page。换言之，VMA 让“未映射但合法”“已映射私有页”“已映射 page cache 页”这三种状态能够在同一段地址空间中共存。

#figure(image("assets/mm_user_layout.drawio.pdf", width: 92%), caption: [用户地址空间与 VMA 元数据示意图])

// 图片生成说明：assets/mm_user_layout.svg
// 目标：简要表达 `MemorySet`、VMA、页表和页对象之间的关系。
// 建议布局：左侧画一条“用户虚拟地址空间”竖条，按从低地址到高地址的逻辑顺序展示主要区域。图中不要求精确比例；不同平台的 `USER_MMAP_BASE`、`USER_STACK_BASE` 常量位置可能不同，但各区域语义如下：
//   1. `ELF load segments`：程序本体的代码段、只读数据段、数据段和 bss，由 ELF program header 装载，权限来自 ELF 段标志。
//   2. `Heap / brk`：紧接 ELF 最高装载地址之后，`start_brk` 由 ELF 最大结束地址决定，后续通过 `brk/sbrk` 扩展或收缩。
//   3. `vDSO / rt_sigreturn page`：位于 `USER_VDSO_BASE = USER_MMAP_BASE - PAGE_SIZE`，提供用户态信号返回跳板；权限为用户可读可执行。
//   4. `mmap area`：从 `USER_MMAP_BASE` 附近开始自动选址，承载匿名 mmap、file-backed mmap、共享匿名映射和动态装载器后续映射。
//   5. `User stacks`：从 `USER_STACK_BASE` 开始按线程编号分配，每个线程一段 `USER_STACK_SIZE` 用户栈，相邻线程栈之间保留页间隔。
//   6. `TrapContext pages`：靠近 `TRAP_CONTEXT_BASE = TRAMPOLINE - PAGE_SIZE`，按线程编号向低地址分配，每个线程一页，供内核保存/恢复用户 trap 上下文。
//   7. `Trampoline`：最高处的跳板页，映射 trap 入口/返回代码，供用户态和内核态切换时共同使用。
// 中间画 `MemorySet`，内部放 `PageTable` 和 `VMA tree` 两个块。
// 右侧画两类页对象：`data_frames -> PrivatePage` 与 `direct_cache_pages -> CachePage`。
// 用箭头强调：VMA 保存语义，PageTable 是硬件状态；匿名/私有页走 PrivatePage，文件共享页走 CachePage。

== brk、mmap 与按需装页

`brk` 与 `mmap` 的共性是：系统调用阶段优先修改 VMA，而不是急于填满页表。`brk` 改变 heap 的逻辑边界；`mmap` 注册匿名或文件 VMA；真正的物理页分配尽量推迟到第一次访问。这样做可以避免为从未触碰的地址浪费物理页，也让 `fork` 后的大地址空间复制保持轻量。

`mmap(NULL, ...)` 的自动选址依赖 `UserSpaceLayout` 中的 `mmap_base` 和 `mmap_hint`。内核从 hint 开始查找空洞，找到后只登记 VMA；若用户使用 `MAP_FIXED`，则先对目标区间执行 `munmap`，再覆盖登记新映射。这一行为是为了兼容动态链接器常见的“先映射整个 DSO，再用 MAP_FIXED 覆盖其中可写子区间”的模式。

```rust
let chosen = inner
    .memory_set
    .find_free_mmap_area(hint, base, len_aligned)
    .ok_or(ERRNO::ENOMEM)?;

inner.memory_set.mmap_file(
    VirtAddr::from(chosen),
    VirtAddr::from(chosen_end),
    perm,
    file.clone(),
    offset / PAGE_SIZE,
    is_shared,
)?;
```

按需装页路径把慢操作拆到了 page fault 中。对匿名、heap、用户栈这类 framed VMA，第一次读写会分配 `PrivatePage`，安装 PTE，并把页对象放入 `data_frames`。对 file-backed VMA，系统调用阶段不读文件；缺页时先构造 `FilePageFaultPlan`，在合适的位置拿到 page cache 页或私有页，再回到地址空间锁下提交 PTE。这样可以避免在持有进程地址空间锁时执行潜在阻塞的文件 I/O，也让 page cache 与 mmap 之间的锁边界更清楚。

== 缺页异常与写时复制

缺页异常处理首先不是分配页，而是做语义检查：故障地址是否落在用户地址空间，是否命中某个 VMA，当前访问类型是否被 `MapPermission` 允许。只有通过检查后，内核才根据 VMA 类型执行装页。这样的顺序保证了非法写只读映射、执行不可执行页、访问 EOF 之后的文件页时不会被错误地“修复”为一张新页。

写时复制主要服务两条路径：`fork()` 后的私有页共享，以及 `MAP_PRIVATE` 文件页的首次写入。`PrivatePage` 内部持有 `FrameTracker` 和一个 `cow` 原子位。`fork()` 复制地址空间时，不复制已经物化的私有页内容，而是让父子 VMA 的 `data_frames` 指向同一个 `Arc<PrivatePage>`，同时把双方 PTE 降成只读并设置 COW。后续任意一方写入时，如果引用计数说明页面已经独占，就只清掉 COW 并恢复写权限；否则分配新页、复制旧页内容、替换当前 PTE。

```rust
pub struct PrivatePage {
    frame: FrameTracker,
    cow: AtomicBool,
}

pub fn set_cow(&self, cow: bool) {
    self.cow.store(cow, Ordering::Release);
}
```

`MAP_PRIVATE` 文件页还有一个额外优化：读或执行首次缺页时，内核可以直接把 page cache 页以只读方式映射到用户页表，不必立刻复制成私有页。只有第一次写入时，才从 cache page 拷贝出一张新的 `PrivatePage`，并把 VMA 中的 `direct_cache_pages` 条目替换为 `data_frames` 条目。这使得动态链接器加载共享库、读取只读文件段等场景不会因为私有映射而产生不必要的内存复制。

#figure(image("assets/mm_demand_fault_flow.drawio.pdf", width: 95%), caption: [按需装页、缺页分流与写时复制流程示意图])

// 图片生成说明：assets/mm_demand_fault_flow.svg
// 目标：用一张流程图同时覆盖 `brk/mmap` 的按需装页、page fault 分流、lazy allocation、COW、file-backed mmap 与 MAP_PRIVATE 写入物化。图要强调“系统调用阶段登记 VMA，缺页阶段根据 VMA 语义决定装页策略”。
// 建议布局：从左到右的流程图，分成三个阶段：
//   1. 系统调用阶段：
//      `brk/sbrk` -> 调整 `Heap VMA`
//      `mmap` -> 登记 `Anonymous VMA` 或 `File VMA`
//      旁边标注：此时通常只更新 VMA，PTE 可暂时为空，不立即分配物理页。
//   2. 缺页检查阶段：
//      `Page Fault` -> `查找命中 VMA` -> `检查访问权限 R/W/X`
//      若越界、权限不符或文件页超过 EOF，走错误出口：`SIGSEGV / SIGBUS`。
//   3. 装页分流阶段：
//      分成三条主分支：
//        A. `Anonymous / Heap / UserStack` -> `frame_alloc` -> `PrivatePage` -> `安装 PTE`，标注 lazy allocation。
//        B. `fork COW private page` -> 写 fault -> 若独占则恢复写权限；若共享则复制新 `PrivatePage` -> `replace PTE`。
//        C. `File-backed mmap` -> `Page Cache`
//           - `MAP_SHARED`：直接映射 `CachePage`，写入时标脏。
//           - `MAP_PRIVATE`：读/执行先只读共享 `CachePage`，写 fault 时复制成 `PrivatePage`。
// 图中只保留关键节点和少量判断菱形，不要画完整函数调用栈。
// 重点视觉提示：
//   - `VMA` 是所有分流的依据。
//   - `PrivatePage` 表示匿名/私有物化页，`CachePage` 表示文件缓存页。
//   - 写 fault 是 COW 和 MAP_PRIVATE 物化的触发点。
//   - PTE 更新后旧页释放还需要后续 TLB shootdown，本图可用一个很小的虚线提示连接到“Deferred Reclaim”，不用展开。

== Page Cache 与文件映射

CosmOS 的 page cache 以 inode 为粒度维护 `PageMapping`。普通文件 `read/write` 与 file-backed `mmap` 不再各自维护一份页数据，而是共享同一个 `inode -> PageMapping -> CachePage` 结构。`CachePage` 内部持有真实物理页框、文件页号、有效字节数、脏页/回写/装入状态以及等待队列；`PageMapping` 则维护页号到 cache page 的映射、文件逻辑长度和脏页集合。

```rust
pub struct PageMapping {
    inode: Weak<Inode>,
    pages: BTreeMap<u64, Arc<SpinNoIrqLock<CachePage>>>,
    size: usize,
    dirty_pages: BTreeSet<u64>,
}
```

这套统一 page cache 对 mmap 的意义很直接。`MAP_SHARED` 缺页时，用户 PTE 可以直接指向 `CachePage` 的物理页；用户写入后，写 fault 路径把 cache page 标脏，后续 `msync`、`fsync` 或全局同步再把脏页写回底层 inode。`MAP_PRIVATE` 则分两阶段：只读首次访问也可以直接共享 cache page；第一次写入才物化为私有页，之后的修改不再影响 page cache。这正好对应 Linux 风格的“私有映射读共享、写复制”语义。

文件长度变化是 file-backed mmap 中最容易出错的点。CosmOS 在 `truncate/ftruncate` 缩小时，会通过 inode 到进程的弱引用注册表找到可能映射了该 inode 的地址空间，扫描当前 file-backed VMA，清除新 EOF 之后已经 present 的 PTE，并处理尾页 EOF 之后的清零。未 present 的页不需要当场拆除；未来若再 fault 到 EOF 之后，会按新的 page cache 视角文件长度返回 `SIGBUS`。这个策略牺牲了一些反向映射精度，但足以保证当前文件映射语义正确。

== TLB Shootdown 与延迟回收

在单 hart 内核里，清掉 PTE 后执行一次本地 TLB flush，随后释放旧页通常就足够了；在 CosmOS 的 SMP 环境中，这个顺序不成立。另一个 hart 可能仍在用户态运行同一个地址空间，并持有旧 PTE 的 TLB 缓存。如果当前 hart 立刻把旧 `FrameTracker` 归还 buddy，这张物理页可能被重新分配给其他用途，而远端 hart 仍能通过旧 TLB 项写到它，形成严重的悬挂映射。

因此，用户页表修改路径都遵循“锁内摘映射并收集旧页，锁外 shootdown，最后释放旧页”的协议。`MemorySet` 用 `loaded_user_harts` 记录当前仍在用户态装载该地址空间的 hart 集合。`munmap`、`mprotect`、COW 替换、`exec` 旧地址空间 teardown、进程退出、truncate invalidation 等路径会在持锁时快照这个 mask，并把旧 `PrivatePage` 或 direct cache page 放入 `UserReleaseBatch`。锁释放后，`DeferredUserReclaim::flush_then_release` 对这些 hart 发起 address-space shootdown；函数返回时 `UserReleaseBatch` 析构，旧页引用才真正减少。

```rust
pub fn flush_then_release(self) {
    if self.mask != 0 && !self.batch.is_empty() {
        shootdown(self.mask, ShootdownKind::AddressSpace { token: self.token });
    }
    // self 析构时，batch 的 Drop 才真正释放旧页引用。
}
```

全局 shootdown 也被用于内核栈回收。任务退出时，内核栈所在的内核虚拟地址区间可能仍残留在某些 hart 的 TLB 中；如果立即复用同一虚拟地址和页框，远端旧 TLB 同样可能造成破坏。CosmOS 为 kernel stack 设计了 deferred recycle：优先把完整映射的 kernel stack id 放入小缓存以便快速复用；需要真正拆映射时，则把 VA 区间、页框和 stack id 放入全局 deferred 状态，等全局 shootdown 完成后再归还页框与 id。

== 权衡与展望

回顾第四章，CosmOS 的内存管理选择了一条“语义清晰优先”的路线。HAL 把不同架构的页表编码压到 `PagingArch` 后面，使 `MemorySet`、COW、mmap、page cache 等上层机制可以复用同一套页表代码；VMA 保存用户地址空间语义，页表保存硬件当前状态，二者分离后，lazy allocation、`mprotect` 拆分、`munmap` 裁剪和 file-backed fault 都有了明确落点；`FrameTracker`、`PrivatePage`、`CachePage` 和 `UserReleaseBatch` 则把物理页生命周期从裸页号提升为可推导的所有权关系。

这套设计已经支撑了比较完整的用户态内存语义：`brk`、匿名 `mmap`、file-backed `mmap`、`MAP_SHARED`、`MAP_PRIVATE`、fork COW、truncate invalidation、OOM 日志与 page cache reclaim、用户页表 shootdown、kernel stack deferred recycle 都已经接入同一组核心机制。尤其是 page cache 与 mmap 的统一，使普通文件 I/O 和内存映射文件不再维护两份数据；延迟释放协议则让多 hart 下的页表修改不再依赖“刚好没有远端旧 TLB”的运气。

代价也很明确。第一，`MAP_SHARED` 的 dirty tracking 仍是 sticky dirty 的第一阶段实现：写 fault 后会把 cache page 标脏，但还没有形成“写回前清 dirty / 重新 write-protect / 下次写再次通知”的精确闭环。第二，TLB shootdown 仍然偏粗粒度：当前按地址空间 token 触发全量本地 flush，没有 ASID，也没有按 VA range 的精确 `sfence.vma` / `invtlb`。第三，文件映射反向映射仍是 inode 到 process 的弱引用注册表，足够支持保守 truncate invalidation，但还不是 Linux 式 per-page rmap。第四，page cache reclaim 仍是同步触发的简化 CLOCK/second-chance，没有后台 writeback 线程，也没有完整 active/inactive 分层。

#figure(
  table(
    columns: (1.1fr, 1.8fr, 1.8fr),
    [方向], [当前状态], [后续改进],
    [dirty tracking], [`MAP_SHARED` 使用 sticky dirty], [建立精确 dirty 闭环，写回后重新 write-protect],
    [TLB shootdown], [按地址空间全量 flush], [引入 ASID 与按 VA range 精确 flush],
    [file rmap], [inode -> process 弱引用注册表], [扩展为 inode/page -> VMA/page 级反向映射],
    [reclaim], [同步 CLOCK/second-chance], [后台 writeback 与冷热页分层],
  ),
  caption: [内存管理当前取舍与后续方向],
)

这些限制并不改变当前设计的主线：先用较小的机制集合把语义做正确，再逐步把性能和精度补上。未来无论是 ASID、精确 dirty tracking，还是更完整的 page cache rmap，都可以沿着现有分层继续演进：HAL 负责硬件差异，VMA 负责语义，页对象负责生命周期，shootdown 负责跨 hart 可见性。
