param(
    [string]$VivadoBin = $env:VIVADO_BIN
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Root 'build\synth_accel'

if ([string]::IsNullOrWhiteSpace($VivadoBin)) {
    $candidate = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($candidate) {
        $VivadoBin = Split-Path $candidate.Source -Parent
    } else {
        throw 'Vivado not found. Pass -VivadoBin or set VIVADO_BIN.'
    }
}

New-Item -ItemType Directory -Force -Path $Build | Out-Null

Push-Location $Root
try {
    & (Join-Path $VivadoBin 'vivado.bat') -mode batch `
        -source (Join-Path $Root 'scripts\synth_accel.tcl') `
        -log (Join-Path $Root 'build\synth_accel\vivado.log') `
        -journal (Join-Path $Root 'build\synth_accel\vivado.jou')
    if ($LASTEXITCODE -ne 0) { throw 'Vivado synthesis failed' }
} finally {
    Pop-Location
}

$log = Join-Path $Build 'vivado.log'
if (-not (Select-String -LiteralPath $log -SimpleMatch 'SYNTH_PASS:')) {
    throw 'Synthesis ended without SYNTH_PASS marker'
}

Write-Host "PASS: accelerator synthesis; reports: $Root\build\synth_accel"
