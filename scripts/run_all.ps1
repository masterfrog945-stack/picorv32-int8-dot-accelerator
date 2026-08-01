param(
    [string]$VivadoBin = $env:VIVADO_BIN,
    [string]$ToolchainBin = $env:RISCV_TOOLCHAIN_BIN
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'run_picorv32_smoke.ps1') -VivadoBin $VivadoBin
& (Join-Path $PSScriptRoot 'run_accel_sim.ps1') -VivadoBin $VivadoBin
& (Join-Path $PSScriptRoot 'run_csr_sim.ps1') -VivadoBin $VivadoBin
& (Join-Path $PSScriptRoot 'run_soc_sim.ps1') `
    -VivadoBin $VivadoBin -ToolchainBin $ToolchainBin
& (Join-Path $PSScriptRoot 'run_synth.ps1') -VivadoBin $VivadoBin
& (Join-Path $PSScriptRoot 'run_soc_synth.ps1') -VivadoBin $VivadoBin

Write-Host 'ALL_PASS: core, CSR, firmware SoC, and both synthesis targets'
