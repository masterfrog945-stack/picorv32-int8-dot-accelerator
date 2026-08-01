param(
    [string]$VivadoBin = $env:VIVADO_BIN
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Root 'build\sim_accel'

if ([string]::IsNullOrWhiteSpace($VivadoBin)) {
    $candidate = Get-Command xvlog.bat -ErrorAction SilentlyContinue
    if ($candidate) {
        $VivadoBin = Split-Path $candidate.Source -Parent
    } else {
        throw 'Vivado tools not found. Pass -VivadoBin or set VIVADO_BIN.'
    }
}

New-Item -ItemType Directory -Force -Path $Build | Out-Null
Push-Location $Build
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv -d ENABLE_SVA `
        (Join-Path $Root 'rtl\int8_dot_accel.sv') `
        (Join-Path $Root 'tb\int8_dot_assertions.sv') `
        (Join-Path $Root 'tb\tb_int8_dot_accel.sv')
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed for accelerator test' }

    & (Join-Path $VivadoBin 'xelab.bat') tb_int8_dot_accel `
        -debug typical -s accel_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed for accelerator test' }

    & (Join-Path $VivadoBin 'xsim.bat') accel_sim -runall `
        --log accel_xsim.log
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed for accelerator test' }

    if (-not (Select-String -LiteralPath 'accel_xsim.log' `
        -SimpleMatch 'TEST_PASS: int8_dot_accel')) {
        throw 'Accelerator simulation ended without TEST_PASS marker'
    }
} finally {
    Pop-Location
}

Write-Host "PASS: accelerator simulation; log: $Build\accel_xsim.log"
