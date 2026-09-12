#!/usr/bin/env python3
"""Render the top timing rows of a syscall counter CSV as a table.

The input is expected to contain a ``total_ns`` column.  Rows are sorted by
that column, the first ten are retained, and the displayed column is changed
to ``total_us``.  Each ``total_us`` cell contains a pale proportional bar.

Examples:

    python3 plot_top10_total_us.py
    python3 plot_top10_total_us.py syscalls_count.csv -o top10.svg
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
from matplotlib.patches import Rectangle


HERE = Path(__file__).resolve().parent
DEFAULT_INPUT = HERE / "syscalls_count.csv"
FONT_CANDIDATES = (
    Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
    Path("/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc"),
    Path("/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"),
)


def plot_font() -> FontProperties:
    """Use a CJK-capable font when one is available on the host."""

    for candidate in FONT_CANDIDATES:
        if candidate.is_file():
            return FontProperties(fname=str(candidate))
    return FontProperties(family="DejaVu Sans")


def parse_number(value: str, *, row_number: int, column: str) -> float:
    """Parse a CSV number while accepting commas and scientific notation."""

    cleaned = value.strip().replace(",", "")
    try:
        number = float(cleaned)
    except ValueError as exc:
        raise ValueError(
            f"row {row_number}: column {column!r} is not numeric: {value!r}"
        ) from exc
    if not math.isfinite(number):
        raise ValueError(f"row {row_number}: column {column!r} is not finite")
    return number


def read_counter_table(path: Path) -> tuple[list[str], list[dict[str, str]], str]:
    """Read the counter table and return fields, rows, and the total_ns field."""

    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if not reader.fieldnames:
            raise ValueError(f"{path} does not contain a CSV header")

        fields = [field.strip() for field in reader.fieldnames]
        total_field = next(
            (field for field in fields if field.lower() == "total_ns"), None
        )
        if total_field is None:
            raise ValueError(
                f"{path} must contain a total_ns column; found {fields!r}"
            )

        rows: list[dict[str, str]] = []
        for row_number, raw_row in enumerate(reader, start=2):
            if not raw_row or all(not str(value or "").strip() for value in raw_row.values()):
                continue
            row = {field: str(raw_row.get(field, "") or "").strip() for field in fields}
            parse_number(row[total_field], row_number=row_number, column=total_field)
            rows.append(row)

    return fields, rows, total_field


def numeric_text(value: str) -> str:
    """Make numeric columns compact while leaving syscall names untouched."""

    try:
        number = float(value.replace(",", ""))
    except ValueError:
        return value
    if not math.isfinite(number):
        return value
    if number.is_integer():
        return f"{int(number):,}"
    return f"{number:,.3f}"


def format_cell(field: str, row: dict[str, str], total_field: str) -> str:
    """Format one displayed cell, converting only total_ns to total_us."""

    if field == total_field:
        total_us = parse_number(row[total_field], row_number=0, column=total_field) / 1_000.0
        return f"{total_us:,.3f}"
    return numeric_text(row[field])


def column_widths(fields: list[str], display_rows: list[list[str]]) -> list[float]:
    """Return relative widths that keep names and timing columns readable."""

    weights: list[float] = []
    for index, field in enumerate(fields):
        longest = max(
            [len(field)] + [len(row[index]) for row in display_rows],
        )
        weight = max(1.0, min(float(longest) / 8.0, 3.8))
        lowered = field.lower()
        if lowered == "name":
            weight += 0.9
        elif lowered in {"total_us", "avg_ns"}:
            weight += 0.35
        weights.append(weight)
    total = sum(weights)
    return [weight / total for weight in weights]


def render_table(
    *,
    input_path: Path,
    output_path: Path,
    fields: list[str],
    rows: list[dict[str, str]],
    total_field: str,
    top_n: int,
) -> None:
    """Render a clean table with a proportional total_us background bar."""

    ranked = sorted(
        rows,
        key=lambda row: parse_number(row[total_field], row_number=0, column=total_field),
        reverse=True,
    )[:top_n]
    if not ranked:
        raise ValueError("the counter table contains no data rows")

    # Keep the original column order, replacing total_ns in-place with total_us.
    display_fields = ["total_us" if field == total_field else field for field in fields]
    display_rows = [
        [format_cell(field, row, total_field) for field in fields] for row in ranked
    ]
    total_values_us = [
        parse_number(row[total_field], row_number=0, column=total_field) / 1_000.0
        for row in ranked
    ]
    max_total_us = max(total_values_us)
    bar_column = display_fields.index("total_us")
    widths = column_widths(display_fields, display_rows)

    regular_font = plot_font()
    bold_font = regular_font.copy()
    bold_font.set_weight("bold")
    figure_height = max(4.8, 2.15 + 0.48 * len(ranked))
    fig, ax = plt.subplots(figsize=(13.2, figure_height), dpi=180)
    fig.patch.set_facecolor("#F4F9F9")
    ax.set_facecolor("#F4F9F9")
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    left, right = 0.035, 0.965
    table_top, table_bottom = 0.835, 0.105
    header_height = 0.075
    row_height = (table_top - table_bottom - header_height) / len(ranked)

    ax.text(
        left,
        0.965,
        f"{input_path.name} · Top {len(ranked)}",
        fontproperties=bold_font,
        color="#102A43",
        fontsize=18,
        va="top",
    )
    ax.text(
        left,
        0.918,
        "按 total_ns 降序；显示为 total_us = total_ns / 1,000",
        fontproperties=regular_font,
        color="#5B738B",
        fontsize=10.5,
        va="top",
    )
    ax.add_patch(
        Rectangle(
            (right - 0.19, 0.902),
            0.018,
            0.014,
            facecolor="#A8D9C8",
            edgecolor="none",
            transform=ax.transAxes,
        )
    )
    ax.text(
        right,
        0.918,
        "条形长度 = 相对 total_us",
        fontproperties=regular_font,
        color="#5B738B",
        fontsize=9.5,
        ha="right",
        va="top",
    )

    # Header row.
    x = left
    for field, width in zip(display_fields, widths):
        ax.add_patch(
            Rectangle(
                (x, table_top - header_height),
                width * (right - left),
                header_height,
                facecolor="#1E6091",
                edgecolor="#D4E5E8",
                linewidth=0.8,
            )
        )
        ax.text(
            x + 0.012,
            table_top - header_height / 2,
            field,
            fontproperties=bold_font,
            color="white",
            fontsize=10.5,
            va="center",
        )
        x += width * (right - left)

    numeric_fields = {"syscall_nr", "count", "total_us", "avg_ns"}
    for row_index, (display_row, total_us) in enumerate(zip(display_rows, total_values_us)):
        y = table_top - header_height - (row_index + 1) * row_height
        x = left
        for column_index, (field, value, width) in enumerate(
            zip(display_fields, display_row, widths)
        ):
            cell_width = width * (right - left)
            base_color = "#FFFFFF" if row_index % 2 == 0 else "#F7FBFB"
            ax.add_patch(
                Rectangle(
                    (x, y),
                    cell_width,
                    row_height,
                    facecolor=base_color,
                    edgecolor="#C9DDE3",
                    linewidth=0.7,
                )
            )

            if column_index == bar_column and max_total_us > 0:
                inset_x = cell_width * 0.018
                inset_y = row_height * 0.16
                bar_width = (cell_width - 2 * inset_x) * (total_us / max_total_us)
                if bar_width > 0:
                    ax.add_patch(
                        Rectangle(
                            (x + inset_x, y + inset_y),
                            bar_width,
                            row_height - 2 * inset_y,
                            facecolor="#A8D9C8",
                            edgecolor="none",
                            alpha=0.78,
                        )
                    )

            is_numeric = field.lower() in numeric_fields
            ax.text(
                x + cell_width - 0.012 if is_numeric else x + 0.012,
                y + row_height / 2,
                value,
                fontproperties=regular_font,
                color="#16324F",
                fontsize=10.2,
                ha="right" if is_numeric else "left",
                va="center",
            )
            x += cell_width

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(
        output_path,
        dpi=180,
        facecolor=fig.get_facecolor(),
        bbox_inches="tight",
        pad_inches=0.12,
    )
    plt.close(fig)

    print(f"wrote {output_path}")
    print(f"largest total_us: {max_total_us:,.3f}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "input",
        nargs="?",
        type=Path,
        default=DEFAULT_INPUT,
        help=f"counter CSV (default: {DEFAULT_INPUT})",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="output image path; defaults to <input>_top10_total_us.png",
    )
    parser.add_argument(
        "-n",
        "--top",
        type=int,
        default=10,
        help="number of rows to show (default: 10)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.top <= 0:
        print("--top must be positive", file=sys.stderr)
        return 2
    if not args.input.is_file():
        print(f"input table not found: {args.input}", file=sys.stderr)
        return 2

    output = args.output or args.input.with_name(
        f"{args.input.stem}_top{args.top}_total_us.svg"
    )
    try:
        fields, rows, total_field = read_counter_table(args.input)
        render_table(
            input_path=args.input,
            output_path=output,
            fields=fields,
            rows=rows,
            total_field=total_field,
            top_n=args.top,
        )
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
