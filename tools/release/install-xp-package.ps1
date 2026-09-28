<#
.SYNOPSIS
Installs a USOS Windows XP UEFI package (EFI\USOS-XP) onto a USOS stick.

.DESCRIPTION
Shipped inside USOS-<version>-XP-package-PL.zip / -EN.zip. Run it from the
extracted folder in PowerShell as administrator, with the USOS stick plugged
in:

    powershell -ExecutionPolicy Bypass -File .\install-xp-package.ps1

It finds the stick's USOS_ESP partition (or uses -EspRoot), checks that the
stick runs the USOS build this package was made for (same micro-Linux), then
copies EFI\USOS-XP\initramfs-xp, vmlinuz.efi and manifest.json and verifies
each copy by SHA-256. It changes nothing else: no formatting, no other
files. When the ESP has no drive letter, a temporary one is assigned and
removed again at the end.

.PARAMETER EspRoot
Root of the USOS_ESP partition (for example "J:\"). Needed only when more
than one USOS stick is plugged in.

.PARAMETER Force
Install even when the stick runs another USOS build (not recommended: the
XP preparation may then not match the menu).
#>
param(
    [string]$EspRoot = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$package = Join-Path $PSScriptRoot 'EFI\USOS-XP'
$names = @('initramfs-xp', 'vmlinuz.efi', 'manifest.json')

function Hash([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

foreach ($name in $names) {
    if (-not (Test-Path -LiteralPath (Join-Path $package $name) -PathType Leaf)) {
        throw "Package file missing: EFI\USOS-XP\$name (extract the whole zip first)"
    }
}
$manifest = Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
foreach ($name in @('initramfs-xp', 'vmlinuz.efi')) {
    if ((Hash (Join-Path $package $name)) -ne $manifest.sha256.$name) {
        throw "Package file damaged: EFI\USOS-XP\$name does not match manifest.json (download the zip again)"
    }
}

$temporaryLetter = $null
$partition = $null
try {
    if ($EspRoot -eq '') {
        $volumes = @(Get-Volume | Where-Object { $_.FileSystemLabel -eq 'USOS_ESP' })
        if ($volumes.Count -eq 0) { throw 'No USOS stick found (no partition labelled USOS_ESP). Plug the stick in, or pass -EspRoot.' }
        if ($volumes.Count -gt 1) { throw 'More than one USOS_ESP partition found. Pass -EspRoot, for example -EspRoot J:\' }
        $volume = $volumes[0]
        if ($volume.DriveLetter) {
            $EspRoot = "$($volume.DriveLetter):\"
        } else {
            $partition = Get-Partition | Where-Object { $_.AccessPaths -contains $volume.Path } | Select-Object -First 1
            if ($null -eq $partition) { throw 'The USOS_ESP partition has no drive letter and could not be found. Pass -EspRoot.' }
            Add-PartitionAccessPath -InputObject $partition -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber
            $temporaryLetter = $partition.DriveLetter
            if (-not $temporaryLetter) { throw 'Could not assign a temporary drive letter to USOS_ESP (run as administrator).' }
            $EspRoot = "${temporaryLetter}:\"
            Write-Output "Temporary drive letter ${temporaryLetter}: for USOS_ESP"
        }
    }
    $EspRoot = [IO.Path]::GetFullPath($EspRoot)
    $buildInfo = Join-Path $EspRoot 'EFI\USOS\build-info.ini'
    $base = Join-Path $EspRoot 'EFI\USOS\micro-linux\initramfs-usos'
    if (-not (Test-Path -LiteralPath $buildInfo -PathType Leaf) -or -not (Test-Path -LiteralPath $base -PathType Leaf)) {
        throw "$EspRoot is not a USOS ESP (EFI\USOS\build-info.ini or the micro-Linux is missing)."
    }
    $stickBuild = (Select-String -LiteralPath $buildInfo -Pattern '^id=(.+)$' | Select-Object -First 1).Matches.Groups[1].Value
    if ((Hash $base) -ne $manifest.base_initramfs_sha256) {
        $message = "The stick runs USOS build $stickBuild, but this XP package was made for another build. Update the stick with the installer of the same release first."
        if (-not $Force) { throw $message }
        Write-Warning "$message Installing anyway (-Force)."
    }

    $target = Join-Path $EspRoot 'EFI\USOS-XP'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    $need = 0
    foreach ($name in $names) { $need += (Get-Item -LiteralPath (Join-Path $package $name)).Length }
    $drive = Get-PSDrive -Name $EspRoot.Substring(0, 1) -ErrorAction SilentlyContinue
    $existing = 0
    foreach ($name in $names) {
        $old = Join-Path $target $name
        if (Test-Path -LiteralPath $old) { $existing += (Get-Item -LiteralPath $old).Length }
    }
    if ($drive -and ($drive.Free + $existing) -lt ($need + 1MB)) {
        throw ("Not enough space on USOS_ESP: need {0:N0} MB, free {1:N0} MB." -f ($need / 1MB), (($drive.Free + $existing) / 1MB))
    }

    Write-Output "Installing the XP package ($($manifest.driver_sources[0].name)) to $target"
    foreach ($name in $names) {
        $source = Join-Path $package $name
        $destination = Join-Path $target $name
        $partial = "$destination.new"
        Copy-Item -LiteralPath $source -Destination $partial -Force
        if ((Hash $partial) -ne (Hash $source)) { Remove-Item -LiteralPath $partial -Force; throw "Copy of $name failed verification." }
        Move-Item -LiteralPath $partial -Destination $destination -Force
    }
    foreach ($name in $names) {
        if ((Hash (Join-Path $target $name)) -ne (Hash (Join-Path $package $name))) { throw "Readback of $name failed." }
    }
    try { Write-VolumeCache -DriveLetter $EspRoot.Substring(0, 1) -ErrorAction Stop } catch { }
    Write-Output "PASS: XP package installed and verified on $EspRoot (stick build $stickBuild)."
    Write-Output 'Copy the matching XP ISO to USOS_DATA: Systems\Windows\Windows XP\Images.'
} finally {
    if ($temporaryLetter -and $partition) {
        Remove-PartitionAccessPath -InputObject $partition -AccessPath "${temporaryLetter}:\" -ErrorAction SilentlyContinue
        Write-Output "Temporary drive letter ${temporaryLetter}: removed."
    }
}
