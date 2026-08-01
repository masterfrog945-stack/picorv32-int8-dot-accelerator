param(
    [string]$VivadoBin = $env:VIVADO_BIN
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Root 'build\sim_picorv32'

if ([string]::IsNullOrWhiteSpace($VivadoBin)) {
    $candidate = Get-Command xvlog.bat -ErrorAction SilentlyContinue
    if ($candidate) {
        $VivadoBin = Split-Path $candidate.Source -Parent
    } else {
        throw 'Vivado tools not found. Pass -VivadoBin or set VIVADO_BIN.'
    }
}

$PicoRtl = Join-Path $Root 'external\picorv32\picorv32.v'
if (-not (Test-Path $PicoRtl)) {
    throw 'PicoRV32 source missing. Clone YosysHQ/picorv32 into external/picorv32.'
}

New-Item -ItemType Directory -Force -Path $Build | Out-Null
Push-Location $Build
try {
    & (Join-Path $VivadoBin 'xvlog.bat') $PicoRtl
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed for PicoRV32 RTL' }

    & (Join-Path $VivadoBin 'xvlog.bat') --sv `
        (Join-Path $Root 'tb\tb_picorv32_smoke.sv')
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed for PicoRV32 testbench' }

    & (Join-Path $VivadoBin 'xelab.bat') tb_picorv32_smoke `
        -debug typical -s picorv32_smoke_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed for PicoRV32 smoke test' }

    & (Join-Path $VivadoBin 'xsim.bat') picorv32_smoke_sim -runall `
        --log picorv32_xsim.log
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed for PicoRV32 smoke test' }

    if (-not (Select-String -LiteralPath 'picorv32_xsim.log' `
        -SimpleMatch 'TEST_PASS: PicoRV32')) {
        throw 'PicoRV32 simulation ended without TEST_PASS marker'
    }
} finally {
    Pop-Location
}

Write-Host "PASS: PicoRV32 smoke simulation; log: $Build\picorv32_xsim.log"
