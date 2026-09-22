$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sh = 'C:\msys64\usr\bin\sh.exe'
$cygpath = 'C:\msys64\usr\bin\cygpath.exe'
if (-not (Test-Path -LiteralPath $sh -PathType Leaf)) { throw "MSYS2 sh missing: $sh" }
if (-not (Test-Path -LiteralPath $cygpath -PathType Leaf)) { throw "MSYS2 cygpath missing: $cygpath" }

$out = Join-Path $root 'zig-out\xp-unattended-policy-tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$safe = Join-Path $out 'safe.sif'
$unsafe = Join-Path $out 'unsafe.sif'
$commentOnly = Join-Path $out 'comment-only.sif'

[IO.File]::WriteAllText($safe, @"
[Data]
AutoPartition = 0
[Unattended]
Repartition = No
[UserData]
ProductKey = "USER-CONTROLLED-TEST-VALUE"
"@, [Text.Encoding]::ASCII)

[IO.File]::WriteAllText($unsafe, @"
[Data]
AutoPartition = "1"
[Unattended]
Repartition = YES
[UserData]
ProductKey = "DO-NOT-LOG-THIS-VALUE"
"@, [Text.Encoding]::ASCII)

[IO.File]::WriteAllText($commentOnly, @"
[Data]
; AutoPartition=1
[Unattended]
; Repartition=Yes
"@, [Text.Encoding]::ASCII)

$policyUnix = (& $cygpath -u (Join-Path $root 'tools\xp_unattended_policy.sh')).Trim()
function Invoke-Risks([string]$Path) {
    $fileUnix = (& $cygpath -u $Path).Trim()
    $command = ". '$policyUnix'; usos_xp_sif_risks '$fileUnix'"
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = (& $sh -lc $command 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    [pscustomobject]@{ Code=$code; Text=$text }
}

$r = Invoke-Risks $safe
if ($r.Code -ne 0 -or $r.Text) { throw "safe WINNT.SIF was flagged:`n$($r.Text)" }
Write-Host '[PASS] safe WINNT.SIF keeps manual partition selection'

$r = Invoke-Risks $commentOnly
if ($r.Code -ne 0 -or $r.Text) { throw "comment-only directives were flagged:`n$($r.Text)" }
Write-Host '[PASS] commented partition directives are ignored'

$r = Invoke-Risks $unsafe
if ($r.Code -ne 0) { throw "unsafe WINNT.SIF scanner failed: $($r.Code)" }
if (-not $r.Text.Contains('AutoPartition=1') -or -not $r.Text.Contains('Repartition=Yes')) {
    throw "unsafe WINNT.SIF risks incomplete:`n$($r.Text)"
}
if ($r.Text -match 'DO-NOT-LOG-THIS-VALUE' -or $r.Text -match 'ProductKey') {
    throw "unsafe scanner leaked user ProductKey data:`n$($r.Text)"
}
Write-Host '[PASS] AutoPartition=1 and Repartition=Yes detected without logging ProductKey'
Write-Host '[PASS] XP unattended policy matrix complete'
