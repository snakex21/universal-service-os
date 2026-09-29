<#
Test fixture for docs/design/bios-via-csmwrap.md (option A): a disposable
USOS stick image (fixed VHD, GPT) that both firmware paths can boot:

  UEFI:  \EFI\BOOT\BOOTX64.EFI (shim -> USOS menu) from the payload ESP
  BIOS:  protective MBR with the committed Legacy Stage 1 + the Core slot at
         LBA 64 (installer/internal/payload/legacy_boot_generated.go)

ESP (FAT32, GPT name USOS_ESP) = the files of an installer payload.zip;
DATA (NTFS, GPT name USOS_DATA) = the DOS test media given on the command
line. Optional EFI\USOS\csmwrap\csmwrap.ini (the release ships none).

Needs an elevated shell (Mount-DiskImage). Touches only the new VHD: it is
created here, must not exist yet, and the mounted disk must be a fresh
file-backed virtual disk of the requested size.
#>
param(
    [Parameter(Mandatory)] [string]$Output,          # new .vhd path under zig-out
    [Parameter(Mandatory)] [string]$PayloadZip,      # installer payload.zip (ESP files)
    [string]$MsDosIso = '',
    [string]$Win31Iso = '',
    [string]$DemoDir = '',                           # folder with HELLO.COM / INPUT.TXT
    [string]$CsmwrapIni = '',                        # file copied to EFI\USOS\csmwrap\csmwrap.ini
    [string]$CsmwrapEfi = '',                        # prototype binary replacing EFI\USOS\csmwrap\csmwrapx64.efi
    [string]$CoreSlot = '',                          # prototype core-slot.bin instead of the committed Core
    [int]$SizeMiB = 1536,
    [int]$EspMiB = 512
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$Output = [IO.Path]::GetFullPath($Output)
if (-not $Output.StartsWith((Join-Path $root 'zig-out') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "fixture must live under zig-out: $Output" }
if (Test-Path -LiteralPath $Output) { throw "refusing to replace an existing fixture: $Output" }
New-Item -ItemType Directory -Force -Path (Split-Path $Output) | Out-Null
$work = "$Output.work"
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null

$script = Join-Path $work 'create.diskpart.txt'
[IO.File]::WriteAllLines($script, @("create vdisk file=`"$Output`" maximum=$SizeMiB type=fixed", 'exit'))
& diskpart.exe /s $script | Out-Null
if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $Output)) { throw 'VHD creation failed' }

$payloadDir = Join-Path $work 'payload'
Expand-Archive -LiteralPath $PayloadZip -DestinationPath $payloadDir

$mounted = $false
try {
    Mount-DiskImage -ImagePath $Output -NoDriveLetter | Out-Null
    $mounted = $true
    $disk = Get-DiskImage -ImagePath $Output | Get-Disk
    if ($disk.BusType -ne 'File Backed Virtual' -or $disk.Size -ne ([uint64]$SizeMiB * 1MB) -or $disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'RAW') {
        throw "unexpected disk identity for the fresh VHD: $($disk | Out-String)"
    }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    foreach ($part in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
        if ($part.GptType -ne '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}') { throw 'unexpected partition in the fresh VHD' }
        $part | Remove-Partition -Confirm:$false
    }
    $esp = New-Partition -DiskNumber $disk.Number -Offset 1MB -Size ([uint64]$EspMiB * 1MB) -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
    $data = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel USOS_ESP -Force -Confirm:$false | Out-Null
    $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel USOS_DATA -Force -Confirm:$false | Out-Null
    $espPath = Join-Path $work 'esp'; $dataPath = Join-Path $work 'data'
    New-Item -ItemType Directory -Force -Path $espPath, $dataPath | Out-Null
    $esp | Add-PartitionAccessPath -AccessPath $espPath
    $data | Add-PartitionAccessPath -AccessPath $dataPath
    try {
        Copy-Item -Path (Join-Path $payloadDir '*') -Destination $espPath -Recurse -Force
        if ($CsmwrapEfi) { Copy-Item -LiteralPath $CsmwrapEfi -Destination (Join-Path $espPath 'EFI\USOS\csmwrap\csmwrapx64.efi') -Force }
        if ($CsmwrapIni) { Copy-Item -LiteralPath $CsmwrapIni -Destination (Join-Path $espPath 'EFI\USOS\csmwrap\csmwrap.ini') -Force }
        foreach ($folder in @('Programs', 'Systems', 'Utilities', 'Utilities\FreeDOS\Programs', 'Systems\DOS\MS-DOS\Programs')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $dataPath $folder) | Out-Null
        }
        if ($DemoDir) {
            Copy-Item -LiteralPath $DemoDir -Destination (Join-Path $dataPath 'Utilities\FreeDOS\Programs\DEMO') -Recurse
            Copy-Item -LiteralPath $DemoDir -Destination (Join-Path $dataPath 'Systems\DOS\MS-DOS\Programs\DEMO') -Recurse
        }
        foreach ($item in @(@{ Src = $MsDosIso; Dir = 'Systems\DOS\MS-DOS\Images' }, @{ Src = $Win31Iso; Dir = 'Systems\Windows\Windows 3.1\Images' })) {
            if (-not $item.Src) { continue }
            $dir = Join-Path $dataPath $item.Dir
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $dst = Join-Path $dir ([IO.Path]::GetFileName($item.Src))
            Copy-Item -LiteralPath $item.Src -Destination $dst
            if ((Get-FileHash -LiteralPath $item.Src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash) { throw "readback mismatch: $dst" }
        }
    } finally {
        $esp | Remove-PartitionAccessPath -AccessPath $espPath -ErrorAction SilentlyContinue
        $data | Remove-PartitionAccessPath -AccessPath $dataPath -ErrorAction SilentlyContinue
    }
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $Output | Out-Null }
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

# BIOS boot code and GPT names, on the raw bytes (a fixed VHD is the raw disk + a footer).
& python (Join-Path $PSScriptRoot 'patch_usos_gpt_names.py') --image $Output
if ($LASTEXITCODE) { throw 'GPT name patch failed' }
$coreArgs = @()
if ($CoreSlot) { $coreArgs = @('--core-slot', $CoreSlot) }
& python (Join-Path $PSScriptRoot 'install_bios_csmwrap_legacy_boot.py') --image $Output @coreArgs
if ($LASTEXITCODE) { throw 'legacy boot install failed' }
Write-Output "PASS: $Output"
