$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$zig = Join-Path $root 'tools\zig\zig.exe'
$parser = Join-Path $root 'src\platform\bios\linux_boot_header.zig'
$realKernelTest = Join-Path $root 'tools\tests\legacy_bios\linux_boot_header_real_kernel_test.zig'
$kernel = Join-Path $root 'zig-out\micro-linux\vmlinuz-virt'

foreach ($item in @($zig, $parser, $realKernelTest, $kernel)) {
    if (-not (Test-Path -LiteralPath $item -PathType Leaf)) {
        throw "Required Linux boot-header test input is missing: $item"
    }
}

Push-Location $root
try {
    & $zig test $parser
    if ($LASTEXITCODE -ne 0) { throw "Linux boot-header unit tests failed: $LASTEXITCODE" }

    $testModule = $realKernelTest.Replace('\', '/')
    $parserModule = $parser.Replace('\', '/')
    & $zig test --dep linux_boot_header "-Mroot=$testModule" "-Mlinux_boot_header=$parserModule"
    if ($LASTEXITCODE -ne 0) { throw "Pinned vmlinuz boot-header test failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Host '[PASS] Legacy Linux boot-header parser + pinned Alpine vmlinuz contract'
