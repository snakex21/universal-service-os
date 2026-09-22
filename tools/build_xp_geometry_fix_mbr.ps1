param(
    [string]$OutputDirectory = 'zig-out/xp-geometry-fix-mbr'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$zig = Full 'tools/zig/zig.exe'
$src = Full 'src/platform/bios/xp'
$out = Full $OutputDirectory
New-Item -ItemType Directory -Force -Path $out | Out-Null

$elf = Join-Path $out 'xp-geometry-fix-mbr.elf'
$raw = Join-Path $out 'xp-geometry-fix-mbr.raw.bin'
$bin = Join-Path $out 'xp-geometry-fix-mbr-440.bin'

& $zig cc -target x86-freestanding-none -mcpu=i386 -nostdlib -nodefaultlibs `
    "-Wl,-T,$((Join-Path $src 'xp_geometry_fix_mbr.ld'))" `
    '-Wl,--entry=xp_geometry_fix_mbr_start' `
    (Join-Path $src 'xp_geometry_fix_mbr.S') -o $elf
if ($LASTEXITCODE -ne 0) { throw "XP geometry-fix MBR assembly/link failed: $LASTEXITCODE" }

& $zig objcopy -O binary -j .text $elf $raw
if ($LASTEXITCODE -ne 0) { throw "XP geometry-fix MBR objcopy failed: $LASTEXITCODE" }

$code = [IO.File]::ReadAllBytes($raw)
if ($code.Length -gt 440) { throw "XP geometry-fix MBR code is $($code.Length) bytes; max is 440" }
$padded = New-Object byte[] 440
[Array]::Copy($code,$padded,$code.Length)
[IO.File]::WriteAllBytes($bin,$padded)
$sha = (Get-FileHash -LiteralPath $bin -Algorithm SHA256).Hash
Write-Host "[PASS] XP geometry-fix MBR: $($code.Length)/440 bytes SHA256=$sha"
Write-Host "OUTPUT=$bin"
