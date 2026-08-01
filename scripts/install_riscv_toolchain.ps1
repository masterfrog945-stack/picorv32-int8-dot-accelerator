param(
    [string]$ToolsRoot = ''
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    $ToolsRoot = Join-Path $Root '.tools'
}
$Version = '15.2.0-1'
$ArchiveName = "xpack-riscv-none-elf-gcc-$Version-win32-x64.zip"
$ExpectedSha256 = '85EF714DACD273B1DADF4AF4892774520AC01915BFA6DA816A56E7E41591E09E'
$Url = "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$Version/$ArchiveName"

$DownloadDir = Join-Path $ToolsRoot 'downloads'
$Archive = Join-Path $DownloadDir $ArchiveName
$InstallRoot = Join-Path $ToolsRoot 'riscv-none-elf-gcc'
$InstallDir = Join-Path $InstallRoot "xpack-riscv-none-elf-gcc-$Version"
$Gcc = Join-Path $InstallDir 'bin\riscv-none-elf-gcc.exe'

New-Item -ItemType Directory -Force -Path $DownloadDir,$InstallRoot | Out-Null

if (-not (Test-Path -LiteralPath $Archive)) {
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Archive
}

$ActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash
if ($ActualSha256 -ne $ExpectedSha256) {
    throw "Toolchain archive SHA-256 mismatch. Expected $ExpectedSha256, got $ActualSha256"
}

if (-not (Test-Path -LiteralPath $Gcc)) {
    Expand-Archive -LiteralPath $Archive -DestinationPath $InstallRoot -Force
}

if (-not (Test-Path -LiteralPath $Gcc)) {
    throw "Compiler not found after extraction: $Gcc"
}

& $Gcc --version
if ($LASTEXITCODE -ne 0) { throw 'Installed compiler failed its version check' }

Write-Host "TOOLCHAIN_PASS: $InstallDir"
