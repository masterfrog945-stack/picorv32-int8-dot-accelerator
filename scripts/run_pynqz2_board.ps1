param(
    [string]$VivadoBin = $env:VIVADO_BIN
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $scriptDir "..")).Path
$tcl = Join-Path $scriptDir "build_pynqz2_board.tcl"

if ([string]::IsNullOrWhiteSpace($VivadoBin)) {
    $candidate = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($candidate) {
        $VivadoBin = Split-Path $candidate.Source -Parent
    } else {
        throw 'Vivado not found. Pass -VivadoBin or set VIVADO_BIN.'
    }
}

$Vivado = Join-Path $VivadoBin 'vivado.bat'

if (-not (Test-Path -LiteralPath $Vivado)) {
    throw "Vivado executable not found: $Vivado"
}

& $Vivado -mode batch -nolog -nojournal -notrace -source $tcl
if ($LASTEXITCODE -ne 0) {
    throw "PYNQ-Z2 board build failed with exit code $LASTEXITCODE"
}

Write-Host "BOARD_PASS: $root\build\pynqz2_board\pynqz2_accel.bit"
