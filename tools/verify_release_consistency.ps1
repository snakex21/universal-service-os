param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$usbRoot = Join-Path $ProjectRoot 'zig-out\usb'
$releaseBoot = Join-Path $usbRoot 'EFI\BOOT\BOOTX64.EFI'
$manualBoot = Join-Path $ProjectRoot 'zig-out\manual-usb\EFI\BOOT\BOOTX64.EFI'
$payloadPath = Join-Path $ProjectRoot 'installer\internal\payload\assets\payload.zip'
$buildInfoPath = Join-Path $ProjectRoot 'build\generated\build-info.ini'
$microLinuxInitramfs = Join-Path $ProjectRoot 'zig-out\micro-linux\initramfs-usos'
$strategyBMbr = Join-Path $ProjectRoot 'zig-out\xp-geometry-fix-mbr\xp-geometry-fix-mbr-440.bin'
$win7NativeFiles = @('win7-support.cpio', 'vista-support.cpio', 'int10.efi', 'int10.original.efi', 'UefiSeven.ini', 'uefiseven-LICENSE.txt')
$msDosFiles = @('HIMEMX.EXE', 'HIMEMX.TXT', 'HIMEMSRC.ZIP', 'LICENSE.TXT', 'manifest.json', 'INSTALL.BAT', 'LIVE.BAT', 'PREPDOS.BAT', 'COPYDOS.BAT', 'UNPACK.BAT', 'W3START.BAT', 'WINMENU.BAT', 'W3CONFIG.SYS', 'W3AUTO.BAT', 'REBOOT.COM')

function Test-StaticEspPath([string]$Relative) {
    # USOS-KEY.cer: the Secure Boot certificate at the ESP root (short path in MokManager).
    return ($Relative -match '^(EFI|UI)/') -or ($Relative -eq 'USOS-KEY.cer')
}

function Test-ByteSequence([byte[]]$Haystack, [byte[]]$Needle) {
    if ($Needle.Length -eq 0 -or $Needle.Length -gt $Haystack.Length) { return $false }
    $limit = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        if ($Haystack[$i] -ne $Needle[0]) { continue }
        $match = $true
        for ($j = 1; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

foreach ($required in @($releaseBoot, $manualBoot, $payloadPath, $buildInfoPath, $microLinuxInitramfs, $strategyBMbr)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing release consistency input: $required"
    }
}

# Secure Boot layout: the release BOOTX64.EFI is the vendored shim, and the
# second stage (grubx64.efi) must be the manual-test USOS binary plus only the
# .sbat section, padding and (when a key was available) the signature.
$shimManifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tools\vendor\shim\16.1-7\manifest.json') -Raw | ConvertFrom-Json
$releaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseBoot).Hash
if ($releaseHash -ne $shimManifest.files.'shimx64.efi'.ToUpperInvariant()) {
    throw "Release BOOTX64.EFI is not the vendored shim: $releaseHash"
}
$secondStage = Join-Path $usbRoot ('EFI\BOOT\' + $shimManifest.second_stage)
$secureBootIni = Join-Path $usbRoot 'EFI\USOS\secure-boot.ini'
foreach ($required in @($secondStage, (Join-Path $usbRoot ('EFI\BOOT\' + $shimManifest.mok_manager)), $secureBootIni)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing Secure Boot layout file: $required" }
}
$sbatFile = Join-Path $ProjectRoot 'assets\secure-boot\usos.sbat.csv'
Push-Location (Join-Path $ProjectRoot 'installer')
try {
    & go run ./cmd/usos-efisign derive-check -unsigned $manualBoot -signed $secondStage -sbat $sbatFile
    if ($LASTEXITCODE -ne 0) { throw "Second stage $secondStage does not derive from $manualBoot" }
    if ((Get-Content -LiteralPath $secureBootIni -Raw) -match '(?m)^signed=1\r?$') {
        $enrollCert = Join-Path $usbRoot 'EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer'
        foreach ($signedFile in @($secondStage, (Join-Path $ProjectRoot 'zig-out\micro-linux\vmlinuz-virt'), (Join-Path $ProjectRoot 'zig-out\micro-linux\systemd-bootx64.efi'), (Join-Path $ProjectRoot 'zig-out\test-assets\ntfs_x64.efi'))) {
            & go run ./cmd/usos-efisign verify -in $signedFile -cert $enrollCert
            if ($LASTEXITCODE -ne 0) { throw "Not signed with the enrolled USOS key: $signedFile" }
        }
        $rootCert = Join-Path $usbRoot 'USOS-KEY.cer'
        if (-not (Test-Path -LiteralPath $rootCert -PathType Leaf)) { throw "Missing root certificate copy: $rootCert" }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $rootCert).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $enrollCert).Hash) {
            throw "USOS-KEY.cer differs from EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer"
        }
    } else {
        Write-Host '[WARN] UNSIGNED Secure Boot layout (no signing key): the stick boots only with Secure Boot off.'
    }
} finally {
    Pop-Location
}
$manualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manualBoot).Hash

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($payloadPath)
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $entries = @{}
    foreach ($entry in $archive.Entries) {
        if (-not (Test-StaticEspPath $entry.FullName)) {
            throw "Embedded payload contains DATA/generated-catalog file that does not belong on ESP: $($entry.FullName)"
        }
        $entries[$entry.FullName] = $entry
    }

    $requiredPayloadPaths = @(
        'EFI/BOOT/BOOTX64.EFI',
        'EFI/BOOT/grubx64.efi',
        'EFI/BOOT/mmx64.efi',
        'EFI/USOS/secure-boot.ini',
        'EFI/USOS/ENROLL-README.txt',
        'EFI/USOS/build-info.ini',
        'EFI/USOS/micro-linux/initramfs-usos',
        'EFI/USOS/micro-linux/vmlinuz-virt',
        'EFI/USOS/windows-native/wimboot',
        'EFI/USOS/windows-native/support.cpio',
        'EFI/USOS/dos-native/memdisk',
        'EFI/USOS/dos-native/COPYING',
        'EFI/USOS/dos-native/source.zip',
        'EFI/USOS/dos-native/manifest.json',
        'EFI/USOS/dos-native/ram-patch/PATCH9X.EXE',
        'EFI/USOS/dos-native/ram-patch/CWSDPMI.EXE',
        'EFI/USOS/dos-native/ram-patch/CWSDPMI.TXT',
        'EFI/USOS/dos-native/ram-patch/LICENSE.TXT',
        'EFI/USOS/dos-native/ram-patch/README.TXT',
        'EFI/USOS/dos-native/ram-patch/NOTICE.TXT',
        'EFI/USOS/dos-native/ram-patch/source.zip',
        'EFI/USOS/dos-native/ram-patch/manifest.json',
        'EFI/USOS/dos-native/ram-patch/INSTALL.BAT',
        'EFI/USOS/dos-native/ram-patch/REPAIR.BAT',
        'EFI/USOS/systemd-bootx64.efi',
        'EFI/USOS/bios-ui.bin',
        'EFI/USOS/licenses/fonts/LICENSE-OFL-1.1.txt',
        'UI/index.html',
        'UI/theme.css',
        'UI/Icons/Systems/windows-11.png'
    )
    foreach ($name in $win7NativeFiles) { $requiredPayloadPaths += 'EFI/USOS/windows-native/' + $name }
    foreach ($requiredPath in $requiredPayloadPaths) {
        if (-not $entries.ContainsKey($requiredPath)) {
            throw "Embedded payload missing required file: $requiredPath"
        }
    }
    foreach ($name in $msDosFiles) {
        if (-not $entries.ContainsKey('EFI/USOS/dos-native/msdos/' + $name)) {
            throw "Embedded payload missing MS-DOS runtime file: $name"
        }
    }

    $usbFiles = Get-ChildItem -LiteralPath $usbRoot -Recurse -File
    $buildInfoHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $buildInfoPath).Hash
    $buildInfoStream = $entries['EFI/USOS/build-info.ini'].Open()
    try {
        $payloadBuildInfoHashBytes = $sha256.ComputeHash($buildInfoStream)
    } finally {
        $buildInfoStream.Dispose()
    }
    $payloadBuildInfoHash = ([BitConverter]::ToString($payloadBuildInfoHashBytes)).Replace('-', '')
    if ($buildInfoHash -ne $payloadBuildInfoHash) {
        throw "Embedded build-info.ini differs from generated build info: generated=$buildInfoHash payload=$payloadBuildInfoHash"
    }
    $buildInfoText = Get-Content -LiteralPath $buildInfoPath -Raw
    if ($env:USOS_BUILD_ID -and $buildInfoText -notmatch ('(?m)^id=' + [regex]::Escape($env:USOS_BUILD_ID) + '\r?$')) {
        throw "Generated build-info.ini does not match USOS_BUILD_ID=$($env:USOS_BUILD_ID)"
    }

    $explicitPayloadFiles = @(
        @{ Source = (Join-Path $ProjectRoot 'zig-out\micro-linux\initramfs-usos'); Target = 'EFI/USOS/micro-linux/initramfs-usos' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\legacy-bios\bios-ui.bin'); Target = 'EFI/USOS/bios-ui.bin' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\windows-native\wimboot'); Target = 'EFI/USOS/windows-native/wimboot' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\windows-native\support.cpio'); Target = 'EFI/USOS/windows-native/support.cpio' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\memdisk'); Target = 'EFI/USOS/dos-native/memdisk' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\COPYING'); Target = 'EFI/USOS/dos-native/COPYING' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\source.zip'); Target = 'EFI/USOS/dos-native/source.zip' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\manifest.json'); Target = 'EFI/USOS/dos-native/manifest.json' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\PATCH9X.EXE'); Target = 'EFI/USOS/dos-native/ram-patch/PATCH9X.EXE' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\CWSDPMI.EXE'); Target = 'EFI/USOS/dos-native/ram-patch/CWSDPMI.EXE' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\CWSDPMI.TXT'); Target = 'EFI/USOS/dos-native/ram-patch/CWSDPMI.TXT' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\LICENSE.TXT'); Target = 'EFI/USOS/dos-native/ram-patch/LICENSE.TXT' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\README.TXT'); Target = 'EFI/USOS/dos-native/ram-patch/README.TXT' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\NOTICE.TXT'); Target = 'EFI/USOS/dos-native/ram-patch/NOTICE.TXT' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\source.zip'); Target = 'EFI/USOS/dos-native/ram-patch/source.zip' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\manifest.json'); Target = 'EFI/USOS/dos-native/ram-patch/manifest.json' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\INSTALL.BAT'); Target = 'EFI/USOS/dos-native/ram-patch/INSTALL.BAT' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\dos-native\ram-patch\REPAIR.BAT'); Target = 'EFI/USOS/dos-native/ram-patch/REPAIR.BAT' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\micro-linux\vmlinuz-virt'); Target = 'EFI/USOS/micro-linux/vmlinuz-virt' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\micro-linux\systemd-bootx64.efi'); Target = 'EFI/USOS/systemd-bootx64.efi' },
        @{ Source = (Join-Path $ProjectRoot 'zig-out\test-assets\ntfs_x64.efi'); Target = 'EFI/USOS/ntfs_x64.efi' }
    )
    foreach ($name in $win7NativeFiles) {
        $explicitPayloadFiles += @{ Source = (Join-Path $ProjectRoot ('zig-out/windows-native/' + $name)); Target = ('EFI/USOS/windows-native/' + $name) }
    }
    foreach ($name in $msDosFiles) {
        $explicitPayloadFiles += @{ Source = (Join-Path $ProjectRoot ('zig-out/dos-native/msdos/' + $name)); Target = ('EFI/USOS/dos-native/msdos/' + $name) }
    }
    foreach ($name in @('BOOT16.BIN','KERNEL.SYS','COMMAND.COM','DZ.EXE','DZ.DOS','FDAUTO.BAT','FDCONFIG.SYS','TOOLS.BAT','README.TXT','REBOOT.COM','DOSZIP.TXT','COPYING','kernel.zip','freecom.zip','doszip.zip','manifest.json')) {
        $explicitPayloadFiles += @{ Source = (Join-Path $ProjectRoot ('zig-out/dos-native/freedos/' + $name)); Target = ('EFI/USOS/dos-native/freedos/' + $name) }
    }
    foreach ($item in $explicitPayloadFiles) {
        if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
            throw "Missing explicit payload source: $($item.Source)"
        }
        if (-not $entries.ContainsKey($item.Target)) {
            throw "Embedded payload missing explicit source: $($item.Target)"
        }
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.Source).Hash
        $stream = $entries[$item.Target].Open()
        try {
            $payloadHashBytes = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
        $payloadHash = ([BitConverter]::ToString($payloadHashBytes)).Replace('-', '')
        if ($sourceHash -ne $payloadHash) {
            throw "Embedded payload differs from explicit source: $($item.Target) source=$sourceHash payload=$payloadHash"
        }
    }

    $strategyBytes = [IO.File]::ReadAllBytes($strategyBMbr)
    if ($strategyBytes.Length -ne 440) {
        throw "Strategy B MBR artifact must be exactly 440 bytes, got $($strategyBytes.Length)"
    }
    $initramfsFile = [IO.File]::OpenRead($microLinuxInitramfs)
    try {
        $gzip = [IO.Compression.GZipStream]::new($initramfsFile, [IO.Compression.CompressionMode]::Decompress)
        try {
            $expanded = [IO.MemoryStream]::new()
            try {
                $gzip.CopyTo($expanded)
                $initramfsBytes = $expanded.ToArray()
            } finally {
                $expanded.Dispose()
            }
        } finally {
            $gzip.Dispose()
        }
    } finally {
        $initramfsFile.Dispose()
    }
    $strategyPathBytes = [Text.Encoding]::ASCII.GetBytes('usr/lib/usos/xp-geometry-fix-mbr-440.bin')
    if (-not (Test-ByteSequence $initramfsBytes $strategyPathBytes)) {
        throw 'micro-Linux initramfs is missing the Strategy B MBR path'
    }
    if (-not (Test-ByteSequence $initramfsBytes $strategyBytes)) {
        throw 'micro-Linux initramfs does not contain the exact Strategy B 440-byte artifact'
    }

    foreach ($source in $usbFiles) {
        $relative = $source.FullName.Substring($usbRoot.Length).TrimStart('\').Replace('\', '/')
        if (-not (Test-StaticEspPath $relative)) {
            continue
        }
        if (-not $entries.ContainsKey($relative)) {
            throw "Embedded payload is stale; missing static ESP file: $relative"
        }

        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash
        $stream = $entries[$relative].Open()
        try {
            $payloadHashBytes = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
        $payloadHash = ([BitConverter]::ToString($payloadHashBytes)).Replace('-', '')
        if ($sourceHash -ne $payloadHash) {
            throw "Embedded payload differs from USB file: $relative source=$sourceHash payload=$payloadHash"
        }
    }
} finally {
    $sha256.Dispose()
    $archive.Dispose()
}

Write-Host "[PASS] BOOTX64.EFI = vendored shim SHA-256=$releaseHash; second stage derives from manual-usb BOOTX64.EFI SHA-256=$manualHash"
Write-Host "[PASS] build-info.ini embedded SHA-256=$buildInfoHash build=$($env:USOS_BUILD_ID)"
Write-Host '[PASS] Embedded payload contains only current static ESP files; DATA images and runtime NTFS discovery stay outside the EXE.'
