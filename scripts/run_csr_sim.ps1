param(
    [string]$VivadoBin = $env:VIVADO_BIN
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Root 'build\sim_csr'

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
    & (Join-Path $VivadoBin 'xvlog.bat') --sv `
        (Join-Path $Root 'rtl\int8_dot_accel.sv') `
        (Join-Path $Root 'rtl\accel_csr.sv') `
        (Join-Path $Root 'tb\tb_accel_csr.sv')
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed for CSR test' }

    & (Join-Path $VivadoBin 'xelab.bat') tb_accel_csr `
        -debug typical -s csr_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed for CSR test' }

    & (Join-Path $VivadoBin 'xsim.bat') csr_sim -runall `
        --log csr_xsim.log
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed for CSR test' }

    if (-not (Select-String -LiteralPath 'csr_xsim.log' `
        -SimpleMatch 'TEST_PASS: accel_csr')) {
        throw 'CSR simulation ended without TEST_PASS marker'
    }
} finally {
    Pop-Location
}

Write-Host "PASS: CSR/MMIO simulation; log: $Build\csr_xsim.log"
