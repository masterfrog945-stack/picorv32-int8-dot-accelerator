param(
    [string]$VivadoBin = $env:VIVADO_BIN,
    [string]$ToolchainBin = $env:RISCV_TOOLCHAIN_BIN
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Root 'build\sim_soc'

if ([string]::IsNullOrWhiteSpace($VivadoBin)) {
    $candidate = Get-Command xvlog.bat -ErrorAction SilentlyContinue
    if ($candidate) {
        $VivadoBin = Split-Path $candidate.Source -Parent
    } else {
        throw 'Vivado tools not found. Pass -VivadoBin or set VIVADO_BIN.'
    }
}

& (Join-Path $PSScriptRoot 'build_firmware.ps1') -ToolchainBin $ToolchainBin

New-Item -ItemType Directory -Force -Path $Build | Out-Null
Copy-Item -LiteralPath (Join-Path $Root 'build\firmware\firmware.hex') `
    -Destination (Join-Path $Build 'firmware.hex') -Force

Push-Location $Build
try {
    & (Join-Path $VivadoBin 'xvlog.bat') `
        (Join-Path $Root 'external\picorv32\picorv32.v')
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed for PicoRV32 RTL' }

    & (Join-Path $VivadoBin 'xvlog.bat') --sv `
        (Join-Path $Root 'rtl\int8_dot_accel.sv') `
        (Join-Path $Root 'rtl\accel_csr.sv') `
        (Join-Path $Root 'rtl\simple_ram.sv') `
        (Join-Path $Root 'rtl\soc_test_device.sv') `
        (Join-Path $Root 'rtl\sync_fifo.sv') `
        (Join-Path $Root 'rtl\uart_rx_core.sv') `
        (Join-Path $Root 'rtl\uart_tx_core.sv') `
        (Join-Path $Root 'rtl\uart_mmio.sv') `
        (Join-Path $Root 'rtl\picorv32_accel_soc.sv') `
        (Join-Path $Root 'tb\tb_picorv32_accel_soc.sv')
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed for SoC RTL/testbench' }

    & (Join-Path $VivadoBin 'xelab.bat') tb_picorv32_accel_soc `
        -debug typical -s soc_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed for SoC test' }

    & (Join-Path $VivadoBin 'xsim.bat') soc_sim -runall `
        --log soc_xsim.log
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed for SoC test' }

    if (-not (Select-String -LiteralPath 'soc_xsim.log' `
        -SimpleMatch 'TEST_PASS: PicoRV32 C firmware')) {
        throw 'SoC simulation ended without TEST_PASS marker'
    }
    if (-not (Select-String -LiteralPath 'soc_xsim.log' `
        -SimpleMatch 'UART_ECHO_PASS:')) {
        throw 'SoC simulation ended without UART_ECHO_PASS marker'
    }
} finally {
    Pop-Location
}

Write-Host "PASS: PicoRV32 accelerator self-test and UART echo simulation; log: $Build\soc_xsim.log"
