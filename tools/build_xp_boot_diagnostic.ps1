param(
    [string]$OutputDirectory = 'zig-out/xp-boot-diagnostic'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }

$zig = Full 'tools/zig/zig.exe'
$src = Full 'src/platform/bios/xp'
$out = Full $OutputDirectory
New-Item -ItemType Directory -Force -Path $out | Out-Null

# Refresh the Microsoft NT52 control fragments from the host bootsect.exe first.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Full 'tools/build_xp_bootstrap.ps1')
if ($LASTEXITCODE -ne 0) { throw "XP NT52 control bootstrap build failed: $LASTEXITCODE" }

function Build-Raw([string]$Name,[string]$Source,[string]$Linker,[string]$Entry) {
    $elf = Join-Path $out "$Name.elf"
    $raw = Join-Path $out "$Name.raw.bin"
    & $zig cc -target x86-freestanding-none -mcpu=i386 -nostdlib -nodefaultlibs `
        "-Wl,-T,$((Join-Path $src $Linker))" "-Wl,--entry=$Entry" `
        (Join-Path $src $Source) -o $elf
    if ($LASTEXITCODE -ne 0) { throw "XP boot diagnostic assembly/link failed: $Source ($LASTEXITCODE)" }
    & $zig objcopy -O binary -j .text $elf $raw
    if ($LASTEXITCODE -ne 0) { throw "XP boot diagnostic objcopy failed: $Source ($LASTEXITCODE)" }
    return $raw
}

$mbrRaw = Build-Raw 'diag-mbr' 'xp_diag_mbr.S' 'xp_diag_mbr.ld' 'xp_diag_mbr_start'
$preludeRaw = Build-Raw 'diag-prelude' 'xp_diag_prelude.S' 'xp_diag_prelude.ld' 'xp_diag_prelude_start'
$mismatchPreludeRaw = Build-Raw 'diag-prelude-mismatch' 'xp_diag_prelude_mismatch.S' 'xp_diag_prelude.ld' 'xp_diag_prelude_start'
$externalMismatchPreludeRaw = Build-Raw 'diag-prelude-external-mismatch' 'xp_diag_prelude_external_mismatch.S' 'xp_diag_prelude.ld' 'xp_diag_prelude_start'
$int13ShimRaw = Build-Raw 'diag-int13-shim' 'xp_diag_int13_shim.S' 'xp_diag_int13_shim.ld' 'xp_diag_int13_shim_install'
$vbrHelperRaw = Build-Raw 'diag-vbr-helper' 'xp_diag_vbr.S' 'xp_diag_vbr.ld' 'xp_diag_vbr_helper'
$stageHelperRaw = Build-Raw 'diag-stage2-helper' 'xp_diag_stage2.S' 'xp_diag_stage2.ld' 'xp_diag_stage2_dispatch'
$stageRegsHelperRaw = Build-Raw 'diag-stage2-regs-helper' 'xp_diag_stage2_regs.S' 'xp_diag_stage2.ld' 'xp_diag_stage2_dispatch'
$runtimeRaw = Build-Raw 'diag-runtime' 'xp_diag_runtime.S' 'xp_diag_runtime.ld' 'xp_diag_runtime_start'

$mbr = [IO.File]::ReadAllBytes($mbrRaw)
if ($mbr.Length -gt 440) { throw "diagnostic MBR code is $($mbr.Length) bytes; max is 440" }
$mbrPadded = New-Object byte[] 440
[Array]::Copy($mbr,$mbrPadded,$mbr.Length)
$mbrPath = Join-Path $out 'diag-mbr-440.bin'
[IO.File]::WriteAllBytes($mbrPath,$mbrPadded)

$prelude = [IO.File]::ReadAllBytes($preludeRaw)
$preludeBytes = 8 * 512
$preludeCoreBudget = 6 * 512
if ($prelude.Length -gt $preludeCoreBudget) { throw "diagnostic prelude core is $($prelude.Length) bytes; LBA1..6 budget is $preludeCoreBudget (LBA7=original MBR, LBA8=runtime)" }
$preludePadded = New-Object byte[] $preludeBytes
[Array]::Copy($prelude,$preludePadded,$prelude.Length)
$preludePath = Join-Path $out 'diag-prelude-lba1-8.bin'
[IO.File]::WriteAllBytes($preludePath,$preludePadded)

$mismatchPrelude = [IO.File]::ReadAllBytes($mismatchPreludeRaw)
if ($mismatchPrelude.Length -gt $preludeBytes) { throw "diagnostic mismatch prelude is $($mismatchPrelude.Length) bytes; LBA1..8 budget is $preludeBytes" }
$mismatchPreludePadded = New-Object byte[] $preludeBytes
[Array]::Copy($mismatchPrelude,$mismatchPreludePadded,$mismatchPrelude.Length)
$mismatchPreludePath = Join-Path $out 'diag-prelude-mismatch-lba1-8.bin'
[IO.File]::WriteAllBytes($mismatchPreludePath,$mismatchPreludePadded)

$externalMismatchPrelude = [IO.File]::ReadAllBytes($externalMismatchPreludeRaw)
if ($externalMismatchPrelude.Length -gt $preludeBytes) { throw "diagnostic external-mismatch prelude is $($externalMismatchPrelude.Length) bytes; LBA1..8 budget is $preludeBytes" }
$externalMismatchPreludePadded = New-Object byte[] $preludeBytes
[Array]::Copy($externalMismatchPrelude,$externalMismatchPreludePadded,$externalMismatchPrelude.Length)
$externalMismatchPreludePath = Join-Path $out 'diag-prelude-external-mismatch-lba1-8.bin'
[IO.File]::WriteAllBytes($externalMismatchPreludePath,$externalMismatchPreludePadded)

$int13Shim = [IO.File]::ReadAllBytes($int13ShimRaw)
if ($int13Shim.Length -gt 512) { throw "diagnostic INT13 shim is $($int13Shim.Length) bytes; LBA9 budget is 512" }
$int13ShimPadded = New-Object byte[] 512
[Array]::Copy($int13Shim,$int13ShimPadded,$int13Shim.Length)
$int13ShimPath = Join-Path $out 'diag-int13-shim-512.bin'
[IO.File]::WriteAllBytes($int13ShimPath,$int13ShimPadded)

$vbrHelper = [IO.File]::ReadAllBytes($vbrHelperRaw)
$vbrHelperBudget = 0x7DF9 - 0x7D7B
if ($vbrHelper.Length -gt $vbrHelperBudget) { throw "NT52 VBR helper is $($vbrHelper.Length) bytes; injection budget is $vbrHelperBudget" }
$vbrHelperPath = Join-Path $out 'diag-vbr-helper.bin'
[IO.File]::WriteAllBytes($vbrHelperPath,$vbrHelper)

$stageHelper = [IO.File]::ReadAllBytes($stageHelperRaw)
$stageHelperBudget = 0x1FE - 0x148
if ($stageHelper.Length -gt $stageHelperBudget) { throw "NT52 stage2 helper is $($stageHelper.Length) bytes; zero-tail injection budget is $stageHelperBudget" }
$stageHelperPath = Join-Path $out 'diag-stage2-helper.bin'
[IO.File]::WriteAllBytes($stageHelperPath,$stageHelper)

$stageRegsHelper = [IO.File]::ReadAllBytes($stageRegsHelperRaw)
if ($stageRegsHelper.Length -gt $stageHelperBudget) { throw "NT52 stage2 register-capture helper is $($stageRegsHelper.Length) bytes; zero-tail injection budget is $stageHelperBudget" }
$stageRegsHelperPath = Join-Path $out 'diag-stage2-regs-helper.bin'
[IO.File]::WriteAllBytes($stageRegsHelperPath,$stageRegsHelper)

$runtime = [IO.File]::ReadAllBytes($runtimeRaw)
$runtimeBudget = 512
if ($runtime.Length -gt $runtimeBudget) { throw "diagnostic runtime is $($runtime.Length) bytes; LBA8 budget is $runtimeBudget" }
$runtimePadded = New-Object byte[] $runtimeBudget
[Array]::Copy($runtime,$runtimePadded,$runtime.Length)
$runtimePath = Join-Path $out 'diag-runtime-512.bin'
[IO.File]::WriteAllBytes($runtimePath,$runtimePadded)

$nt52Vbr = Full 'zig-out/xp-bios/xp-nt52-vbr-tail.bin'
$nt52Stage2 = Full 'zig-out/xp-bios/xp-nt52-stage2.bin'
function Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash }

Write-Host "[PASS] XP boot diagnostic MBR: $($mbr.Length)/440 bytes SHA256=$(Sha $mbrPath)"
Write-Host "[PASS] XP boot diagnostic prelude: $($prelude.Length)/$preludeBytes bytes LBA=1..8 SHA256=$(Sha $preludePath)"
Write-Host "[PASS] XP boot mismatch prelude: $($mismatchPrelude.Length)/$preludeBytes bytes INT13 shim=240/63 SHA256=$(Sha $mismatchPreludePath)"
Write-Host "[PASS] XP boot external-mismatch prelude: $($externalMismatchPrelude.Length)/$preludeBytes bytes shim=LBA9->0000:1200 SHA256=$(Sha $externalMismatchPreludePath)"
Write-Host "[PASS] XP boot persistent INT13 shim: $($int13Shim.Length)/512 bytes @0000:1200 SHA256=$(Sha $int13ShimPath)"
Write-Host "[PASS] NT52 VBR instrumentation helper: $($vbrHelper.Length)/$vbrHelperBudget bytes @7D7B SHA256=$(Sha $vbrHelperPath)"
Write-Host "[PASS] NT52 stage2 instrumentation helper: $($stageHelper.Length)/$stageHelperBudget bytes @8148 SHA256=$(Sha $stageHelperPath)"
Write-Host "[PASS] NT52 stage2 register-capture helper: $($stageRegsHelper.Length)/$stageHelperBudget bytes @8148 SHA256=$(Sha $stageRegsHelperPath)"
Write-Host "[PASS] XP diagnostic runtime: $($runtime.Length)/$runtimeBudget bytes copied LBA8 -> 0000:1000 SHA256=$(Sha $runtimePath)"
Write-Host "[BASE] Microsoft NT52 VBR tail SHA256=$(Sha $nt52Vbr)"
Write-Host "[BASE] Microsoft NT52 stage2 SHA256=$(Sha $nt52Stage2)"
Write-Host '[PASS] Diagnostic architecture: MBR -> LBA1..6 prelude + LBA7 original MBR + LBA8 runtime -> triple EDD/CHS comparison -> instrumented Microsoft NT52 VBR/stage2 -> CRC32 + BIOS-timer auto-continue -> original NTLDR jump.'
Write-Host "OUTPUT=$out"
