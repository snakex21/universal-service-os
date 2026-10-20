# PE10 donor ISO image (UDF 1.02, no El Torito) via Windows IMAPI2FS; called by
# tools/release/build_pe10_donor.py. File-system image creation only: no
# recorder, no disc writer, no USB access.
param(
    [Parameter(Mandatory=$true)][string]$Payload,
    [Parameter(Mandatory=$true)][string]$OutputIso,
    [Parameter(Mandatory=$true)][string]$WorkDirectory,
    [Parameter(Mandatory=$true)][string]$VolumeName
)
$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath((Split-Path -Parent $OutputIso)).TrimEnd("\") + "\"
foreach ($path in @($Payload, $OutputIso, $WorkDirectory)) {
    if (-not [IO.Path]::GetFullPath($path).StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "All paths must remain inside the output directory: $path"
    }
}
if (Test-Path -LiteralPath $OutputIso) { throw 'Refusing to overwrite an ISO' }
[void][IO.Directory]::CreateDirectory($WorkDirectory)
$env:TEMP = $WorkDirectory
$env:TMP = $WorkDirectory
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class DonorImageStream {
    public static long Save(object value, string path) {
        IStream stream = (IStream)value;
        System.Runtime.InteropServices.ComTypes.STATSTG stat;
        stream.Stat(out stat, 1);
        stream.Seek(0, 0, IntPtr.Zero);
        byte[] buffer = new byte[1024 * 1024];
        IntPtr count = Marshal.AllocCoTaskMem(4);
        long total = 0;
        try {
            using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                while (total < stat.cbSize) {
                    int wanted = (int)Math.Min(buffer.Length, stat.cbSize - total);
                    Marshal.WriteInt32(count, 0);
                    stream.Read(buffer, wanted, count);
                    int got = Marshal.ReadInt32(count);
                    if (got <= 0 || got > wanted) throw new EndOfStreamException("Invalid IMAPI IStream read");
                    output.Write(buffer, 0, got);
                    total += got;
                }
                output.Flush(true);
            }
            return total;
        } finally { Marshal.FreeCoTaskMem(count); }
    }
}
'@
$image = $null
$result = $null
$stream = $null
try {
    # File-system image creation only: no recorder, no disc writer, no USB access.
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.WorkingDirectory = $WorkDirectory
    $image.FileSystemsToCreate = 4
    $image.UDFRevision = 0x102
    $image.FreeMediaBlocks = 500000
    $image.VolumeName = $VolumeName
    $image.Root.AddTree($Payload, $false)
    Write-Output ('IMAPI2FS UDFRevision=0x{0:X4}; FileSystemsToCreate={1}; ElTorito=not configured' -f $image.UDFRevision, $image.FileSystemsToCreate)
    $result = $image.CreateResultImage()
    $stream = $result.ImageStream
    $length = [DonorImageStream]::Save($stream, $OutputIso)
    if ($length -ne [long]$result.TotalBlocks * [long]$result.BlockSize) { throw 'IMAPI length mismatch' }
    Write-Output "ISO created: $OutputIso; bytes=$length; blocks=$($result.TotalBlocks); blockSize=$($result.BlockSize)"
} finally {
    foreach ($value in @($stream, $result, $image)) {
        if ($null -ne $value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($value)
        }
    }
}
