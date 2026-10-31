# Host validation of the MiniOS Win10 x86 CSMWrap disk (no VM, run elevated):
# zig-out/bin/usosprep-csmwrap-disk writes the route's disk (csmwrap_write.zig,
# the code uefi_main.runCsmwrapSetup runs) into a fixed raw file, which gets a
# VHD footer and is attached READ-ONLY; then Windows' own chkdsk (read-only
# mode) on both NTFS volumes, bcdedit /store on the staging BCD, DISM and
# wimlib-imagex verify on the staging boot.wim. Everything is deleted after.
#   powershell -File tools\tests\minios_csmwrap_vhd.ps1 -Iso <Win10 x86 ISO> -Work <empty dir> [-GiB 20] [-Bus nvme|other]
# Microsoft files are only read from the user's ISO; nothing goes into git.
param([Parameter(Mandatory)][string]$Iso, [Parameter(Mandatory)][string]$Work, [int]$GiB = 20, [string]$Bus = 'nvme')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
$tool = "$root\zig-out\bin\usosprep-csmwrap-disk.exe"
$wimlib = "$root\tools\vendor\wimlib\1.14.5\wimlib-imagex.exe"
New-Item -ItemType Directory -Force $Work | Out-Null
$raw = Join-Path $Work 'minios-csmwrap.raw'
$vhd = Join-Path $Work 'minios-csmwrap.vhd'
$fail = 0
try {
    fsutil file createnew $raw ([int64]$GiB * 1GB) | Out-Null
    & $tool $raw $Iso "$root\zig-out\windows-native\support.cpio" "$root\zig-out\windows-native\modern-support.cpio" "$root\zig-out\xp-geometry-fix-mbr\xp-geometry-fix-mbr-440.bin" "$root\zig-out\xp-bios\vista-nt60-ntfs.bin" $Bus --usosres "$root\zig-out\windows-usos-res\USOSRES.EXE" --csmwrap "$root\zig-out\usb\EFI\USOS\csmwrap"
    if ($LASTEXITCODE -ne 0) { throw "harness exit $LASTEXITCODE" }
    # Fixed VHD footer (big-endian, checksum over the footer).
    $size = (Get-Item $raw).Length
    $f = New-Object byte[] 512
    function Put([int]$o, [byte[]]$b) { [Array]::Copy($b, 0, $f, $o, $b.Length) }
    function BE([UInt64]$v, [int]$n) { $b = [BitConverter]::GetBytes($v); [Array]::Reverse($b); $b[(8 - $n)..7] }
    Put 0 ([Text.Encoding]::ASCII.GetBytes('conectix')); Put 8 (BE 2 4); Put 12 (BE 0x10000 4); Put 16 (BE ([UInt64]::MaxValue) 8)
    Put 28 ([Text.Encoding]::ASCII.GetBytes('usos')); Put 32 (BE 0x10000 4); Put 36 ([Text.Encoding]::ASCII.GetBytes('Wi2k'))
    Put 40 (BE $size 8); Put 48 (BE $size 8); Put 56 (BE 65535 2); $f[58] = 16; $f[59] = 255; Put 60 (BE 2 4); Put 68 ([Guid]::NewGuid().ToByteArray())
    $sum = 0; foreach ($b in $f) { $sum += $b }; Put 64 (BE ((-bnot [UInt32]$sum) -band 0xffffffff) 4)
    $s = [IO.File]::Open($raw, 'Append'); $s.Write($f, 0, 512); $s.Close()
    Move-Item $raw $vhd
    $disk = Mount-DiskImage -ImagePath $vhd -Access ReadOnly -NoDriveLetter -PassThru | Get-Disk
    foreach ($p in Get-Partition -DiskNumber $disk.Number) {
        $v = $p.AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1
        if (-not $v -or $p.Type -ne 'IFS') { continue }
        $out = cmd /c "chkdsk $($v.TrimEnd('\')) 2>&1"
        $ok = ($LASTEXITCODE -eq 0) -and ($out -match 'found no problems')
        "CHKDSK partition $($p.PartitionNumber) $(if ($ok) {'PASS'} else {'FAIL'})"
        if (-not $ok) { $fail++; $out }
        if ($p.IsActive) {
            cmd /c "copy /y $($v)boot\bcd `"$Work\bcd`"" | Out-Null
            cmd /c "copy /y $($v)sources\boot.wim `"$Work\boot.wim`"" | Out-Null
            $bcd = bcdedit /store "$Work\bcd" /enum all
            if ($LASTEXITCODE -ne 0 -or -not ($bcd -match 'ramdisk=\[boot\]\\sources\\boot.wim')) { $fail++; 'BCD FAIL'; $bcd } else { 'BCD PASS' }
            if ($Bus -eq 'nvme' -and -not ($bcd -match 'truncatememory\s+0x100000000')) { $fail++; 'BCD truncatememory FAIL' }
            dism /English /Get-WimInfo /WimFile:"$Work\boot.wim" /Index:1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $fail++; 'DISM FAIL' } else { 'DISM PASS' }
            $ErrorActionPreference = 'Continue'
            $null = & $wimlib verify "$Work\boot.wim" 2>&1
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -ne 0) { $fail++; 'WIMLIB VERIFY FAIL' } else { 'WIMLIB VERIFY PASS' }
        }
    }
} finally {
    if (Test-Path $vhd) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item -Force -ErrorAction SilentlyContinue $raw, $vhd, "$Work\bcd", "$Work\boot.wim"
}
if ($fail) { "MINIOS CSMWRAP VHD FAIL ($fail)"; exit 1 }
'MINIOS CSMWRAP VHD PASS'
