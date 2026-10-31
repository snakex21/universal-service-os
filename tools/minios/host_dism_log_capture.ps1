# SPDX-License-Identifier: GPL-3.0-or-later
# Copy a bounded internal DISM log after revalidating the volume. No scratch
# deletion or device operation is performed here.
function Copy-HostDismLog {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,
          [Parameter(Mandatory)][string]$Prefix,[Parameter(Mandatory)][scriptblock]$Guard,
          [Parameter(Mandatory)][scriptblock]$PathGuard)
    $null=& $Guard
    if(-not (Test-Path -LiteralPath $Source -PathType Leaf)) {return $false}
    $null=& $PathGuard $Source
    $src=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if($src.Length -gt 64MB){throw 'DISM log exceeds copy bound'}
        $dst=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes($Prefix);$dst.Write($bytes,0,$bytes.Length)
            $src.CopyTo($dst);$dst.Flush($true)
        } finally {$dst.Dispose()}
    } finally {$src.Dispose()}
    return $true
}
