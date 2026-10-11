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

# NT 3.x variant: same boot path plus the resident INT 15h E820 filter
# (src/platform/bios/nt3/nt3_e820_mbr.S).
$nt3src = Full 'src/platform/bios/nt3'
$nt3elf = Join-Path $out 'nt3-e820-mbr.elf'
$nt3raw = Join-Path $out 'nt3-e820-mbr.raw.bin'
$nt3bin = Join-Path $out 'nt3-e820-mbr-440.bin'
& $zig cc -target x86-freestanding-none -mcpu=i386 -nostdlib -nodefaultlibs `
    "-Wl,-T,$((Join-Path $nt3src 'nt3_e820_mbr.ld'))" `
    '-Wl,--entry=nt3_e820_mbr_start' `
    (Join-Path $nt3src 'nt3_e820_mbr.S') -o $nt3elf
if ($LASTEXITCODE -ne 0) { throw "NT3 E820 MBR assembly/link failed: $LASTEXITCODE" }
& $zig objcopy -O binary -j .text $nt3elf $nt3raw
if ($LASTEXITCODE -ne 0) { throw "NT3 E820 MBR objcopy failed: $LASTEXITCODE" }
$code = [IO.File]::ReadAllBytes($nt3raw)
if ($code.Length -gt 440) { throw "NT3 E820 MBR code is $($code.Length) bytes; max is 440" }
$padded = New-Object byte[] 440
[Array]::Copy($code,$padded,$code.Length)
[IO.File]::WriteAllBytes($nt3bin,$padded)
$sha = (Get-FileHash -LiteralPath $nt3bin -Algorithm SHA256).Hash
Write-Host "[PASS] NT3 E820 MBR: $($code.Length)/440 bytes SHA256=$sha"
Write-Host "OUTPUT=$nt3bin"

# Its resident INT 15h / INT 1Ah hooks: sector 1 of the disk, "U3" (55 33)
# in the last two bytes; the old vectors follow the code (8 bytes).
$hookraw = Join-Path $out 'nt3-e820-hook.raw.bin'
$hookbin = Join-Path $out 'nt3-e820-hook-512.bin'
& $zig objcopy -O binary -j .hook $nt3elf $hookraw
if ($LASTEXITCODE -ne 0) { throw "NT3 MBR hook objcopy failed: $LASTEXITCODE" }
$code = [IO.File]::ReadAllBytes($hookraw)
if ($code.Length -gt 502) { throw "NT3 MBR hook code is $($code.Length) bytes; max is 502" }
$padded = New-Object byte[] 512
[Array]::Copy($code,$padded,$code.Length)
$padded[510] = 0x55
$padded[511] = 0x33
[IO.File]::WriteAllBytes($hookbin,$padded)
$sha = (Get-FileHash -LiteralPath $hookbin -Algorithm SHA256).Hash
Write-Host "[PASS] NT3 MBR hook sector: $($code.Length)/502 bytes SHA256=$sha"
Write-Host "OUTPUT=$hookbin"

# ReactOS (and own BIOS images) behind CSMWrap: the ELCR MBR marks the PCI
# IRQs level-triggered, then chains to the image's MBR kept at LBA 1
# (src/platform/bios/reactos/elcr_mbr.S, docs/custom-os-2026-10-11.md).
$elcrsrc = Full 'src/platform/bios/reactos'
$elcrelf = Join-Path $out 'elcr-mbr.elf'
$elcrraw = Join-Path $out 'elcr-mbr.raw.bin'
$elcrbin = Join-Path $out 'elcr-mbr-440.bin'
& $zig cc -target x86-freestanding-none -mcpu=i386 -nostdlib -nodefaultlibs `
    "-Wl,-T,$((Join-Path $elcrsrc 'elcr_mbr.ld'))" `
    '-Wl,--entry=elcr_mbr_start' `
    (Join-Path $elcrsrc 'elcr_mbr.S') -o $elcrelf
if ($LASTEXITCODE -ne 0) { throw "ELCR MBR assembly/link failed: $LASTEXITCODE" }
& $zig objcopy -O binary -j .text $elcrelf $elcrraw
if ($LASTEXITCODE -ne 0) { throw "ELCR MBR objcopy failed: $LASTEXITCODE" }
$code = [IO.File]::ReadAllBytes($elcrraw)
if ($code.Length -gt 440) { throw "ELCR MBR code is $($code.Length) bytes; max is 440" }
$padded = New-Object byte[] 440
[Array]::Copy($code,$padded,$code.Length)
[IO.File]::WriteAllBytes($elcrbin,$padded)
$sha = (Get-FileHash -LiteralPath $elcrbin -Algorithm SHA256).Hash
Write-Host "[PASS] ELCR MBR: $($code.Length)/440 bytes SHA256=$sha"
Write-Host "OUTPUT=$elcrbin"
