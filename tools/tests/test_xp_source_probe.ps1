$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sh = 'C:\msys64\usr\bin\sh.exe'
$cygpath = 'C:\msys64\usr\bin\cygpath.exe'
if (-not (Test-Path -LiteralPath $sh -PathType Leaf)) { throw "MSYS2 sh missing: $sh" }
if (-not (Test-Path -LiteralPath $cygpath -PathType Leaf)) { throw "MSYS2 cygpath missing: $cygpath" }
$probe = Join-Path $root 'tools\probe_xp_source.sh'
if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw "XP source probe missing: $probe" }

$out = Join-Path $root 'zig-out\xp-source-probe-tests'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $out | Out-Null

$required = @(
    'DOSNET.INF','SETUPLDR.BIN','NTLDR','NTDETECT.COM','TXTSETUP.SIF',
    'USETUP.EXE','SETUPDD.SY_','NTOSKRNL.EX_','NTKRNLMP.EX_','BOOTVID.DL_'
)

function New-Xp32Fixture([string]$Name, [string[]]$Markers) {
    $dir = Join-Path $out $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'I386') | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $dir 'WIN51') | Out-Null
    foreach ($marker in $Markers) { New-Item -ItemType File -Force -Path (Join-Path $dir $marker) | Out-Null }
    foreach ($file in $required) { New-Item -ItemType File -Force -Path (Join-Path $dir "I386\$file") | Out-Null }
    return $dir
}

function Invoke-Probe([string]$Fixture) {
    $fixtureUnix = (& $cygpath -u $Fixture).Trim()
    $probeUnix = (& $cygpath -u $probe).Trim()
    $oldSourceRoot = $env:SOURCE_ROOT
    $oldPreference = $ErrorActionPreference
    try {
        $env:SOURCE_ROOT = $fixtureUnix
        $ErrorActionPreference = 'Continue'
        $text = (& $sh $probeUnix 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Code=$code; Text=$text }
    } finally {
        $ErrorActionPreference = $oldPreference
        $env:SOURCE_ROOT = $oldSourceRoot
    }
}

$pro = New-Xp32Fixture 'pro-sp2' @('WIN51IP','WIN51IP.SP2')
$r = Invoke-Probe $pro
if ($r.Code -ne 0 -or $r.Text -notmatch 'markers=WIN51IP,WIN51IP\.SP2' -or $r.Text -notmatch 'service_pack_markers=WIN51IP\.SP2') {
    throw "Professional SP2 probe failed:`n$($r.Text)"
}
Write-Host '[PASS] WIN51 + WIN51IP + SP2 accepted'

$homeFixture = New-Xp32Fixture 'home-rtm' @('WIN51IC')
$r = Invoke-Probe $homeFixture
if ($r.Code -ne 0 -or $r.Text -notmatch 'markers=WIN51IC' -or $r.Text -notmatch 'service_pack_markers=RTM') {
    throw "Home RTM probe failed:`n$($r.Text)"
}
Write-Host '[PASS] WIN51 + WIN51IC RTM accepted'

$mce = New-Xp32Fixture 'arbitrary-win51i' @('WIN51IMCE','WIN51IMCE.SP2')
$r = Invoke-Probe $mce
if ($r.Code -ne 0 -or $r.Text -notmatch 'markers=WIN51IMCE,WIN51IMCE\.SP2') {
    throw "arbitrary WIN51I* probe failed:`n$($r.Text)"
}
Write-Host '[PASS] arbitrary WIN51I* edition marker accepted'

$x64 = Join-Path $out 'x64-amd64'
New-Item -ItemType Directory -Force -Path (Join-Path $x64 'AMD64') | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $x64 'WIN51') | Out-Null
$r = Invoke-Probe $x64
if ($r.Code -eq 0 -or $r.Text -notmatch 'XP x64/AMD64 source is not supported') {
    throw "XP x64 rejection failed:`n$($r.Text)"
}
Write-Host '[PASS] AMD64-without-I386 rejected with explicit XP x64 message'

$noEdition = New-Xp32Fixture 'missing-win51i' @()
$r = Invoke-Probe $noEdition
if ($r.Code -eq 0 -or $r.Text -notmatch 'missing edition marker matching WIN51I\*') {
    throw "missing WIN51I* rejection failed:`n$($r.Text)"
}
Write-Host '[PASS] missing WIN51I* rejected'

Write-Host '[PASS] XP source marker probe matrix complete'
