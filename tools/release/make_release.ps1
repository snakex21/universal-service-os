<#
.SYNOPSIS
Builds the USOS release folder zig-out\release-<major.minor>\ in one command.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\make_release.ps1 [-Data L:\] [-WinPEDonor PATH] [-SkipBuild] [-SkipChecks]

1. build.bat (full release build, payload and installer; unless -SkipBuild);
2. the XP UEFI packages, one per language, from the allowlisted original ISOs
   only (tools/build_xp_uefi_csm_trial.py --release --release-lang pl|en),
   read from -Data (default L:\, the DATA partition; read only);
3. the XP package checks (tools/tests/check_xp_*.py) on each package
   (unless -SkipChecks);
4. tools/release/assemble_release.py: installer, WinPE donor zip, XP package
   zips, LICENSES, THIRD-PARTY-NOTICES, SOURCE-OFFER, sources zip, docs,
   forbidden-content scan, SHA256SUMS.

Nothing is written to a USB stick. Windows ISOs are only read (to derive the
XP driver bundles) and never copied into the release.
#>
param(
    [string]$Data = 'L:\',
    [string]$WinPEDonor = '',
    [switch]$SkipBuild,
    [switch]$SkipChecks,
    # Issue tracker named in SOURCE-OFFER.txt (the public repository, filled in
    # at publish time; empty keeps the placeholder).
    [string]$IssuesUrl = ''
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Set-Location -LiteralPath $root

function Step([string]$Text) { Write-Host "[RELEASE] $Text" -ForegroundColor Cyan }
function Run([string]$Label, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
}

$version = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
if ($version -notmatch '^(\d+)\.(\d+)\.\d+$') { throw "VERSION must be MAJOR.MINOR.PATCH, got '$version'" }
$out = Join-Path $root ("zig-out\release-{0}.{1}" -f $Matches[1], $Matches[2])
$work = Join-Path $root 'zig-out\release-work'

if (-not $SkipBuild) {
    Step "build.bat (version $version)"
    Run 'build.bat' { cmd.exe /c "`"$root\build.bat`"" }
}
$env:USOS_BUILD_ID = ((Get-Content -LiteralPath (Join-Path $root 'build\generated\build-info.ini') | Select-String '^id=(.+)$').Matches.Groups[1].Value)
Run 'verify_release_consistency' { powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\verify_release_consistency.ps1') }

$info = Get-Content -LiteralPath (Join-Path $root 'build\generated\build-info.ini')
$buildId = (($info | Select-String '^id=(.+)$').Matches.Groups[1].Value)
$builtVersion = (($info | Select-String '^version=(.+)$').Matches.Groups[1].Value)
if ($builtVersion -ne $version) { throw "The last build is version '$builtVersion', VERSION says '$version': run without -SkipBuild." }
Step "build $buildId, version $version"

$xpImages = Join-Path $Data 'Systems\Windows\Windows XP\Images'
if (-not (Test-Path -LiteralPath $xpImages -PathType Container)) { throw "No XP images folder on DATA: $xpImages (pass -Data)" }
if ($WinPEDonor -eq '') { $WinPEDonor = Join-Path $Data 'Programs\USOS\WinPE\PE10_x64_19041_USOS.iso' }
if (-not (Test-Path -LiteralPath $WinPEDonor -PathType Leaf)) { throw "WinPE donor not found: $WinPEDonor (pass -WinPEDonor)" }

$xpSources = @{
    pl = 'pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso'
    en = 'en_windows_xp_professional_with_service_pack_3_x86_cd_x14-80428.iso'
}
$xpArgs = @()
foreach ($lang in @('pl', 'en')) {
    $package = Join-Path $work "xp-$lang"
    Step "XP package $lang -> $package"
    if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Recurse -Force }
    Run "XP package $lang" { python.exe (Join-Path $root 'tools\build_xp_uefi_csm_trial.py') --release --release-lang $lang --data $Data --out $package }
    if (-not $SkipChecks) {
        $env:USOS_XP_PACKAGE_DIR = $package
        try {
            # check_xp_pae extracts the SP3 kernel files the import check reads.
            $sourceIso = Join-Path $xpImages $xpSources[$lang]
            Step "  check_xp_pae.py ($lang)"
            Run 'check_xp_pae.py' { python.exe (Join-Path $root 'tools\tests\check_xp_pae.py') --images $xpImages }
            Step "  check_xp_driver_imports.py ($lang)"
            Run 'check_xp_driver_imports.py' { python.exe (Join-Path $root 'tools\tests\check_xp_driver_imports.py') --source-iso $sourceIso }
            foreach ($check in @('check_xp_driver_integration.py', 'check_xp_menu_overlay.py')) {
                Step "  $check ($lang)"
                Run $check { python.exe (Join-Path $root "tools\tests\$check") }
            }
        } finally {
            Remove-Item Env:\USOS_XP_PACKAGE_DIR -ErrorAction SilentlyContinue
        }
    }
    $xpArgs += @('--xp', "$lang=$package")
}

Step "build kit (pinned downloads: tools\release\buildkit.lock.json)"
Run 'fetch_buildkit_inputs' { python.exe (Join-Path $root 'tools\release\fetch_buildkit_inputs.py') }
$epoch = (($info | Select-String '^epoch=(.+)$').Matches.Groups[1].Value)
$kitDir = Join-Path $work 'buildkit'
if (Test-Path -LiteralPath $kitDir) { Remove-Item -LiteralPath $kitDir -Recurse -Force }
Run 'make_buildkit' { python.exe (Join-Path $root 'tools\release\make_buildkit.py') --out (Join-Path $kitDir "USOS-$version-buildkit.zip") --version $version --build-id $buildId --epoch $epoch }
$kitArgs = @()
foreach ($part in Get-ChildItem -LiteralPath $kitDir -File) { $kitArgs += @('--buildkit', $part.FullName) }

if ($IssuesUrl -ne '') { $env:USOS_ISSUES_URL = $IssuesUrl }
Step "assemble $out"
Run 'assemble_release' { python.exe (Join-Path $root 'tools\release\assemble_release.py') --out $out --installer (Join-Path $root 'installer\USOS Installer.exe') --winpe $WinPEDonor @xpArgs @kitArgs }
Step "PASS: $out"
