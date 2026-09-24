<#
.SYNOPSIS
  Read-only snapshot / compare of the USOS Kingston stick (GPT + ESP + WORK + DATA).

.DESCRIPTION
  Takes a snapshot of the stick using read-only operations only:
    - Get-Disk / Get-Partition / Get-Volume
    - raw read of LBA 0-33 and the last 33 LBAs (backup GPT) via \\.\PhysicalDriveN opened FileAccess.Read
    - optional raw read-only SHA-256 of the whole ESP volume
    - directory enumeration (no file opens) for metadata on all volumes
    - ESP (FAT32) content hashes from a raw FileAccess.Read of the volume device, parsing FAT32
      directly: opening files through fastfat would update their FAT last-access dates
    - WORK/DATA (NTFS, last-access updates disabled on this host) hashed with FileAccess.Read handles
    - bcdedit /enum firmware (read-only)
  Nothing is written to the stick and no drive letters are assigned or removed. Volumes are
  accessed through their \\?\Volume{GUID}\ paths so drive letters do not matter.

  -SnapshotOnly   take a snapshot into -OutDir and stop (used to create a baseline)
  -Baseline DIR   take a new snapshot (into -OutDir or a compare-<ts> folder next to DIR)
                  and report added / removed / changed files per volume and GPT changes.
                  Exit code 0 = no differences, 1 = differences, 2 = error.

.EXAMPLE
  .\tools\compare_esp_snapshot.ps1 -SnapshotOnly -OutDir artifacts\win10-esp-test\baseline-20260924-120000
  .\tools\compare_esp_snapshot.ps1 -Baseline artifacts\win10-esp-test\baseline-20260924-120000
#>
[CmdletBinding()]
param(
    [string]$Baseline,
    [string]$OutDir,
    [switch]$SnapshotOnly,
    [string]$DiskGuid = '{31c644bf-74dd-4807-9cb2-46745adeadd4}',
    [switch]$NoRawEspHash,
    [switch]$IncludeAccessTime   # also treat LastAccessTime differences as changes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------- helpers
function Get-Sha256OfBytes([byte[]]$b) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($b)) -replace '-', '') } finally { $h.Dispose() }
}

function Get-Sha256OfFile([string]$path) {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $h = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($h.ComputeHash($fs)) -replace '-', '') } finally { $h.Dispose() }
    } finally { $fs.Dispose() }
}

function Read-RawSectors([string]$device, [long]$offset, [int]$length) {
    $fs = New-Object IO.FileStream($device, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::None)
    try {
        [void]$fs.Seek($offset, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $length
        $got = 0
        while ($got -lt $length) {
            $n = $fs.Read($buf, $got, $length - $got)
            if ($n -le 0) { throw "short read on $device at $offset" }
            $got += $n
        }
        return , $buf
    } finally { $fs.Dispose() }
}

function Get-RawVolumeSha256([string]$volumePathNoSlash, [long]$size) {
    $fs = New-Object IO.FileStream($volumePathNoSlash, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::None)
    try {
        $h = [Security.Cryptography.SHA256]::Create()
        $chunk = 1MB
        $buf = New-Object byte[] $chunk
        [long]$done = 0
        while ($done -lt $size) {
            $want = [int][Math]::Min([long]$chunk, $size - $done)
            $n = $fs.Read($buf, 0, $want)
            if ($n -le 0) { break }
            [void]$h.TransformBlock($buf, 0, $n, $null, 0)
            $done += $n
        }
        [void]$h.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return [pscustomobject]@{ Bytes = $done; SHA256 = ([BitConverter]::ToString($h.Hash) -replace '-', '') }
    } finally { $fs.Dispose() }
}

function ConvertFrom-GptBytes([byte[]]$hdr, [byte[]]$entries) {
    $sig = [Text.Encoding]::ASCII.GetString($hdr, 0, 8)
    $diskGuidBytes = New-Object byte[] 16; [Array]::Copy($hdr, 56, $diskGuidBytes, 0, 16)
    $h = [ordered]@{
        Signature         = $sig
        Revision          = ('0x{0:X8}' -f [BitConverter]::ToUInt32($hdr, 8))
        HeaderSize        = [BitConverter]::ToUInt32($hdr, 12)
        HeaderCRC32       = ('0x{0:X8}' -f [BitConverter]::ToUInt32($hdr, 16))
        MyLBA             = [BitConverter]::ToUInt64($hdr, 24)
        AlternateLBA      = [BitConverter]::ToUInt64($hdr, 32)
        FirstUsableLBA    = [BitConverter]::ToUInt64($hdr, 40)
        LastUsableLBA     = [BitConverter]::ToUInt64($hdr, 48)
        DiskGUID          = ([Guid]::new($diskGuidBytes)).ToString()
        PartEntryLBA      = [BitConverter]::ToUInt64($hdr, 72)
        NumPartEntries    = [BitConverter]::ToUInt32($hdr, 80)
        PartEntrySize     = [BitConverter]::ToUInt32($hdr, 84)
        PartEntriesCRC32  = ('0x{0:X8}' -f [BitConverter]::ToUInt32($hdr, 88))
    }
    $parts = @()
    $es = [int]$h.PartEntrySize
    for ($i = 0; $i -lt $h.NumPartEntries -and (($i + 1) * $es) -le $entries.Length; $i++) {
        $o = $i * $es
        $tb = New-Object byte[] 16; [Array]::Copy($entries, $o, $tb, 0, 16)
        $t = [Guid]::new($tb)
        if ($t -eq [Guid]::Empty) { continue }
        $ub = New-Object byte[] 16; [Array]::Copy($entries, $o + 16, $ub, 0, 16)
        $first = [BitConverter]::ToUInt64($entries, $o + 32)
        $last = [BitConverter]::ToUInt64($entries, $o + 40)
        $attr = [BitConverter]::ToUInt64($entries, $o + 48)
        $name = [Text.Encoding]::Unicode.GetString($entries, $o + 56, 72).TrimEnd([char]0)
        $parts += [pscustomobject][ordered]@{
            Index       = $i + 1
            TypeGUID    = $t.ToString()
            UniqueGUID  = ([Guid]::new($ub)).ToString()
            FirstLBA    = $first
            LastLBA     = $last
            OffsetBytes = [uint64]($first * 512)
            SizeBytes   = [uint64](($last - $first + 1) * 512)
            Attributes  = ('0x{0:X16}' -f $attr)
            Name        = $name
        }
    }
    return [pscustomobject]@{ Header = [pscustomobject]$h; Partitions = $parts }
}

function Get-TreeListing {
    param([string]$Root, [int]$MaxDepth = [int]::MaxValue, [switch]$Hash, [string]$Prefix = '')
    # Root must end with '\'. Returns objects with RelPath relative to the volume root.
    $out = New-Object Collections.Generic.List[object]
    $errs = New-Object Collections.Generic.List[string]
    $stack = New-Object Collections.Generic.Stack[object]
    $stack.Push(@($Root, 1))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop(); $dir = $item[0]; $depth = $item[1]
        try { $children = ([IO.DirectoryInfo]::new($dir)).GetFileSystemInfos() }
        catch { $errs.Add("ENUM-ERROR`t$dir`t$($_.Exception.InnerException.Message)$($_.Exception.Message)"); continue }
        foreach ($c in ($children | Sort-Object Name)) {
            $isDir = ($c.Attributes -band [IO.FileAttributes]::Directory) -ne 0
            $rel = $Prefix + $c.FullName.Substring($Root.Length)
            $sha = ''
            if (-not $isDir -and $Hash) {
                try { $sha = Get-Sha256OfFile $c.FullName } catch { $sha = 'ERROR'; $errs.Add("HASH-ERROR`t$rel`t$($_.Exception.Message)") }
            }
            $out.Add([pscustomobject][ordered]@{
                RelPath       = $rel
                Type          = $(if ($isDir) { 'D' } else { 'F' })
                Length        = $(if ($isDir) { '' } else { [string]$c.Length })
                CreationUtc   = $c.CreationTimeUtc.ToString('o')
                LastWriteUtc  = $c.LastWriteTimeUtc.ToString('o')
                LastAccessUtc = $c.LastAccessTimeUtc.ToString('o')
                Attributes    = [string]$c.Attributes
                SHA256        = $sha
            })
            $isReparse = ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isDir -and -not $isReparse -and $depth -lt $MaxDepth) { $stack.Push(@(($c.FullName + '\'), ($depth + 1))) }
        }
    }
    return [pscustomobject]@{ Items = ($out | Sort-Object RelPath); Errors = $errs }
}

# Raw FAT32 reader: hashes every file of a FAT32 volume by parsing the BPB, FAT and directory
# entries from a FileAccess.Read handle on the volume device. Opening files through the file
# system makes fastfat update the FAT "last access date" of each file read (the NTFS
# disable-last-access policy does not apply to FAT), so the ESP is hashed this way instead.
function Get-Fat32RawHashes([string]$volNoSlash) {
    $fs = New-Object IO.FileStream($volNoSlash, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::None)
    try {
        $read = {
            param([long]$off, [int]$len)
            [void]$fs.Seek($off, [IO.SeekOrigin]::Begin)
            $b = New-Object byte[] $len; $g = 0
            while ($g -lt $len) { $n = $fs.Read($b, $g, $len - $g); if ($n -le 0) { throw "raw short read at $off" }; $g += $n }
            , $b
        }
        $bs = & $read 0 512
        if ([Text.Encoding]::ASCII.GetString($bs, 82, 8) -notmatch 'FAT32') { throw 'volume is not FAT32' }
        $bps = [BitConverter]::ToUInt16($bs, 11); $spc = $bs[13]
        $rsv = [BitConverter]::ToUInt16($bs, 14); $nf = $bs[16]
        $fsz = [BitConverter]::ToUInt32($bs, 36); $rootClus = [BitConverter]::ToUInt32($bs, 44)
        $clusBytes = [int]($bps * $spc)
        $dataStart = [long]($rsv + $nf * $fsz) * $bps
        $fat = & $read ([long]$rsv * $bps) ([int]($fsz * $bps))
        $maxClus = [uint32]($fat.Length / 4)
        $chain = {
            param([uint32]$c)
            $l = New-Object Collections.Generic.List[uint32]
            while ($c -ge 2 -and $c -lt 0x0FFFFFF7 -and $c -lt $maxClus -and $l.Count -lt 1000000) {
                $l.Add($c); $c = [BitConverter]::ToUInt32($fat, [int]($c * 4)) -band 0x0FFFFFFF
            }
            , $l
        }
        $readChain = {
            param([uint32]$first, [long]$size, $hasher)
            # returns bytes (dirs) or feeds $hasher (files); contiguous runs read in one go
            $cl = & $chain $first
            $ms = if ($hasher) { $null } else { New-Object IO.MemoryStream }
            [long]$left = $(if ($size -ge 0) { $size } else { [long]$cl.Count * $clusBytes })
            $i = 0
            while ($i -lt $cl.Count -and $left -gt 0) {
                $j = $i
                while (($j + 1) -lt $cl.Count -and $cl[$j + 1] -eq ($cl[$j] + 1) -and ($j - $i) -lt 255) { $j++ }
                $runBytes = [long]($j - $i + 1) * $clusBytes
                $take = [int][Math]::Min($runBytes, $left)
                $buf = & $read ($dataStart + [long]($cl[$i] - 2) * $clusBytes) ([int]$runBytes)
                if ($hasher) { [void]$hasher.TransformBlock($buf, 0, $take, $null, 0) } else { $ms.Write($buf, 0, $take) }
                $left -= $take; $i = $j + 1
            }
            if ($left -gt 0) { throw "cluster chain shorter than file size (first cluster $first)" }
            if (-not $hasher) { , $ms.ToArray() }
        }
        $result = @{}
        $stack = New-Object Collections.Generic.Stack[object]
        $stack.Push(@($rootClus, ''))
        while ($stack.Count -gt 0) {
            $it = $stack.Pop(); $dirBytes = & $readChain ([uint32]$it[0]) -1 $null; $prefix = $it[1]
            $lfn = @{}
            for ($o = 0; $o -le $dirBytes.Length - 32; $o += 32) {
                $f = $dirBytes[$o]
                if ($f -eq 0) { break }
                if ($f -eq 0xE5) { $lfn = @{}; continue }
                $attr = $dirBytes[$o + 11]
                if ($attr -eq 0x0F) {
                    $seq = $f -band 0x1F
                    $ch = New-Object byte[] 26
                    [Array]::Copy($dirBytes, $o + 1, $ch, 0, 10); [Array]::Copy($dirBytes, $o + 14, $ch, 10, 12); [Array]::Copy($dirBytes, $o + 28, $ch, 22, 4)
                    $lfn[[int]$seq] = [Text.Encoding]::Unicode.GetString($ch)
                    continue
                }
                if ($attr -band 0x08) { $lfn = @{}; continue }   # volume label
                $base = [Text.Encoding]::ASCII.GetString($dirBytes, $o, 8).TrimEnd()
                $ext = [Text.Encoding]::ASCII.GetString($dirBytes, $o + 8, 3).TrimEnd()
                if ($f -eq 0x05) { $base = [char]0xE5 + $base.Substring(1) }
                if ($base -eq '.' -or $base -eq '..') { $lfn = @{}; continue }
                if ($lfn.Count) {
                    $name = (($lfn.Keys | Sort-Object | ForEach-Object { $lfn[$_] }) -join '')
                    $z = $name.IndexOf([char]0); if ($z -ge 0) { $name = $name.Substring(0, $z) }
                } else {
                    $nt = $dirBytes[$o + 12]
                    if ($nt -band 0x08) { $base = $base.ToLowerInvariant() }
                    if ($nt -band 0x10) { $ext = $ext.ToLowerInvariant() }
                    $name = $(if ($ext) { "$base.$ext" } else { $base })
                }
                $lfn = @{}
                $clus = ([uint32][BitConverter]::ToUInt16($dirBytes, $o + 20) -shl 16) -bor [BitConverter]::ToUInt16($dirBytes, $o + 26)
                $size = [BitConverter]::ToUInt32($dirBytes, $o + 28)
                $rel = $prefix + $name
                if ($attr -band 0x10) {
                    if ($clus -ge 2) { $stack.Push(@($clus, ($rel + '\'))) }
                } else {
                    $h = [Security.Cryptography.SHA256]::Create()
                    try {
                        if ($size -gt 0) { & $readChain $clus ([long]$size) $h }
                        [void]$h.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                        $result[$rel.ToLowerInvariant()] = ([BitConverter]::ToString($h.Hash) -replace '-', '')
                    } catch { $result[$rel.ToLowerInvariant()] = "ERROR: $($_.Exception.Message)" }
                    finally { $h.Dispose() }
                }
            }
        }
        return $result
    } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------- snapshot
function New-UsosSnapshot([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $log = New-Object Collections.Generic.List[string]
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

    $disk = Get-Disk | Where-Object { $_.Guid -eq $DiskGuid }
    if (-not $disk) { throw "Disk $DiskGuid not found" }
    if (@($disk).Count -ne 1) { throw "More than one disk matched $DiskGuid" }
    if ($disk.FriendlyName -notmatch 'DataTraveler') { throw "Disk $DiskGuid is '$($disk.FriendlyName)', not the Kingston DataTraveler" }
    $disk | Select-Object Number, FriendlyName, Model, SerialNumber, Size, PartitionStyle, Guid, Signature,
        LogicalSectorSize, PhysicalSectorSize, BusType, IsReadOnly, IsOffline, NumberOfPartitions |
        ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Dir 'disk.json')

    $parts = @(Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)
    $parts | Select-Object PartitionNumber, DriveLetter, GptType, Guid, Offset, Size, IsHidden, IsActive,
        IsSystem, IsBoot, NoDefaultDriveLetter, @{n = 'AccessPaths'; e = { $_.AccessPaths -join ';' } } |
        ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Dir 'partitions.json')

    $vols = foreach ($p in $parts) {
        $v = $null
        try { $v = $p | Get-Volume } catch {}
        $vp = ($p.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' } | Select-Object -First 1)
        [pscustomobject][ordered]@{
            PartitionNumber = $p.PartitionNumber; DriveLetter = [string]$p.DriveLetter
            Label = $(if ($v) { $v.FileSystemLabel } else { '' }); FileSystem = $(if ($v) { $v.FileSystem } else { '' })
            VolumeSize = $(if ($v) { $v.Size } else { 0 }); PartSize = $p.Size; VolumePath = $vp
        }
    }
    $vols | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Dir 'volumes.json')

    # --- raw GPT (read-only)
    $dev = "\\.\PhysicalDrive$($disk.Number)"
    $primary = Read-RawSectors $dev 0 (34 * 512)
    [IO.File]::WriteAllBytes((Join-Path $Dir 'gpt_primary_lba0-33.bin'), $primary)
    $lastLba = [long]($disk.Size / 512) - 1
    $backupOff = ($lastLba - 32) * 512
    $backup = Read-RawSectors $dev $backupOff (33 * 512)
    [IO.File]::WriteAllBytes((Join-Path $Dir 'gpt_backup_last33.bin'), $backup)

    $pHdr = New-Object byte[] 512; [Array]::Copy($primary, 512, $pHdr, 0, 512)
    $pEnt = New-Object byte[] (32 * 512); [Array]::Copy($primary, 1024, $pEnt, 0, 32 * 512)
    $bHdr = New-Object byte[] 512; [Array]::Copy($backup, 32 * 512, $bHdr, 0, 512)
    $bEnt = New-Object byte[] (32 * 512); [Array]::Copy($backup, 0, $bEnt, 0, 32 * 512)
    $gP = ConvertFrom-GptBytes $pHdr $pEnt
    $gB = ConvertFrom-GptBytes $bHdr $bEnt
    $mbrSig = '0x{0:X8}' -f [BitConverter]::ToUInt32($primary, 440)
    $mbrType = '0x{0:X2}' -f $primary[450]
    $gpt = [pscustomobject][ordered]@{
        Device = $dev; DiskSizeBytes = $disk.Size; LastLBA = $lastLba
        ProtectiveMBR_DiskSignature = $mbrSig; ProtectiveMBR_Part1Type = $mbrType
        ProtectiveMBR_BootSig = ('0x{0:X2}{1:X2}' -f $primary[511], $primary[510])
        PrimaryHeader = $gP.Header; BackupHeader = $gB.Header
        Partitions = $gP.Partitions
        BackupEntriesMatchPrimary = ((Get-Sha256OfBytes $pEnt) -eq (Get-Sha256OfBytes $bEnt))
        SHA256_Primary_LBA0_33 = (Get-Sha256OfBytes $primary)
        SHA256_Backup_Last33 = (Get-Sha256OfBytes $backup)
        SHA256_PrimaryEntries = (Get-Sha256OfBytes $pEnt)
    }
    $gpt | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $Dir 'gpt.json')
    @("$($gpt.SHA256_Primary_LBA0_33)  gpt_primary_lba0-33.bin", "$($gpt.SHA256_Backup_Last33)  gpt_backup_last33.bin") |
        Set-Content -Encoding ASCII (Join-Path $Dir 'gpt_bins.sha256')

    # --- volumes
    $esp = $vols | Where-Object { $_.Label -eq 'USOS_ESP' } | Select-Object -First 1
    $data = $vols | Where-Object { $_.Label -eq 'USOS_DATA' } | Select-Object -First 1
    $work = $vols | Where-Object { $_.Label -eq 'USOS_WORK' } | Select-Object -First 1
    if (-not $esp) { $esp = $vols | Where-Object { $_.PartitionNumber -eq 1 } | Select-Object -First 1; $log.Add('WARN: USOS_ESP label not found, using partition 1') }
    if (-not $data) { $data = $vols | Where-Object { $_.PartitionNumber -eq 2 } | Select-Object -First 1; $log.Add('WARN: USOS_DATA label not found, using partition 2') }
    if (-not $work) { $work = $vols | Where-Object { $_.PartitionNumber -eq 3 } | Select-Object -First 1; $log.Add('WARN: USOS_WORK label not found, using partition 3') }

    $counts = [ordered]@{}
    $espRaw = $null
    $espList = $null
    if ($esp -and $esp.VolumePath) {
        # metadata via directory enumeration (no file opens), content hashes via raw FAT32 read
        $r = Get-TreeListing -Root $esp.VolumePath
        $raw = Get-Fat32RawHashes ($esp.VolumePath.TrimEnd('\'))
        foreach ($x in $r.Items) {
            if ($x.Type -ne 'F') { continue }
            $k = $x.RelPath.ToLowerInvariant()
            if ($raw.ContainsKey($k)) { $x.SHA256 = $raw[$k]; if ($raw[$k] -like 'ERROR*') { $log.Add("ESP RAW-HASH-ERROR`t$($x.RelPath)`t$($raw[$k])") } }
            else { $x.SHA256 = 'RAW-NOTFOUND'; $log.Add("ESP RAW-NOTFOUND`t$($x.RelPath)") }
        }
        $espList = $r.Items
        $r.Items | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Dir 'esp_files.csv')
        $r.Errors | ForEach-Object { $log.Add("ESP $_") }
        $counts['ESP'] = '{0} files, {1} dirs (full recursive, hashed)' -f @($r.Items | Where-Object Type -eq 'F').Count, @($r.Items | Where-Object Type -eq 'D').Count
        if (-not $NoRawEspHash) {
            try { $espRaw = Get-RawVolumeSha256 ($esp.VolumePath.TrimEnd('\')) ([long]$esp.PartSize) }
            catch { $log.Add("ESP raw hash failed: $($_.Exception.Message)") }
        }
    } else { $log.Add('ERROR: ESP volume path not found') }

    if ($work -and $work.VolumePath) {
        $r = Get-TreeListing -Root $work.VolumePath -MaxDepth 2
        $r.Items | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Dir 'work_top2.csv')
        $r.Errors | ForEach-Object { $log.Add("WORK $_") }
        $wTop = $r.Items
        $efiDir = ([IO.DirectoryInfo]::new($work.VolumePath)).GetDirectories() | Where-Object { $_.Name -ieq 'efi' } | Select-Object -First 1
        $wEfi = @()
        if ($efiDir) {
            $r2 = Get-TreeListing -Root ($efiDir.FullName + '\') -Hash -Prefix ($efiDir.Name + '\')
            $wEfi = $r2.Items
            $r2.Errors | ForEach-Object { $log.Add("WORK-EFI $_") }
        }
        $wEfi | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Dir 'work_efi.csv')
        $counts['WORK'] = '{0} files, {1} dirs in top 2 levels; EFI\: {2} files, {3} dirs (hashed)' -f @($wTop | Where-Object Type -eq 'F').Count, @($wTop | Where-Object Type -eq 'D').Count, @($wEfi | Where-Object Type -eq 'F').Count, @($wEfi | Where-Object Type -eq 'D').Count
    } else { $log.Add('ERROR: WORK volume path not found') }

    if ($data -and $data.VolumePath) {
        $r = Get-TreeListing -Root $data.VolumePath -MaxDepth 1
        $r.Items | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Dir 'data_top.csv')
        $r.Errors | ForEach-Object { $log.Add("DATA $_") }
        $dTop = $r.Items
        $drvDir = ([IO.DirectoryInfo]::new($data.VolumePath)).GetDirectories() | Where-Object { $_.Name -ieq 'Drivers' } | Select-Object -First 1
        $dDrv = @()
        if ($drvDir) {
            $r2 = Get-TreeListing -Root ($drvDir.FullName + '\') -Prefix ($drvDir.Name + '\')
            $dDrv = $r2.Items
            $r2.Errors | ForEach-Object { $log.Add("DATA-Drivers $_") }
        }
        $dDrv | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Dir 'data_drivers.csv')
        $counts['DATA'] = '{0} files, {1} dirs at top level; Drivers\: {2} files, {3} dirs (listing only)' -f @($dTop | Where-Object Type -eq 'F').Count, @($dTop | Where-Object Type -eq 'D').Count, @($dDrv | Where-Object Type -eq 'F').Count, @($dDrv | Where-Object Type -eq 'D').Count
    } else { $log.Add('ERROR: DATA volume path not found') }

    # --- bcdedit (read-only)
    $bcd = & bcdedit.exe /enum firmware 2>&1 | Out-String
    Set-Content -Encoding UTF8 -Path (Join-Path $Dir 'bcdedit_enum_firmware.txt') -Value $bcd

    $meta = [ordered]@{
        Taken = $ts; Host = $env:COMPUTERNAME; DiskGuid = $DiskGuid; DiskNumber = $disk.Number
        Counts = $counts; EspRawSha256 = $(if ($espRaw) { $espRaw.SHA256 } else { '' })
        EspRawBytes = $(if ($espRaw) { $espRaw.Bytes } else { 0 }); Log = @($log)
    }
    $meta | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $Dir 'snapshot_meta.json')
    Set-Content -Encoding UTF8 (Join-Path $Dir 'errors.txt') -Value (@($log) -join "`r`n")

    # --- summary.txt
    $s = New-Object Collections.Generic.List[string]
    $s.Add("USOS stick read-only snapshot"); $s.Add("Taken: $ts on $env:COMPUTERNAME"); $s.Add('')
    $s.Add("Disk: $($disk.FriendlyName) (model '$($disk.Model)', serial '$($disk.SerialNumber)'), disk #$($disk.Number), $($disk.BusType)")
    $s.Add("  Size: $($disk.Size) bytes ($([math]::Round($disk.Size/1GB,2)) GiB), sector $($disk.LogicalSectorSize)")
    $s.Add("  GPT disk GUID: $($gpt.PrimaryHeader.DiskGUID)  (Get-Disk Guid $($disk.Guid))")
    $s.Add("  Protective MBR disk signature: $mbrSig, part1 type $mbrType, boot sig $($gpt.ProtectiveMBR_BootSig)")
    $s.Add("  GPT header CRC $($gpt.PrimaryHeader.HeaderCRC32), entries CRC $($gpt.PrimaryHeader.PartEntriesCRC32), backup at LBA $($gpt.PrimaryHeader.AlternateLBA), backup entries match primary: $($gpt.BackupEntriesMatchPrimary)")
    $s.Add("  SHA256 gpt_primary_lba0-33.bin: $($gpt.SHA256_Primary_LBA0_33)")
    $s.Add("  SHA256 gpt_backup_last33.bin : $($gpt.SHA256_Backup_Last33)")
    $s.Add(''); $s.Add('Partitions (raw GPT):')
    foreach ($p in $gpt.Partitions) {
        $vv = $vols | Where-Object { $_.PartitionNumber -eq $p.Index }
        $s.Add(("  #{0} type {1} unique {2} attr {3} LBA {4}-{5} offset {6} size {7} name '{8}'" -f $p.Index, $p.TypeGUID, $p.UniqueGUID, $p.Attributes, $p.FirstLBA, $p.LastLBA, $p.OffsetBytes, $p.SizeBytes, $p.Name))
        if ($vv) { $s.Add(("      letter '{0}' label '{1}' fs {2} volume {3}" -f $vv.DriveLetter, $vv.Label, $vv.FileSystem, $vv.VolumePath)) }
    }
    $s.Add(''); $s.Add('Counts:')
    foreach ($k in $counts.Keys) { $s.Add("  ${k}: $($counts[$k])") }
    if ($espRaw) { $s.Add(''); $s.Add("ESP raw volume SHA256 ($($espRaw.Bytes) bytes): $($espRaw.SHA256)") }
    if ($espList) {
        $s.Add(''); $s.Add('ESP boot-relevant files:')
        $espList | Where-Object { $_.Type -eq 'F' -and ($_.RelPath -match '^EFI\\(Microsoft|BOOT)\\' -or $_.RelPath -match '(?i)(\\|^)(BCD|bootmgr|bootmgfw\.efi|bootmgr\.efi)$') } |
            ForEach-Object { $s.Add(('  {0,-60} {1,10}  {2}  {3}' -f $_.RelPath, $_.Length, $_.LastWriteUtc, $_.SHA256)) }
    }
    $s.Add(''); $s.Add('Files:')
    $s.Add('  disk.json partitions.json volumes.json gpt.json gpt_*.bin gpt_bins.sha256')
    $s.Add('  esp_files.csv work_top2.csv work_efi.csv data_top.csv data_drivers.csv bcdedit_enum_firmware.txt snapshot_meta.json errors.txt')
    $s.Add(''); $s.Add("Enumeration notes/errors: $($log.Count)")
    foreach ($l in $log) { $s.Add("  $l") }
    $s.Add(''); $s.Add('Method: read-only only (Get-Disk/Get-Partition/Get-Volume, FileAccess.Read raw reads, raw FAT32 parsing for ESP hashes, FileAccess.Read NTFS file hashes, bcdedit /enum firmware). Nothing written to the stick; no drive letters changed.')
    Set-Content -Encoding UTF8 -Path (Join-Path $Dir 'summary.txt') -Value ($s -join "`r`n")
    return $Dir
}

# ---------------------------------------------------------------- compare
function Compare-Listing([string]$name, [string]$baseCsv, [string]$newCsv, [Collections.Generic.List[string]]$rep) {
    $b = @(); $n = @()
    if (Test-Path $baseCsv) { $b = @(Import-Csv $baseCsv) }
    if (Test-Path $newCsv) { $n = @(Import-Csv $newCsv) }
    $bi = @{}; foreach ($x in $b) { $bi[$x.RelPath.ToLowerInvariant()] = $x }
    $ni = @{}; foreach ($x in $n) { $ni[$x.RelPath.ToLowerInvariant()] = $x }
    $fields = @('Type', 'Length', 'SHA256', 'LastWriteUtc', 'CreationUtc', 'Attributes')
    if ($IncludeAccessTime) { $fields += 'LastAccessUtc' }
    $added = @($n | Where-Object { -not $bi.ContainsKey($_.RelPath.ToLowerInvariant()) })
    $removed = @($b | Where-Object { -not $ni.ContainsKey($_.RelPath.ToLowerInvariant()) })
    $changed = @(); $accessOnly = 0
    foreach ($x in $n) {
        $k = $x.RelPath.ToLowerInvariant()
        if (-not $bi.ContainsKey($k)) { continue }
        $o = $bi[$k]
        $d = @($fields | Where-Object { $o.$_ -ne $x.$_ } | ForEach-Object { "$_ '$($o.$_)' -> '$($x.$_)'" })
        if ($d.Count) { $changed += "  ~ $($x.RelPath): " + ($d -join '; ') }
        elseif ($o.LastAccessUtc -ne $x.LastAccessUtc) { $accessOnly++ }
    }
    $rep.Add("[$name] base $($b.Count) entries, new $($n.Count) entries: +$($added.Count) added, -$($removed.Count) removed, ~$($changed.Count) changed" + $(if ($accessOnly) { " ($accessOnly access-time-only, ignored)" } else { '' }))
    foreach ($x in $added) { $rep.Add("  + $($x.RelPath) [$($x.Type)] $($x.Length) $($x.SHA256)") }
    foreach ($x in $removed) { $rep.Add("  - $($x.RelPath) [$($x.Type)] $($x.Length) $($x.SHA256)") }
    foreach ($x in $changed) { $rep.Add($x) }
    return ($added.Count + $removed.Count + $changed.Count)
}

function Compare-Snapshots([string]$baseDir, [string]$newDir) {
    $rep = New-Object Collections.Generic.List[string]
    $diff = 0
    $rep.Add("Compare: baseline $baseDir"); $rep.Add("         new      $newDir"); $rep.Add('')

    $bg = Get-Content -Raw (Join-Path $baseDir 'gpt.json') | ConvertFrom-Json
    $ng = Get-Content -Raw (Join-Path $newDir 'gpt.json') | ConvertFrom-Json
    $g = New-Object Collections.Generic.List[string]
    foreach ($f in 'ProtectiveMBR_DiskSignature', 'ProtectiveMBR_Part1Type', 'ProtectiveMBR_BootSig', 'BackupEntriesMatchPrimary', 'SHA256_Primary_LBA0_33', 'SHA256_Backup_Last33', 'SHA256_PrimaryEntries') {
        if ([string]$bg.$f -ne [string]$ng.$f) { $g.Add("  ~ $f '$($bg.$f)' -> '$($ng.$f)'") }
    }
    foreach ($hn in 'PrimaryHeader', 'BackupHeader') {
        foreach ($p in $bg.$hn.PSObject.Properties.Name) {
            if ([string]$bg.$hn.$p -ne [string]$ng.$hn.$p) { $g.Add("  ~ $hn.$p '$($bg.$hn.$p)' -> '$($ng.$hn.$p)'") }
        }
    }
    $bp = @{}; foreach ($p in @($bg.Partitions)) { $bp[[string]$p.Index] = $p }
    $np = @{}; foreach ($p in @($ng.Partitions)) { $np[[string]$p.Index] = $p }
    foreach ($k in ($bp.Keys + $np.Keys | Sort-Object -Unique)) {
        if (-not $np.ContainsKey($k)) { $g.Add("  - partition #$k removed ($($bp[$k].TypeGUID) $($bp[$k].UniqueGUID))"); continue }
        if (-not $bp.ContainsKey($k)) { $g.Add("  + partition #$k added ($($np[$k].TypeGUID) $($np[$k].UniqueGUID) LBA $($np[$k].FirstLBA)-$($np[$k].LastLBA) '$($np[$k].Name)')"); continue }
        foreach ($f in 'TypeGUID', 'UniqueGUID', 'FirstLBA', 'LastLBA', 'Attributes', 'Name') {
            if ([string]$bp[$k].$f -ne [string]$np[$k].$f) { $g.Add("  ~ partition #$k $f '$($bp[$k].$f)' -> '$($np[$k].$f)'") }
        }
    }
    $rep.Add("[GPT] $($g.Count) difference(s)"); foreach ($l in $g) { $rep.Add($l) }; $diff += $g.Count

    $bv = @((Get-Content -Raw (Join-Path $baseDir 'volumes.json') | ConvertFrom-Json) | ForEach-Object { $_ })
    $nv = @((Get-Content -Raw (Join-Path $newDir 'volumes.json') | ConvertFrom-Json) | ForEach-Object { $_ })
    $v = New-Object Collections.Generic.List[string]
    foreach ($x in $bv) {
        $y = $nv | Where-Object { $_.PartitionNumber -eq $x.PartitionNumber } | Select-Object -First 1
        if (-not $y) { $v.Add("  - partition $($x.PartitionNumber) volume gone"); continue }
        foreach ($f in 'DriveLetter', 'Label', 'FileSystem', 'VolumeSize', 'VolumePath') {
            if ([string]$x.$f -ne [string]$y.$f) { $v.Add("  ~ partition $($x.PartitionNumber) $f '$($x.$f)' -> '$($y.$f)'") }
        }
    }
    $rep.Add("[VOLUMES] $($v.Count) difference(s) (drive letters / labels / volume GUIDs)"); foreach ($l in $v) { $rep.Add($l) }; $diff += $v.Count
    $rep.Add('')

    $diff += Compare-Listing 'ESP (full, hashed)' (Join-Path $baseDir 'esp_files.csv') (Join-Path $newDir 'esp_files.csv') $rep
    $diff += Compare-Listing 'WORK top 2 levels' (Join-Path $baseDir 'work_top2.csv') (Join-Path $newDir 'work_top2.csv') $rep
    $diff += Compare-Listing 'WORK EFI\ (hashed)' (Join-Path $baseDir 'work_efi.csv') (Join-Path $newDir 'work_efi.csv') $rep
    $diff += Compare-Listing 'DATA top level' (Join-Path $baseDir 'data_top.csv') (Join-Path $newDir 'data_top.csv') $rep
    $diff += Compare-Listing 'DATA Drivers\' (Join-Path $baseDir 'data_drivers.csv') (Join-Path $newDir 'data_drivers.csv') $rep
    $rep.Add('')

    $bm = Get-Content -Raw (Join-Path $baseDir 'snapshot_meta.json') | ConvertFrom-Json
    $nm = Get-Content -Raw (Join-Path $newDir 'snapshot_meta.json') | ConvertFrom-Json
    if ($bm.EspRawSha256 -and $nm.EspRawSha256) {
        $same = $bm.EspRawSha256 -eq $nm.EspRawSha256
        $rep.Add("[ESP raw volume hash] $(if ($same) { 'identical' } else { "DIFFERENT: $($bm.EspRawSha256) -> $($nm.EspRawSha256)" })")
        if (-not $same) { $diff++ }
    }
    $bb = @(Get-Content (Join-Path $baseDir 'bcdedit_enum_firmware.txt'))
    $nb = @(Get-Content (Join-Path $newDir 'bcdedit_enum_firmware.txt'))
    $bd = @(Compare-Object $bb $nb)
    $rep.Add("[bcdedit /enum firmware, host context only, not counted] $($bd.Count) line difference(s)")
    foreach ($x in $bd) { $rep.Add("  $(if ($x.SideIndicator -eq '=>') { '+' } else { '-' }) $($x.InputObject)") }
    $rep.Add('')
    $rep.Add($(if ($diff -eq 0) { 'RESULT: NO DIFFERENCES' } else { "RESULT: $diff DIFFERENCE(S)" }))
    return [pscustomobject]@{ Report = $rep; Count = $diff }
}

# ---------------------------------------------------------------- main
try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($SnapshotOnly) {
        if (-not $OutDir) { $OutDir = Join-Path $repoRoot "artifacts\win10-esp-test\baseline-$stamp" }
        $d = New-UsosSnapshot ([IO.Path]::GetFullPath($OutDir))
        Get-Content (Join-Path $d 'summary.txt')
        Write-Host "Snapshot written to $d"
        exit 0
    }
    if (-not $Baseline) { throw 'Specify -Baseline <folder> or -SnapshotOnly' }
    $Baseline = [IO.Path]::GetFullPath($Baseline)
    if (-not (Test-Path (Join-Path $Baseline 'gpt.json'))) { throw "Not a snapshot folder: $Baseline" }
    if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $Baseline) "compare-$stamp" }
    $d = New-UsosSnapshot ([IO.Path]::GetFullPath($OutDir))
    $r = Compare-Snapshots $Baseline $d
    Set-Content -Encoding UTF8 -Path (Join-Path $d 'compare_report.txt') -Value ($r.Report -join "`r`n")
    $r.Report | ForEach-Object { Write-Host $_ }
    Write-Host "Report: $(Join-Path $d 'compare_report.txt')"
    exit $(if ($r.Count -eq 0) { 0 } else { 1 })
} catch {
    Write-Error $_
    exit 2
}
