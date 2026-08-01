param(
    [string]$ToolchainBin = $env:RISCV_TOOLCHAIN_BIN
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Root 'build\firmware'

if ([string]::IsNullOrWhiteSpace($ToolchainBin)) {
    $candidate = Get-Command riscv-none-elf-gcc.exe -ErrorAction SilentlyContinue
    if ($candidate) {
        $ToolchainBin = Split-Path $candidate.Source -Parent
    } else {
        throw 'RISC-V toolchain not found. Pass -ToolchainBin or set RISCV_TOOLCHAIN_BIN.'
    }
}

$Gcc     = Join-Path $ToolchainBin 'riscv-none-elf-gcc.exe'
$Objcopy = Join-Path $ToolchainBin 'riscv-none-elf-objcopy.exe'
$Objdump = Join-Path $ToolchainBin 'riscv-none-elf-objdump.exe'
$Size    = Join-Path $ToolchainBin 'riscv-none-elf-size.exe'

foreach ($tool in @($Gcc, $Objcopy, $Objdump, $Size)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Required RISC-V tool not found: $tool"
    }
}

New-Item -ItemType Directory -Force -Path $Build | Out-Null

$Elf = Join-Path $Build 'firmware.elf'
$Bin = Join-Path $Build 'firmware.bin'
$Hex = Join-Path $Build 'firmware.hex'
$Map = Join-Path $Build 'firmware.map'
$Disasm = Join-Path $Build 'firmware.disasm'

$gccArgs = @(
    '-march=rv32i',
    '-mabi=ilp32',
    '-Os',
    '-g',
    '-ffreestanding',
    '-fno-builtin',
    '-fdata-sections',
    '-ffunction-sections',
    '-msmall-data-limit=0',
    '-nostdlib',
    '-nostartfiles',
    '-Wall',
    '-Wextra',
    '-Werror',
    "-Wl,-T,$Root\sw\linker.ld",
    "-Wl,-Map=$Map",
    '-Wl,--gc-sections',
    '-o', $Elf,
    (Join-Path $Root 'sw\start.S'),
    (Join-Path $Root 'sw\main.c'),
    (Join-Path $Root 'sw\accel.c'),
    (Join-Path $Root 'sw\uart_echo.c'),
    '-lgcc'
)

& $Gcc @gccArgs
if ($LASTEXITCODE -ne 0) { throw 'RISC-V firmware compilation failed' }

& $Objcopy -O binary $Elf $Bin
if ($LASTEXITCODE -ne 0) { throw 'RISC-V objcopy failed' }

& python (Join-Path $Root 'scripts\bin_to_hex.py') $Bin $Hex
if ($LASTEXITCODE -ne 0) { throw 'Binary-to-hex conversion failed' }

& $Objdump -d -S $Elf | Set-Content -LiteralPath $Disasm -Encoding ascii
if ($LASTEXITCODE -ne 0) { throw 'RISC-V objdump failed' }

& $Size $Elf
if ($LASTEXITCODE -ne 0) { throw 'RISC-V size failed' }

Write-Host "FIRMWARE_PASS: $Elf"
