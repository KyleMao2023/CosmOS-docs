# CosmOS performance presentation

这是面向比赛答辩的独立 Typst/Touying 演示文稿，位于 `cosmos_docs/presentations`，不修改 `cosmos_docs/main.typ`。

## 页序

封面之后按“负载 → 观测 → 热路径 → 方法”推进：

- 01–03：真实构建的性能对象、BuildStorm 负载、`/proc` 观测闭环
- 04–07：trap、fork/exec、page cache、元数据与小 I/O
- 08–10：网络栈、事件机制、RISC-V / LoongArch 跨架构复用
- 11：采样—定位—单变量改动—回归验证
- 结尾：三条定性 takeaway，不放正确性边界页，也不放总体成绩页

## 生成 PDF

在 Windows PowerShell 中，从仓库根目录执行：

```powershell
.\cosmos_docs\presentations\build.ps1
```

等价的直接命令是：

```powershell
typst compile --root cosmos_docs cosmos_docs/presentations/cosmos-performance.typ cosmos_docs/presentations/cosmos-performance.pdf
```

实时预览：

```powershell
typst watch --root cosmos_docs cosmos_docs/presentations/cosmos-performance.typ cosmos_docs/presentations/cosmos-performance.pdf
```

## Linux / WSL 编译与排版检查

如果 Linux/WSL 能调用 Windows 的 `typst.exe`，可以运行：

```bash
bash cosmos_docs/presentations/build-and-check.sh
```

脚本会自动尝试本机 `typst`、`typst.exe`，以及 MiKTeX 的常见安装路径。也可以显式指定你给出的路径：

```bash
TYPST_BIN='/mnt/c/Program Files/MiKTeX/miktex/bin/x64/typst.exe' \
  bash cosmos_docs/presentations/build-and-check.sh
```

也支持直接传入 Windows 形式的路径：

```bash
TYPST_BIN='C:/Program Files/MiKTeX/miktex/bin/x64/typst.exe' \
  bash cosmos_docs/presentations/build-and-check.sh
```

它会检查 Typst 编译诊断、PDF 页数、16:9 尺寸、标题是否丢失、文字坐标是否明显越界，并用 Typst 直接输出 PNG 缩略图。总览图和日志位于 `cosmos_docs/presentations/.preview/`；自动检查不能替代最终人工看一遍总览图。如果源目录在 Linux 中只读，可把 PDF 和检查目录重定向到 `/tmp`。

## 生成 PPTX 备份

PDF 是比赛现场主版本。若已安装 `typ2pptx`，可以额外生成可编辑备份：

```powershell
.\cosmos_docs\presentations\build.ps1 -Pptx
```

等价的直接命令是：

```powershell
typ2pptx cosmos_docs/presentations/cosmos-performance.typ -o cosmos_docs/presentations/cosmos-performance.pptx --root cosmos_docs
```

复杂 SVG/PDF 图表在 PPTX 中可能被栅格化；应以 PDF 版检查最终清晰度。

## 资产与数据

演示文稿从所在目录的上级路径读取 `../assets/` 和 `../visualize/` 中的 SVG 图表。

候选数字记录在 [data/metrics.csv](data/metrics.csv)。其中 `draft-candidate` 表示来自设计文档的当前候选值，不代表最终比赛数据。定稿前应使用同一内核版本、QEMU 配置和 workload 成功标记重新验证。

推荐字体优先级：`Microsoft YaHei`、`Arial`。
