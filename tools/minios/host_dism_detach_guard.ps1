# SPDX-License-Identifier: GPL-3.0-or-later
# Detach only the exact pinned image, including when no disk number was found.
function Dismount-HostDismPinnedImage {
    param([Parameter(Mandatory)]$FilePin,[Parameter(Mandatory)][string]$ImagePath)
    $FilePin.AssertUnchanged()
    $exact=@(Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop)
    if($exact.Count -ne 1 -or -not $exact[0].Attached -or
       -not [string]::Equals([IO.Path]::GetFullPath([string]$exact[0].ImagePath),[IO.Path]::GetFullPath($ImagePath),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Mounted image path no longer matches'
    }
    $FilePin.AssertUnchanged()
    Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null
}
