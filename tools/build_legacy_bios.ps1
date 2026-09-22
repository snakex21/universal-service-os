param(
    [string]$OutputDirectory = 'zig-out/legacy-bios',
    [ValidateSet('direct-ntfs','esp-fallback')][string]$CatalogMode = 'direct-ntfs',
    [switch]$XpMenuAutoTest,
    [switch]$XpMenuAutoNone
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$zig = Full 'tools/zig/zig.exe'
$out = Full $OutputDirectory
# Test runners must never overwrite the release artifacts consumed by the installer.
$productionOut = Full 'zig-out/legacy-bios'
if (($XpMenuAutoTest -or $XpMenuAutoNone) -and $out.TrimEnd('\','/') -ieq $productionOut.TrimEnd('\','/')) {
    throw 'XP menu autotest requires a separate -OutputDirectory; refusing to overwrite production Legacy Core'
}
if ($XpMenuAutoNone -and -not $XpMenuAutoTest) {
    throw 'XpMenuAutoNone requires XpMenuAutoTest'
}
$sourceRoot = Full 'src/platform/bios'
$coreSlotBytes = 512 * 512
$bootstrapReservedBytes = 32 * 512
$coreSlotPacker = Full 'tools/pack_legacy_core_slot.py'
$python = (Get-Command python.exe -ErrorAction Stop).Source

if (-not (Test-Path -LiteralPath $zig -PathType Leaf)) { throw "Missing Zig toolchain: $zig" }
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Build-LinkedText([string]$Name, [string]$Source, [string]$LinkerScript, [string]$Entry) {
    $elf = Join-Path $out "$Name.elf"
    $binary = Join-Path $out "$Name.raw.bin"
    $script = Join-Path $sourceRoot $LinkerScript
    & $zig cc -target x86-freestanding-none -nostdlib -nodefaultlibs `
        "-Wl,-T,$script" "-Wl,--entry=$Entry" `
        (Join-Path $sourceRoot $Source) -o $elf
    if ($LASTEXITCODE -ne 0) { throw "Assembly/link failed for $Source with exit code $LASTEXITCODE" }
    & $zig objcopy -O binary -j .text $elf $binary
    if ($LASTEXITCODE -ne 0) { throw "objcopy failed for $Source with exit code $LASTEXITCODE" }
    return $binary
}

function Build-CorePayload {
    $coreMain = Full 'src/platform/bios/core_main.zig'
    $storageRoot = Full 'src/storage/root.zig'
    $catalogRoot = Full 'src/catalog_module.zig'
    $graphicsRoot = Full 'src/legacy_graphics_module.zig'
    $menuPolicyRoot = Full 'src/gui/menu_policy.zig'
    $legacyIconsGenerator = Full 'tools/generate_legacy_icons.py'
    $legacyIcons = Join-Path $out 'legacy_icons.zig'
    $catalogModeModule = Join-Path $out 'legacy_catalog_mode.zig'
    $testModeModule = Join-Path $out 'legacy_test_mode.zig'
    $legacyIconSource = Full 'media/UI/Icons/Systems'
    $coreObject = Join-Path $out 'core-main.o'
    $coreAssembly = Join-Path $out 'core-main.audit.s'
    $coreElf = Join-Path $out 'core.elf'
    $coreBinary = Join-Path $out 'core.raw.bin'
    $coreScript = Join-Path $sourceRoot 'core.ld'
    $coreAsm = Join-Path $sourceRoot 'core.S'

    & $python $legacyIconsGenerator --input $legacyIconSource --output $legacyIcons | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Legacy icon generation failed with exit code $LASTEXITCODE" }
    $forceEsp = if ($CatalogMode -eq 'esp-fallback') { 'true' } else { 'false' }
    [IO.File]::WriteAllText($catalogModeModule, "pub const force_esp_catalog = $forceEsp;`n", [Text.UTF8Encoding]::new($false))
    $xpMenuAuto = if ($XpMenuAutoTest) { 'true' } else { 'false' }
    $xpMenuAutoNone = if ($XpMenuAutoNone) { 'true' } else { 'false' }
    [IO.File]::WriteAllText($testModeModule, "pub const xp_menu_auto = $xpMenuAuto;`npub const xp_menu_auto_none = $xpMenuAutoNone;`n", [Text.UTF8Encoding]::new($false))

    & $zig build-obj -target x86-freestanding-none -mcpu=i386 -O ReleaseSmall --dep storage --dep catalog --dep menu_policy --dep graphics --dep legacy_icons --dep catalog_mode --dep test_mode `
        "-Mroot=$coreMain" "-Mstorage=$storageRoot" "-Mcatalog=$catalogRoot" "-Mmenu_policy=$menuPolicyRoot" "-Mgraphics=$graphicsRoot" "-Mlegacy_icons=$legacyIcons" "-Mcatalog_mode=$catalogModeModule" "-Mtest_mode=$testModeModule" "-femit-bin=$coreObject" "-femit-asm=$coreAssembly"
    if ($LASTEXITCODE -ne 0) { throw "Legacy Core Zig compile failed with exit code $LASTEXITCODE" }

    $generatedAssembly = [IO.File]::ReadAllText($coreAssembly)
    $handwrittenAssembly = [IO.File]::ReadAllText($coreAsm)
    $sseMatches = [regex]::Matches($generatedAssembly + "`n" + $handwrittenAssembly, '(?im)\b(?:xmm|ymm|zmm)[0-9]+\b').Count
    if ($sseMatches -ne 0) {
        throw "Legacy Core ISA audit failed: found $sseMatches SSE/AVX register references; Core must remain i386 baseline"
    }
    Write-Host "[PASS] Legacy Core ISA audit: SSE/AVX register references=0"

    & $zig cc -target x86-freestanding-none -mcpu=i386 -nostdlib -nodefaultlibs `
        "-Wl,-T,$coreScript" "-Wl,--entry=core_start" `
        $coreAsm $coreObject -o $coreElf
    if ($LASTEXITCODE -ne 0) { throw "Legacy Core link failed with exit code $LASTEXITCODE" }

    & $zig objcopy -O binary $coreElf $coreBinary
    if ($LASTEXITCODE -ne 0) { throw "Legacy Core objcopy failed with exit code $LASTEXITCODE" }
    return $coreBinary
}

$stage1Raw = Build-LinkedText 'stage1' 'stage1.S' 'boot_sector.ld' 'stage1_start'
$bootstrapRaw = Build-LinkedText 'bootstrap' 'bootstrap.S' 'bootstrap.ld' 'bootstrap_start'
$core = Build-CorePayload
$vbrRaw = Build-LinkedText 'test-vbr' 'test_vbr.S' 'boot_sector.ld' 'test_vbr_start'

$stage1Bytes = [IO.File]::ReadAllBytes($stage1Raw)
if ($stage1Bytes.Length -gt 440) { throw "Stage 1 is $($stage1Bytes.Length) bytes; maximum is 440" }
$stage1Padded = New-Object byte[] 440
[Array]::Copy($stage1Bytes, $stage1Padded, $stage1Bytes.Length)
$stage1Path = Join-Path $out 'stage1.bin'
[IO.File]::WriteAllBytes($stage1Path, $stage1Padded)

$bootstrapBytes = [IO.File]::ReadAllBytes($bootstrapRaw)
if ($bootstrapBytes.Length -gt $bootstrapReservedBytes) {
    throw "Legacy bootstrap is $($bootstrapBytes.Length) bytes; fixed bootstrap window is $bootstrapReservedBytes bytes"
}
$coreBytes = [IO.File]::ReadAllBytes($core)
if ($coreBytes.Length -gt ($coreSlotBytes - $bootstrapReservedBytes)) {
    throw "Legacy Core payload is $($coreBytes.Length) bytes; slot payload maximum is $($coreSlotBytes - $bootstrapReservedBytes) bytes"
}
$coreSlotPath = Join-Path $out 'core-slot.bin'
& $python $coreSlotPacker --bootstrap $bootstrapRaw --core $core --output $coreSlotPath
if ($LASTEXITCODE -ne 0) { throw "Legacy Core slot packing failed with exit code $LASTEXITCODE" }
$coreSlot = [IO.File]::ReadAllBytes($coreSlotPath)
if ($coreSlot.Length -ne $coreSlotBytes) { throw "Legacy Core slot is $($coreSlot.Length) bytes; want $coreSlotBytes" }

$vbrBytes = [IO.File]::ReadAllBytes($vbrRaw)
if ($vbrBytes.Length -gt 510) { throw "Test VBR is $($vbrBytes.Length) bytes; maximum is 510 before signature" }
$vbrSector = New-Object byte[] 512
[Array]::Copy($vbrBytes, $vbrSector, $vbrBytes.Length)
$vbrSector[510] = 0x55
$vbrSector[511] = 0xAA
$vbrPath = Join-Path $out 'test-vbr.bin'
[IO.File]::WriteAllBytes($vbrPath, $vbrSector)

Write-Host "[PASS] Legacy Stage 1: $($stage1Bytes.Length) code bytes, padded to 440"
Write-Host "[PASS] Legacy bootstrap: $($bootstrapBytes.Length) bytes in fixed $bootstrapReservedBytes-byte load window"
Write-Host "[PASS] Legacy Core PM32 payload: $($coreBytes.Length) bytes inside $coreSlotBytes-byte slot"
Write-Host "[PASS] Test VBR: $($vbrBytes.Length) code bytes, sector signature=55AA"
Write-Host "[PASS] Legacy catalog mode: $CatalogMode"
Write-Host "[PASS] Output: $out"
