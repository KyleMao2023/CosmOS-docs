param(
  [switch]$Pptx
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Push-Location $repoRoot
try {
  & typst compile --root . presentations/cosmos-performance.typ presentations/cosmos-performance.pdf
  if ($LASTEXITCODE -ne 0) {
    throw "Typst PDF compilation failed."
  }

  if ($Pptx) {
    if (-not (Get-Command typ2pptx -ErrorAction SilentlyContinue)) {
      throw "typ2pptx was not found. Install it or omit -Pptx."
    }

    & typ2pptx presentations/cosmos-performance.typ `
      -o presentations/cosmos-performance.pptx `
      --root .
    if ($LASTEXITCODE -ne 0) {
      throw "typ2pptx conversion failed."
    }
  }
}
finally {
  Pop-Location
}
