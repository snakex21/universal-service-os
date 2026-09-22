# Read-only: list non-empty files on an attached XP volume whose content is all
# zeros (writes lost before reaching the disk, e.g. after a forced power-off).
# Exit 0 = none found, 2 = zero-filled files found. Never writes to the volume.
param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter)
$ErrorActionPreference = 'Stop'
$root = $DriveLetter.ToUpperInvariant() + ':\'
if (!(Test-Path -LiteralPath (Join-Path $root 'WINDOWS'))) { throw "No WINDOWS directory on $root" }
$skip = @('pagefile.sys', 'hiberfil.sys') | ForEach-Object { Join-Path $root $_ }
$buffer = New-Object byte[] 65536
$hits = New-Object System.Collections.Generic.List[object]
$scanned = 0; $errors = 0
Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Length -eq 0 -or $skip -contains $_.FullName) { return }
    $scanned++
    try {
        $stream = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $allZero = $true
            while ($allZero -and ($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                for ($i = 0; $i -lt $read; $i++) { if ($buffer[$i] -ne 0) { $allZero = $false; break } }
            }
        } finally { $stream.Close() }
        if ($allZero) { $hits.Add([pscustomobject]@{ Path = $_.FullName; Size = $_.Length; ModifiedUtc = $_.LastWriteTimeUtc.ToString('s') }) }
    } catch { $errors++ }
}
"Scanned $scanned non-empty files on $root; read errors: $errors; zero-filled: $($hits.Count)"
if ($hits.Count) { $hits | Format-Table -AutoSize | Out-String -Width 300; exit 2 }
exit 0
