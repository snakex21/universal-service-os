param(
    [string]$OutputDirectory = 'zig-out/xp-bios'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$zig = Full 'tools/zig/zig.exe'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$src = Full 'src/platform/bios/xp'
$out = Full $OutputDirectory
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Build-Raw([string]$Name, [string]$Source, [string]$Linker, [string]$Entry) {
    $elf = Join-Path $out "$Name.elf"
    $raw = Join-Path $out "$Name.raw.bin"
    & $zig cc -target x86-freestanding-none -mcpu=i386 -nostdlib -nodefaultlibs `
        "-Wl,-T,$((Join-Path $src $Linker))" "-Wl,--entry=$Entry" `
        (Join-Path $src $Source) -o $elf
    if ($LASTEXITCODE -ne 0) { throw "XP BIOS assembly/link failed: $Source ($LASTEXITCODE)" }
    & $zig objcopy -O binary -j .text $elf $raw
    if ($LASTEXITCODE -ne 0) { throw "XP BIOS objcopy failed: $Source ($LASTEXITCODE)" }
    return $raw
}

$vbrRaw = Build-Raw 'xp-vbr-code' 'xp_vbr.S' 'xp_vbr.ld' 'xp_vbr_start'
$stage2Raw = Build-Raw 'xp-stage2' 'xp_stage2.S' 'xp_stage2.ld' 'xp_stage2_start'
$stage2DiagRaw = Build-Raw 'xp-stage2-diag' 'xp_stage2_diag.S' 'xp_stage2.ld' 'xp_stage2_start'
$stage2RegsRaw = Build-Raw 'xp-stage2-regs' 'xp_stage2_regs.S' 'xp_stage2.ld' 'xp_stage2_start'

$vbr = [IO.File]::ReadAllBytes($vbrRaw)
$vbrMax = 510 - 90
if ($vbr.Length -gt $vbrMax) { throw "XP VBR code is $($vbr.Length) bytes; max after FAT32 BPB is $vbrMax" }
$vbrPath = Join-Path $out 'xp-vbr-code.bin'
[IO.File]::WriteAllBytes($vbrPath, $vbr)

$stage2 = [IO.File]::ReadAllBytes($stage2Raw)
$stage2Bytes = 24 * 512
if ($stage2.Length -gt $stage2Bytes) { throw "XP stage2 is $($stage2.Length) bytes; reserved-sector budget is $stage2Bytes" }
$stage2Padded = New-Object byte[] $stage2Bytes
[Array]::Copy($stage2, $stage2Padded, $stage2.Length)
$stage2Path = Join-Path $out 'xp-stage2.bin'
[IO.File]::WriteAllBytes($stage2Path, $stage2Padded)

$stage2Diag = [IO.File]::ReadAllBytes($stage2DiagRaw)
if ($stage2Diag.Length -gt $stage2Bytes) { throw "XP diagnostic stage2 is $($stage2Diag.Length) bytes; reserved-sector budget is $stage2Bytes" }
$stage2DiagPadded = New-Object byte[] $stage2Bytes
[Array]::Copy($stage2Diag, $stage2DiagPadded, $stage2Diag.Length)
$stage2DiagPath = Join-Path $out 'xp-stage2-diag.bin'
[IO.File]::WriteAllBytes($stage2DiagPath, $stage2DiagPadded)

$stage2Regs = [IO.File]::ReadAllBytes($stage2RegsRaw)
if ($stage2Regs.Length -gt $stage2Bytes) { throw "XP register-capture stage2 is $($stage2Regs.Length) bytes; reserved-sector budget is $stage2Bytes" }
$stage2RegsPadded = New-Object byte[] $stage2Bytes
[Array]::Copy($stage2Regs, $stage2RegsPadded, $stage2Regs.Length)
$stage2RegsPath = Join-Path $out 'xp-stage2-regs.bin'
[IO.File]::WriteAllBytes($stage2RegsPath, $stage2RegsPadded)

# Production XP handoff uses the Microsoft NT52 FAT32 loader semantics. The
# local control proved that this loader reaches Setup with the staged ~BT/~LS
# source while the direct custom SETUPLDR jump reboots. Extract the two small
# executable fragments from the host's signed bootsect.exe at build time rather
# than committing Microsoft boot code to the repository.
$bootsect = Join-Path $env:SystemRoot 'System32\bootsect.exe'
if (-not (Test-Path -LiteralPath $bootsect -PathType Leaf)) { throw "bootsect.exe is required for XP NT52 bootstrap extraction: $bootsect" }
$extractor = Full 'tools/extract_xp_nt52_boot.py'
$nt52Vbr = Join-Path $out 'xp-nt52-vbr-tail.bin'
$nt52VbrEdd = Join-Path $out 'xp-nt52-vbr-tail-edd.bin'
$nt52Stage2 = Join-Path $out 'xp-nt52-stage2.bin'
& $python $extractor --bootsect-exe $bootsect --vbr-tail-out $nt52Vbr --stage2-out $nt52Stage2 --ntfs-out (Join-Path $out 'xp-nt52-ntfs.bin') --nt60-ntfs-out (Join-Path $out 'vista-nt60-ntfs.bin')
if ($LASTEXITCODE -ne 0) { throw "XP NT52 bootstrap extraction failed: $LASTEXITCODE" }
if ((Get-Item -LiteralPath (Join-Path $out 'vista-nt60-ntfs.bin')).Length -ne 8192) { throw 'Vista NT60 NTFS bootstrap must be exactly 8192 bytes' }
if ((Get-Item -LiteralPath $nt52Vbr).Length -ne 420) { throw 'XP NT52 VBR tail must be exactly 420 bytes' }
if ((Get-Item -LiteralPath $nt52Stage2).Length -ne 512) { throw 'XP NT52 stage2 must be exactly 512 bytes' }
$eddPatcher = Full 'tools/patch_xp_nt52_edd.py'
& $python $eddPatcher --input $nt52Vbr --output $nt52VbrEdd
if ($LASTEXITCODE -ne 0) { throw "XP NT52 EDD-only patch failed: $LASTEXITCODE" }
if ((Get-Item -LiteralPath $nt52VbrEdd).Length -ne 420) { throw 'XP NT52 EDD-only VBR tail must be exactly 420 bytes' }

Write-Host "[PASS] XP diagnostic FAT32 VBR code: $($vbr.Length)/$vbrMax bytes"
Write-Host "[PASS] XP diagnostic FAT32 stage2: $($stage2.Length)/$stage2Bytes bytes"
Write-Host "[PASS] XP EDD stage2 diagnostic variant: $($stage2Diag.Length)/$stage2Bytes bytes"
Write-Host "[PASS] XP EDD stage2 register-capture variant: $($stage2Regs.Length)/$stage2Bytes bytes"
Write-Host '[PASS] XP production FAT32 loader base: Microsoft NT52 VBR tail=420 stage2=512'
Write-Host "[PASS] XP NT52 EDD-only VBR tail: 4-byte CHS-branch patch SHA256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $nt52VbrEdd).Hash)"
Write-Host "[PASS] XP BIOS bootstrap output: $out"
