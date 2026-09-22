param(
    [Parameter(Mandatory=$true)][int]$DiskNumber,
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [string]$StagingDirectory = 'J:\ISO',
    [string]$ExpectedDataLabel = 'USOS_DATA',
    [Parameter(Mandatory=$true)][string]$LogPath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$SourcePath = [IO.Path]::GetFullPath($SourcePath)
$LogPath = [IO.Path]::GetFullPath($LogPath)
$ResultPath = [IO.Path]::GetFullPath($ResultPath)

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Missing source ISO: $SourcePath"
}
if ([IO.Path]::GetExtension($SourcePath) -ine '.iso') {
    throw "Source is not an ISO file: $SourcePath"
}

$disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
if ($disk.IsBoot -or $disk.IsSystem) {
    throw "Refusing system/boot disk PhysicalDrive$DiskNumber"
}
if ($disk.BusType -ne 'USB') {
    throw "Refusing non-USB PhysicalDrive$DiskNumber bus=$($disk.BusType)"
}

$dataPartition = $null
foreach ($partition in Get-Partition -DiskNumber $DiskNumber) {
    $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
    if ($null -ne $volume -and $volume.FileSystemLabel -eq $ExpectedDataLabel) {
        if ($null -ne $dataPartition) { throw "Multiple $ExpectedDataLabel volumes on PhysicalDrive$DiskNumber" }
        $dataPartition = $partition
    }
}
if ($null -eq $dataPartition -or -not $dataPartition.DriveLetter) {
    throw "PhysicalDrive$DiskNumber has no mounted $ExpectedDataLabel volume"
}
$dataRoot = "$($dataPartition.DriveLetter):\"
$stagingFull = [IO.Path]::GetFullPath($StagingDirectory)
if (-not $stagingFull.StartsWith($dataRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing staging directory outside PhysicalDrive$DiskNumber DATA: $stagingFull"
}

$source = Get-Item -LiteralPath $SourcePath
$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourcePath).Hash.ToLowerInvariant()
$sourceDir = $source.DirectoryName
$fileName = $source.Name
New-Item -ItemType Directory -Force -Path $stagingFull | Out-Null
$destination = Join-Path $stagingFull $fileName
Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $LogPath,$ResultPath -Force -ErrorAction SilentlyContinue

$robocopyArgs = @(
    $sourceDir,
    $stagingFull,
    $fileName,
    '/J',
    '/R:0',
    '/W:0',
    '/COPY:DAT',
    '/DCOPY:T',
    '/TEE',
    "/LOG:$LogPath"
)
& robocopy.exe @robocopyArgs
$rc = $LASTEXITCODE
if ($rc -gt 7) {
    throw "robocopy failed with exit code $rc; see $LogPath"
}
if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
    throw "Destination ISO missing after robocopy: $destination"
}
$destinationInfo = Get-Item -LiteralPath $destination
if ($destinationInfo.Length -ne $source.Length) {
    throw "ISO size mismatch source=$($source.Length) destination=$($destinationInfo.Length)"
}
$destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
if ($destinationHash -ne $sourceHash) {
    throw "ISO SHA-256 mismatch source=$sourceHash destination=$destinationHash"
}

@(
    'RESULT=PASS',
    "DISK=$DiskNumber",
    "DATA=$dataRoot",
    "STAGING=$destination",
    "BYTES=$($source.Length)",
    "SHA256=$sourceHash",
    "ROBOCOPY_EXIT=$rc"
) | Set-Content -LiteralPath $ResultPath -Encoding ASCII
