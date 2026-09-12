#!/usr/bin/env python3
"""Render side-by-side file-size pies for the RISC-V Rust toolchain ELFs."""

from __future__ import annotations

from collections import OrderedDict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties


HERE = Path(__file__).resolve().parent
DEFAULT_OUTPUT = HERE.parent / "assets" / "rust_elf_size_pies.svg"

FONT_CANDIDATES = (
    Path("/mnt/c/Windows/Fonts/msyh.ttc"),
    Path("/mnt/c/Windows/Fonts/msyhl.ttc"),
    Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
    Path("/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc"),
    Path("/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"),
)

FILE_SIZES = {
    "cargo": 45_559_552,
    "librustc_driver.so": 300_664_024,
}

BSS_SIZES = {
    "cargo": 21_016 + 496,
    "librustc_driver.so": 708_496 + 12_600,
}

# These groups are formed from the ELF section sizes reported by readelf.
# The final "其他 ELF 元数据" slice closes the accounting gap: ELF headers,
# alignment padding, section headers, .comment, .riscv.attributes, and the
# small gaps between loadable sections.
GROUPS = {
    "cargo": OrderedDict(
        [
            ("代码（.text + .plt）", 18_669_034 + 4_624),
            ("只读数据（.rodata）", 2_675_728),
            ("异常与展开信息", 297_316 + 1_786_972 + 1_807_468),
            ("动态链接与重定位", 8_000 + 7_332 + 23_928 + 42_465 + 1_994 + 256 + 1_928_592 + 6_888),
            ("可写数据与 RELRO", 184 + 8 + 32 + 8 + 1_386_512 + 608 + 70_780 + 9_360),
            ("调试信息（.debug_*）", 3_861_043),
            ("符号与字符串表", 4_998_720 + 7_960_857 + 398),
        ]
    ),
    "librustc_driver.so": OrderedDict(
        [
            ("代码（.text + .plt）", 112_117_006 + 159_392),
            ("只读数据（.rodata）", 58_875_660),
            ("异常与展开信息", 2_266_780 + 13_013_172 + 5_456_288),
            ("动态链接与重定位", 99_780 + 114_620 + 476_592 + 2_432_865 + 39_716 + 288 + 6_984_672 + 239_040),
            ("可写数据与 RELRO", 176 + 5_232 + 8 + 4_653_440 + 592 + 98_720 + 172_344),
            ("调试信息（.debug_*）", 9_682_563),
            ("符号与字符串表", 22_765_248 + 60_986_724 + 368),
        ]
    ),
}

COLORS = [matplotlib.colormaps["GnBu"](value) for value in (0.42, 0.50, 0.58, 0.66, 0.74, 0.82, 0.90, 0.97)]


def plot_font() -> FontProperties:
    for candidate in FONT_CANDIDATES:
        if candidate.is_file():
            return FontProperties(fname=str(candidate))
    return FontProperties(family="DejaVu Sans")


def mib(value: int) -> float:
    return value / 1024 / 1024


def make_groups(name: str) -> OrderedDict[str, int]:
    groups = OrderedDict(GROUPS[name])
    accounted = sum(groups.values())
    remainder = FILE_SIZES[name] - accounted
    if remainder < 0:
        raise ValueError(f"section groups exceed file size for {name}")
    groups["其他 ELF 元数据"] = remainder
    if sum(groups.values()) != FILE_SIZES[name]:
        raise AssertionError(f"file-size accounting does not close for {name}")
    return groups


def pct_text(value: float, total: int) -> str:
    return f"{value / total * 100:.1f}%"


def autopct(value: float) -> str:
    return f"{value:.1f}%" if value >= 2.0 else ""


def render(output: Path) -> None:
    regular = plot_font()
    bold = regular.copy()
    bold.set_weight("bold")

    fig, axes = plt.subplots(1, 2, figsize=(15.2, 8.8), dpi=180)
    fig.patch.set_facecolor("#F5F8FA")
    fig.subplots_adjust(left=0.035, right=0.965, top=0.82, bottom=0.23, wspace=0.12)

    fig.text(
        0.04,
        0.955,
        "RISC-V Rust 工具链 ELF 文件大小构成",
        fontproperties=bold,
        fontsize=21,
        color="#102A43",
        va="top",
    )
    fig.text(
        0.04,
        0.918,
        "按磁盘文件大小归并 section；.bss/.tbss 为 NOBITS，不占文件空间，单独标注",
        fontproperties=regular,
        fontsize=10.5,
        color="#5B738B",
        va="top",
    )

    for ax, name in zip(axes, FILE_SIZES):
        groups = make_groups(name)
        values = list(groups.values())
        total = FILE_SIZES[name]
        legend_font = regular.copy()
        legend_font.set_size(8.5)
        labels = [
            f"{label}  {mib(value):,.2f} MiB ({pct_text(value, total)})"
            for label, value in groups.items()
        ]
        colors = COLORS[: len(values)]

        wedges, _, _ = ax.pie(
            values,
            colors=colors,
            startangle=90,
            counterclock=False,
            autopct=autopct,
            pctdistance=0.70,
            textprops={"fontproperties": regular, "fontsize": 9, "color": "white"},
            wedgeprops={"linewidth": 1.2, "edgecolor": "#FFFFFF"},
        )
        ax.set_title(
            f"{name}\n{mib(total):,.2f} MiB",
            fontproperties=bold,
            fontsize=15,
            color="#102A43",
            pad=12,
        )
        ax.legend(
            wedges,
            labels,
            loc="upper center",
            bbox_to_anchor=(0.5, -0.08),
            ncol=2,
            frameon=False,
            prop=legend_font,
            handlelength=1.0,
            columnspacing=1.0,
            handletextpad=0.45,
            labelspacing=0.8,
        )
        ax.text(
            0.5,
            -0.265,
            f".bss + .tbss：{BSS_SIZES[name] / 1024:.1f} KiB（仅占运行时内存）",
            transform=ax.transAxes,
            ha="center",
            va="top",
            fontproperties=regular,
            fontsize=9,
            color="#5B738B",
        )

    fig.text(
        0.04,
        0.055,
        "最大占比来自 librustc_driver.so 的 .text、.rodata，以及未剥离的 .symtab/.strtab；运行时 LOAD 段并不包含 debug/symbol section。",
        fontproperties=regular,
        fontsize=9.5,
        color="#5B738B",
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, format="svg", facecolor=fig.get_facecolor(), bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    render(DEFAULT_OUTPUT)
    print(DEFAULT_OUTPUT)
