#!/usr/bin/env bash
# Compile the Touying deck from Linux/WSL and run lightweight PDF/layout checks.
#
# The script prefers a native Linux typst. If none is available, it can invoke
# the Windows binary from WSL, including the path shown by `which typst` on the
# user's machine. Set TYPST_BIN explicitly when auto-discovery is not enough.

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
presentation_dir="$repo_root/presentations"
source_linux="$presentation_dir/cosmos-performance.typ"
pdf_linux="${COSMOS_PDF_OUT:-$presentation_dir/cosmos-performance.pdf}"
check_dir="${COSMOS_CHECK_DIR:-$presentation_dir/.preview}"
ppi="${COSMOS_PREVIEW_PPI:-120}"
skip_preview=0

usage() {
  cat <<'EOF'
Usage: presentations/build-and-check.sh [--no-preview]

Compile the CosmOS Typst deck, validate the resulting PDF, and render a
thumbnail contact sheet for manual visual inspection.

Environment overrides:
  TYPST_BIN                 Linux path or Windows path to typst.exe
  COSMOS_PDF_OUT            PDF output path
  COSMOS_CHECK_DIR          logs and PNG preview directory
  COSMOS_PREVIEW_PPI        PNG preview resolution (default: 120)

Examples:
  bash presentations/build-and-check.sh
  TYPST_BIN='/mnt/c/Program Files/MiKTeX/miktex/bin/x64/typst.exe' \
    bash presentations/build-and-check.sh
  bash presentations/build-and-check.sh --no-preview
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

while (($# > 0)); do
  case "$1" in
    --no-preview)
      skip_preview=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (use --help)"
      ;;
  esac
  shift
done

[[ -f "$source_linux" ]] || die "deck source not found: $source_linux"
mkdir -p "$check_dir"

to_linux_path() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z]:[\\/].* ]] && command -v wslpath >/dev/null 2>&1; then
    wslpath -u "$value"
  else
    printf '%s\n' "$value"
  fi
}

to_tool_path() {
  local value="$1"
  if [[ "$typst_is_windows" -eq 1 ]]; then
    command -v wslpath >/dev/null 2>&1 \
      || die "wslpath is required when invoking a Windows typst.exe from Linux"
    wslpath -w "$value"
  else
    printf '%s\n' "$value"
  fi
}

resolve_candidate() {
  local candidate="$1"
  candidate="$(to_linux_path "$candidate")"

  if [[ "$candidate" != */* && "$candidate" != *\\* ]]; then
    if command -v "$candidate" >/dev/null 2>&1; then
      candidate="$(to_linux_path "$(command -v "$candidate")")"
    fi
  fi

  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

typst_bin=""
if [[ -n "${TYPST_BIN:-}" ]]; then
  typst_bin="$(resolve_candidate "$TYPST_BIN" || true)"
else
  for candidate in typst typst.exe \
    '/mnt/c/Program Files/MiKTeX/miktex/bin/x64/typst.exe' \
    '/mnt/c/Program Files/Typst/typst.exe' \
    '/mnt/c/Program Files/Typst/bin/typst.exe'; do
    if typst_bin="$(resolve_candidate "$candidate" || true)" && [[ -n "$typst_bin" ]]; then
      break
    fi
  done
fi

# If PATH discovery did not find it, ask Windows where typst is installed.
if [[ -z "$typst_bin" ]]; then
  for cmd_candidate in /mnt/c/Windows/System32/cmd.exe /mnt/c/Windows/SysWOW64/cmd.exe; do
    [[ -x "$cmd_candidate" ]] || continue
    windows_typst_path="$(
      "$cmd_candidate" /c where typst 2>/dev/null \
        | tr -d '\r' \
        | sed -n -E '/^[A-Za-z]:[\\/].*typst(\.exe)?$/Ip' \
        | sed -n '1p' \
        || true
    )"
    if [[ -n "$windows_typst_path" ]] && typst_bin="$(resolve_candidate "$windows_typst_path" || true)"; then
      [[ -n "$typst_bin" ]] && break
    fi
  done
fi

[[ -n "$typst_bin" ]] || die "typst was not found. Set TYPST_BIN to typst or typst.exe."
typst_is_windows=0
[[ "$typst_bin" == *.exe ]] && typst_is_windows=1

printf 'typst: %s\n' "$typst_bin"
if [[ "$typst_is_windows" -eq 1 ]]; then
  printf '%s\n' 'mode: Windows typst.exe through WSL path translation'
else
  printf '%s\n' 'mode: native Linux typst'
fi

# A quick executable check gives a more useful message than a later path error.
set +e
typst_version="$("$typst_bin" --version 2>&1)"
version_rc=$?
set -e
if ((version_rc != 0)); then
  printf '%s\n' "$typst_version" >&2
  die "cannot execute $typst_bin (WSL Windows interop may be unavailable)"
fi
printf 'version: %s\n' "$typst_version"

root_arg="$(to_tool_path "$repo_root")"
source_arg="$(to_tool_path "$source_linux")"
pdf_arg="$(to_tool_path "$pdf_linux")"
compile_log="$check_dir/typst-compile.log"

printf 'compile: %s\n' "$pdf_linux"
set +e
"$typst_bin" compile --root "$root_arg" "$source_arg" "$pdf_arg" >"$compile_log" 2>&1
compile_rc=$?
set -e

if ((compile_rc != 0)); then
  cat "$compile_log" >&2
  die "Typst compilation failed with exit code $compile_rc"
fi

if [[ -s "$compile_log" ]]; then
  printf '%s\n' 'Typst diagnostics:'
  cat "$compile_log"
fi

layout_failed=0
layout_warning=0
if grep -Eiq '(^|[[:space:]])(error|warning):|does not fit|overflow|overfull|clipped|out of bounds' "$compile_log"; then
  warn "Typst emitted a possible layout diagnostic; inspect $compile_log"
  layout_failed=1
fi

[[ -s "$pdf_linux" ]] || die "Typst reported success but PDF is missing or empty: $pdf_linux"

# The source headings define the expected number of Touying slides. This keeps
# the check useful after adding/removing a slide without hard-coding 13 forever.
expected_pages="$(awk '/^== / {count++} END {print count + 0}' "$source_linux")"

pdf_check_rc=0
if command -v python3 >/dev/null 2>&1; then
  set +e
  python3 - "$pdf_linux" "$source_linux" "$expected_pages" <<'PY'
import re
import sys
from pathlib import Path

pdf_path = Path(sys.argv[1])
source_path = Path(sys.argv[2])
expected_pages = int(sys.argv[3])

try:
    from pypdf import PdfReader
except ImportError:
    print("PDF_LAYOUT_CHECK=SKIP (python package pypdf is not installed)")
    sys.exit(2)

def compact(value):
    return re.sub(r"\s+", "", value or "")

source_text = source_path.read_text(encoding="utf-8")
titles = [line[3:].strip() for line in source_text.splitlines() if line.startswith("== ")]
reader = PdfReader(str(pdf_path))
pages = reader.pages
errors = []
warnings = []

if len(pages) != expected_pages:
    errors.append(f"page count is {len(pages)}, expected {expected_pages} from == headings")

all_text = []
for page_number, page in enumerate(pages, start=1):
    box = page.mediabox
    width = float(box.width)
    height = float(box.height)
    ratio = width / height if height else 0.0
    if abs(ratio - (16 / 9)) > 0.02:
        errors.append(f"page {page_number} has ratio {ratio:.4f}, expected 16:9")

    try:
        text = page.extract_text() or ""
    except Exception as exc:
        warnings.append(f"page {page_number} text extraction failed: {exc}")
        text = ""
    all_text.append(text)
    if len(compact(text)) < 4:
        errors.append(f"page {page_number} has almost no extractable text")

    outside = []

    def visitor_text(value, cm, tm, _font_dict, _font_size):
        if not value or not value.strip():
            return
        try:
            # pypdf exposes the text matrix and the current transformation
            # matrix separately. Their translation components alone are often
            # zero for Typst-generated PDFs, so combine the affine matrices.
            x = float(cm[0]) * float(tm[4]) + float(cm[2]) * float(tm[5]) + float(cm[4])
            y = float(cm[1]) * float(tm[4]) + float(cm[3]) * float(tm[5]) + float(cm[5])
        except Exception:
            return
        # A small tolerance avoids treating glyph baselines at the edge as
        # overflow, while still catching text placed well outside the page.
        tolerance = 6.0
        if x < -tolerance or x > width + tolerance or y < -tolerance or y > height + tolerance:
            outside.append((value.strip().replace("\n", " ")[:40], x, y))

    try:
        page.extract_text(visitor_text=visitor_text)
    except Exception:
        # Older pypdf versions may not support visitor_text. The other checks
        # remain valid in that case.
        pass
    if outside:
        preview = "; ".join(f"{text!r}@({x:.1f},{y:.1f})" for text, x, y in outside[:3])
        warnings.append(f"page {page_number} has text coordinates outside the page: {preview}")

normalized_document = compact("\n".join(all_text))
missing_titles = [title for title in titles if compact(title) not in normalized_document]
if missing_titles:
    errors.append("missing slide title text: " + ", ".join(missing_titles))

print(f"PDF_PAGES={len(pages)}")
print(f"PDF_SIZE_PT={float(pages[0].mediabox.width):.2f}x{float(pages[0].mediabox.height):.2f}")
print(f"PDF_TITLES_EXPECTED={len(titles)}")
for warning in warnings:
    print(f"PDF_LAYOUT_WARNING={warning}")
for error in errors:
    print(f"PDF_LAYOUT_ERROR={error}")

if errors:
    print("PDF_LAYOUT_CHECK=FAIL")
    sys.exit(1)
if warnings:
    print("PDF_LAYOUT_CHECK=WARN")
    sys.exit(3)
print("PDF_LAYOUT_CHECK=OK")
PY
  pdf_check_rc=$?
  set -e
else
  warn "python3 is not installed; skipped PDF structure/layout checks"
  pdf_check_rc=2
fi

if ((pdf_check_rc == 1)); then
  layout_failed=1
elif ((pdf_check_rc == 2)); then
  warn "install python3-pypdf for automatic PDF checks"
  layout_warning=1
elif ((pdf_check_rc == 3)); then
  layout_warning=1
fi

contact_sheet="$check_dir/contact-sheet.png"
if ((skip_preview == 0)); then
  preview_template_linux="$check_dir/slide-{p}.png"
  preview_arg="$(to_tool_path "$preview_template_linux")"
  preview_log="$check_dir/typst-preview.log"
  printf 'preview: %s\n' "$check_dir"

  set +e
  "$typst_bin" compile --format png --ppi "$ppi" \
    --root "$root_arg" "$source_arg" "$preview_arg" >"$preview_log" 2>&1
  preview_rc=$?
  set -e

  if ((preview_rc != 0)); then
    warn "PNG preview generation failed; inspect $preview_log"
    layout_warning=1
  else
    if python3 - "$check_dir" "$contact_sheet" <<'PY'
import re
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("CONTACT_SHEET=SKIP (python package Pillow is not installed)")
    sys.exit(2)

preview_dir = Path(sys.argv[1])
output = Path(sys.argv[2])
files = sorted(
    preview_dir.glob("slide-*.png"),
    key=lambda path: int(re.search(r"(\d+)", path.stem).group(1)),
)
if not files:
    print("CONTACT_SHEET=SKIP (no PNG pages were produced)")
    sys.exit(2)

thumb_width = 420
label_height = 34
padding = 18
columns = 3
rows = (len(files) + columns - 1) // columns
tiles = []
for number, path in enumerate(files, start=1):
    image = Image.open(path).convert("RGB")
    scale = thumb_width / image.width
    thumb = image.resize((thumb_width, round(image.height * scale)), Image.Resampling.LANCZOS)
    tile = Image.new("RGB", (thumb.width, thumb.height + label_height), "white")
    tile.paste(thumb, (0, label_height))
    draw = ImageDraw.Draw(tile)
    draw.text((8, 8), f"slide {number}", fill="#102A43")
    tiles.append(tile)

tile_height = max(tile.height for tile in tiles)
canvas = Image.new(
    "RGB",
    (columns * thumb_width + (columns + 1) * padding,
     rows * tile_height + (rows + 1) * padding),
    "#EAF2F8",
)
for index, tile in enumerate(tiles):
    row, column = divmod(index, columns)
    x = padding + column * (thumb_width + padding)
    y = padding + row * (tile_height + padding)
    canvas.paste(tile, (x, y))
canvas.save(output)
print(f"CONTACT_SHEET={output}")
PY
    then
      :
    else
      warn "could not create a contact sheet; inspect individual PNGs in $check_dir"
      layout_warning=1
    fi
  fi
else
  printf '%s\n' 'preview: skipped (--no-preview)'
fi

if ((layout_failed != 0)); then
  printf '%s\n' 'RESULT=FAIL (inspect the diagnostics and preview)' >&2
  exit 1
fi

if ((layout_warning != 0)); then
  printf '%s\n' 'RESULT=WARN (automatic checks completed with warnings; inspect the preview)' >&2
  exit 0
fi

printf '%s\n' 'RESULT=OK (automatic checks passed; inspect the contact sheet for visual balance)'
