<#
.SYNOPSIS
Builds the USOS release folder zig-out\release-<major.minor>\ in one command.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\release\make_release.ps1 [-Data L:\] [-WinPEDonor PATH] [-Tag v1.0.0-rc2] [-SkipBuild] [-SkipChecks]

1. build.bat (full release build, payload and installer; unless -SkipBuild);
2. the XP UEFI packages, one per language, from the allowlisted original ISOs
   only (tools/build_xp_uefi_csm_trial.py --release --release-lang pl|en),
   read from -Data (default L:\, the DATA partition; read only);
3. the XP package checks (tools/tests/check_xp_*.py) on each package
   (unless -SkipChecks);
4. the WinPE donor zip and XP package zips (assemble_release.py
   --components-only), then the installer rebuilt with -Tag (the GitHub
   release it downloads them from) and their SHA-256 list compiled in:
   USOS-Installer-VERSION-online.exe, and USOS-Installer-VERSION.exe, the
   full build with the zips appended (cmd/usos-component-bundle);
5. tools/release/assemble_release.py: both installers, those zips, LICENSES,
   THIRD-PARTY-NOTICES, SOURCE-OFFER, sources zip, docs, forbidden-content
   scan, SHA256SUMS; it refuses an installer without the hash list.

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
    [string]$IssuesUrl = '',
    # GitHub release tag the installer downloads its components from
    # (e.g. v1.0.0-rc2); empty means v<VERSION>.
    [string]$Tag = ''
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

# The installer downloads the WinPE and XP zips from its own GitHub release
# and pins their SHA-256: build the zips first, then rebuild the installer
# (same build, same payload) with the release tag and that hash list.
$componentsDir = Join-Path $work 'components'
Step "component zips (WinPE, XP) -> $componentsDir"
Run 'assemble components' { python.exe (Join-Path $root 'tools\release\assemble_release.py') --components-only --out $componentsDir --winpe $WinPEDonor @xpArgs }
$pins = ([IO.File]::ReadAllText((Join-Path $componentsDir 'component-sha256.txt'))).Trim()
if ($Tag -eq '') { $Tag = "v$version" }
if ($Tag -notmatch '^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') { throw "-Tag must look like v1.0.0 or v1.0.0-rc2, got '$Tag'" }
if (-not $Tag.StartsWith("v$version")) { throw "-Tag $Tag does not match VERSION $version" }
Step "installer for release $Tag with the component hash list"
$buildInfoPackage = 'github.com/snakex21/universal-service-os/installer/internal/buildinfo'
$sourceSha = (($info | Select-String '^source_sha256=(.+)$').Matches.Groups[1].Value)
$buildEpoch = (($info | Select-String '^epoch=(.+)$').Matches.Groups[1].Value)
$ldflags = "-H=windowsgui -X $buildInfoPackage.ID=$buildId -X $buildInfoPackage.EpochText=$buildEpoch -X $buildInfoPackage.SourceSHA256=$sourceSha -X $buildInfoPackage.Version=$version -X $buildInfoPackage.ReleaseTag=$Tag -X $buildInfoPackage.ComponentSHA256=$pins"
Push-Location -LiteralPath (Join-Path $root 'installer')
try {
    Run 'go build installer' { go.exe build -trimpath -ldflags $ldflags -o 'USOS Installer.exe' ./cmd/usos-installer }
    # Full (all-in-one) installer: the same executable with the component
    # zips appended as a verified overlay; the plain one ships as -online.
    $allInOne = Join-Path $work 'USOS-Installer-full.exe'
    $componentZips = @(Get-ChildItem -LiteralPath $componentsDir -Filter '*.zip' | Sort-Object Name | ForEach-Object { $_.FullName })
    Run 'usos-component-bundle' { go.exe run ./cmd/usos-component-bundle -exe 'USOS Installer.exe' -out $allInOne @componentZips }
} finally {
    Pop-Location
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
Run 'assemble_release' { python.exe (Join-Path $root 'tools\release\assemble_release.py') --out $out --installer $allInOne --installer-online (Join-Path $root 'installer\USOS Installer.exe') --components $componentsDir @kitArgs }
Step "PASS: $out"
