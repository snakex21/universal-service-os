#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
<# Host DISM reference prototype. REVIEW REQUIRED; previously run on a VHDX.
   A pinned job selects one new case. Never selects a physical host disk.
   The fixed VHDX allocation check is an initial-state check, not a guarantee
   that the Windows virtual disk driver cannot later extend the host file. #>
[CmdletBinding()]
param([Parameter(Mandatory)][Alias('Job')][string]$JobPathArg,
      [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$JobSha256,
      [switch]$ValidateJobOnly,[switch]$ValidateResumeOnly)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$head=(& git -C $repo rev-parse HEAD).Trim()
if ($head -notmatch '^[0-9a-f]{40}$' -or @(& git -C $repo status --porcelain=v1 -uall).Count -ne 0) {throw 'Clean HEAD required'}
$prefix="HEAD=$head DIRTY=0`n"
. (Join-Path $PSScriptRoot 'host_dism_executor.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'host_dism_log_capture.ps1')
. (Join-Path $PSScriptRoot 'host_dism_detach_guard.ps1')
Initialize-HostDismNativeReaders
Add-Type -Path (Join-Path $PSScriptRoot 'host_dism_vhdx_native.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'host_dism_bounded_process.cs')
if (-not [MiniOsHostDismVhdxNative]::AbiValid()) {throw 'Native VHDX ABI differs'}

function Assert-OrdinaryPath([string]$Path,[string]$Root,[bool]$Existing) {
    $full=[MiniOsBcdReference]::Canonical($Path);$base=[MiniOsBcdReference]::Canonical($Root).TrimEnd('\')
    if (-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Path outside authorized runtime'}
    if ($Existing -and -not (Test-Path -LiteralPath $full -PathType Leaf)) {throw 'Required input missing'}
    for($at=$full;$at;$at=[IO.Path]::GetDirectoryName($at)) {
        if ((Test-Path -LiteralPath $at) -and ((Get-Item -LiteralPath $at -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Reparse ancestry forbidden'}
    }
    return $full
}
function Open-Pinned([string]$Path,[string]$ExpectedSha) {
    if ($ExpectedSha -notmatch '^[0-9a-f]{64}$') {throw 'Input SHA required'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        if ($hash -cne $ExpectedSha) {throw 'Pinned input SHA differs'}
        $stream.Position=0;return $stream
    } catch {$stream.Dispose();throw}
}

$jobPath=[MiniOsBcdReference]::Canonical($JobPathArg)
$jobLock=Open-Pinned $jobPath $JobSha256
try {
    if ($jobLock.Length -gt 1MB) {throw 'Job too large'}
    $reader=[IO.StreamReader]::new($jobLock,[Text.Encoding]::UTF8,$true,4096,$true)
    $job=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable;$reader.Dispose()
    if ($job.schema -cne 'minios-host-dism-control-v1' -or $job.head -cne $head -or $job.index -ne 2 -or $job.virtual_bytes -ne 32GB) {throw 'Pinned exact host DISM job required'}
    if ($ValidateJobOnly) {Write-Output 'Pinned job schema and HEAD validated; no disk action'; return}
    # LibraryOnly loads observation helpers; it must never grant write access.
    # This unconditional fail-closed gate precedes all output and mutations.
    if (-not $ValidateResumeOnly) {Assert-HostDismMutationAvailable}
    $runtime=[MiniOsBcdReference]::Canonical([string]$job.runtime).TrimEnd('\')
    if ($runtime.Substring(0,2) -ine 'K:') {throw 'Authorized K runtime required'}
    $null=Assert-OrdinaryPath $jobPath $runtime $true
    $case=Assert-OrdinaryPath $job.case $runtime $false
    $caseParent=[IO.Path]::GetDirectoryName($case)
    $resume=($job.mode -ceq 'resume')
    if ($caseParent -ine (Join-Path $runtime '1c7') -or [IO.Path]::GetFileName($case) -notmatch '^host-dism-[0-9a-f-]+$') {throw 'Exact case required'}
    if ($resume) {
        Assert-HostDismResumeRequest -Case $case -Job $job
        if(-not (Test-Path -LiteralPath $case -PathType Container)){throw 'Resume case missing'}
    } elseif (Test-Path -LiteralPath $case) {throw 'Fresh unique case required'}
    foreach($name in @('plan','wim','oracle_receipt','oracle_tree')) {$job[$name]=Assert-OrdinaryPath $job[$name] $runtime $true}
    if ($job.wim_sha256 -cne 'de1f5d0d14b9337cb32790d718a84bcfbc94425660b224c705833da5d9e88a51') {throw 'WIM differs'}
    if ($job.volume_guid -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$') {throw 'Explicit runtime volume pin required'}
    $python=[MiniOsBcdReference]::Canonical([string]$job.python)
    if ([IO.Path]::GetFileName($python) -ine 'python.exe' -or (Get-FileHash -LiteralPath $python -Algorithm SHA256).Hash.ToLowerInvariant() -cne $job.python_sha256) {throw 'Pinned Python executable required'}
    $locks=[Collections.Generic.List[IDisposable]]::new()
    try {
        foreach($pair in @(@($python,$job.python_sha256),@($job.wim,$job.wim_sha256),@($job.plan,$job.plan_sha256),
                           @($job.oracle_receipt,$job.oracle_receipt_sha256),@($job.oracle_tree,$job.oracle_tree_sha256))) {
            $locks.Add((Open-Pinned $pair[0] $pair[1]))
        }
        if($resume) {
            foreach($pair in @(@('result.json',$job.resume_result_sha256),@('original-gpt-first-1m.bin',$job.resume_gpt_first_sha256),@('original-gpt-last-1m.bin',$job.resume_gpt_last_sha256),@('original-gpt-backup.json',$job.resume_gpt_manifest_sha256))) {
                $locks.Add((Open-Pinned (Join-Path $case $pair[0]) $pair[1]))
            }
            $imageLock=Open-Pinned (Join-Path $case 'install.vhdx') $job.resume_image_sha256
            $imageLock.Dispose()
        }
        $env:USOS_MINIOS_RUNTIME=$runtime;$env:USOS_MINIOS_VOLUME_GUID=$job.volume_guid
        $env:PYTHONNOUSERSITE='1';$env:PYTHONPATH=''
        $image=Join-Path $case 'install.vhdx'
        if($ValidateResumeOnly) {
            if(-not $resume){throw 'Read-only resume validation requires resume job'}
            $prior=@(Get-DiskImage -ImagePath $image -ErrorAction Stop)
            if($prior.Count -ne 1 -or $prior[0].Attached){throw 'Resume image must be detached'}
            $args=@((Join-Path $PSScriptRoot 'host_dism_capacity.py'),'--root',$runtime,'--plan',$job.plan,'--plan-sha256',$job.plan_sha256,'--case',$case,'--image-exists','yes')
            & $python @args
            if($LASTEXITCODE -ne 0){throw 'Resume capacity preflight failed'}
            Write-Output 'Pinned resume inputs and detached image validated; no disk action'
            return
        }
        $scratchName='USOS-TEMP-'+([guid]::NewGuid().ToString('N').ToUpperInvariant())
        $out=if($resume){Join-Path $case $job.resume_name}else{$case}
        if($resume -and (Test-Path -LiteralPath $out)){throw 'Resume evidence directory already exists'}
        $temporary=$out
        $seq=0;$pin=$null;$diskExpected=$null;$mounted=$false;$aliases=[Collections.Generic.List[object]]::new()
        $knownParts=[Collections.Generic.List[object]]::new();$initialized=$false
        $result=[ordered]@{schema='minios-host-dism-reference-v1';passed=$false;head=$head;job_sha256=$JobSha256;image=$image;wim_sha256=$job.wim_sha256;index=2;vhdmp_growth_guaranteed=$false;dismounted=$false}
        $processPolicy=[MiniOsHostDismProcess]::new($python,$job.python_sha256)
        function Run-Logged([string]$Exe,[string[]]$Arguments,[string]$Stem,[string]$TempDir) {
            Assert-HostDismMutationAvailable
            $script:seq++;$base=('{0:D3}-{1}' -f $script:seq,$Stem)
            $stdout=Join-Path $out ($base+'-out.log');$stderr=Join-Path $out ($base+'-err.log')
            $script:lastStdout=$stdout;$script:lastStderr=$stderr;$script:lastExitCode=$null
            $rc=$processPolicy.RunAllowed($Exe,$Arguments,$stdout,$stderr,$prefix,64MB,10800000,$TempDir)
            $script:lastExitCode=$rc
            if ($rc -ne 0) {throw "$Stem failed with exit $rc"}
            return $stdout
        }
        function Capacity([bool]$Exists) {
            if ((& git -C $repo rev-parse HEAD).Trim() -cne $head -or @(& git -C $repo status --porcelain=v1 -uall).Count -ne 0) {throw 'HEAD/worktree changed before phase'}
            $args=@((Join-Path $PSScriptRoot 'host_dism_capacity.py'),'--root',$runtime,'--plan',$job.plan,'--plan-sha256',$job.plan_sha256,'--case',$case,'--image-exists',$(if($Exists){'yes'}else{'no'}))
            # Capture the tiny preflight response before creating a new log;
            # otherwise the log itself would be written before the check.
            $output=@(& $python @args 2>&1)
            if($LASTEXITCODE -ne 0){throw 'Capacity preflight failed'}
            $json=($output -join "`n");$measurement=$json | ConvertFrom-Json -AsHashtable
            # Of the 3 GiB non-image budget, retain 2 GiB for the later
            # firstboot overlay and leave 65 MiB for the next bounded logs.
            if($measurement.other_logical_bytes -gt (1GB-65MB) -or $measurement.other_allocated_bytes -gt (1GB-65MB)) {throw 'Insufficient log or firstboot overlay reservation'}
            $script:seq++;$path=Join-Path $out ('{0:D3}-capacity.log' -f $script:seq)
            if($json.Length -gt 65536){throw 'Capacity response exceeds bound'}
            [IO.File]::WriteAllText($path,$prefix+$json+"`n",[Text.UTF8Encoding]::new($false))
        }
        function Verify-Disk {
            return (Get-HostDismVerifiedDisk -FilePin $pin -ImagePath $image -Expected $diskExpected)
        }
        function Before-Phase {
            Assert-HostDismMutationAvailable
            Capacity $true
            $disk=Verify-Disk
            if($initialized) {
                if($disk.PartitionStyle.ToString() -cne 'GPT'){throw 'Virtual disk no longer has GPT'}
                $found=@(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)
                if($found.Count -ne $knownParts.Count){throw 'Unexpected partition count'}
                foreach($part in $knownParts){$null=Assert-HostDismPartition -Disk $disk -Expected $part}
            }
            foreach($alias in $aliases) {Assert-HostDismAlias -Alias $alias.alias -ExpectedTarget $alias.target -Disk $disk -Partition $alias.partition}
            return $disk
        }
        function Assert-NoReparse([string]$Path) {
            for($walk=$Path;$walk -and $walk.Length -gt 3;$walk=[IO.Path]::GetDirectoryName($walk)) {
                if((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Temporary path redirects'}
            }
        }
        function Add-Alias([hashtable]$Part) {
            $disk=Before-Phase;$partition=Assert-HostDismPartition -Disk $disk -Expected $Part
            $vol=@($partition | Get-Volume -ErrorAction Stop)
            $filesystem=if($Part.GptType -ceq 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'){'FAT32'}else{'NTFS'}
            if($vol.Count -ne 1 -or $vol[0].DriveLetter -or $vol[0].Path -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') {throw 'Unlettered virtual volume required'}
            if($vol[0].FileSystem -ine $filesystem){throw 'Virtual volume filesystem differs'}
            $buf=[Text.StringBuilder]::new(32768)
            if(-not [MiniOsBcdReference]::QueryDosDevice($vol[0].Path.Substring(4).TrimEnd('\'),$buf,$buf.Capacity)) {throw 'Volume target lookup failed'}
            $target=$buf.ToString().Split([char]0)[0]
            foreach($candidate in @('Z:','Y:','X:','W:','V:','U:','T:','S:','R:')) {
                $buf=[Text.StringBuilder]::new(32768)
                if([MiniOsBcdReference]::QueryDosDevice($candidate,$buf,$buf.Capacity)) {continue}
                if([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 2) {continue}
                $null=Before-Phase
                if(-not [MiniOsBcdReference]::DefineDosDevice(9,$candidate,$target)) {throw 'Could not create temporary alias'}
                $entry=@{alias=$candidate;target=$target;partition=$Part};$aliases.Add($entry)
                Assert-HostDismAlias -Alias $candidate -ExpectedTarget $target -Disk (Verify-Disk) -Partition $Part
                return $entry
            }
            throw 'No private alias available'
        }
        try {
            Assert-HostDismMutationAvailable
            # Capacity check must precede even directory creation. For this
            # one bootstrap command no log is written until the case exists.
            $capArgs=@((Join-Path $PSScriptRoot 'host_dism_capacity.py'),'--root',$runtime,'--plan',$job.plan,'--plan-sha256',$job.plan_sha256,'--case',$case,'--image-exists',$(if($resume){'yes'}else{'no'}))
            & $python @capArgs | Out-Null;if($LASTEXITCODE -ne 0){throw 'Initial capacity check failed'}
            [MiniOsHostDismVhdxNative]::CreateFreshDirectory($out)
            Capacity $resume
            $treeArgs=@((Join-Path $PSScriptRoot 'host_dism_tree_guard.py'),'--receipt',$job.oracle_receipt,'--receipt-sha256',$job.oracle_receipt_sha256,'--tree',$job.oracle_tree,'--tree-sha256',$job.oracle_tree_sha256,'--name',$scratchName)
            $null=Run-Logged $python $treeArgs 'scratch-tree' $temporary
            Capacity $resume
            if(-not $resume){[MiniOsHostDismVhdxNative]::CreateFreshFixed($image,32GB)}
            $pin=[MiniOsHostDismFilePin]::new($image);$pin.AssertUnchanged()
            Capacity $true
            $verifyArgs=@((Join-Path $PSScriptRoot 'host_dism_vhdx_verify.py'),'--image',$image,'--virtual',[string](32GB),'--cap',[string](33GB))
            $null=Run-Logged $python $verifyArgs 'fixed-vhdx' $temporary
            $pin.AssertUnchanged();Capacity $true
            $prior=@(Get-DiskImage -ImagePath $image -ErrorAction Stop)
            if($prior.Count -ne 1 -or $prior[0].Attached){throw 'New image must be detached'}
            $attachment=Mount-DiskImage -ImagePath $image -Access ReadWrite -NoDriveLetter -PassThru -ErrorAction Stop;$mounted=$true
            $initial=@($attachment | Get-Disk -ErrorAction Stop)
            if($initial.Count -ne 1 -or $initial[0].IsBoot -or $initial[0].IsSystem -or $initial[0].IsReadOnly -or $initial[0].IsOffline -or
               $initial[0].Size -ne 32GB -or $initial[0].LogicalSectorSize -ne 512 -or $initial[0].PartitionStyle.ToString() -cne $(if($resume){'GPT'}else{'RAW'}) -or
               (($initial[0].BusType.ToString() -replace ' ','') -ine 'FileBackedVirtual')) {throw 'New attached disk is not exact blank virtual disk'}
            $diskExpected=@{Number=$initial[0].Number;Path=$initial[0].Path;UniqueId=$initial[0].UniqueId;Bytes=32GB}
            $disk=Before-Phase
            if(-not $resume){Initialize-Disk -InputObject $disk -PartitionStyle GPT -ErrorAction Stop | Out-Null}
            $disk=Verify-Disk
            $msrWant=Get-HostDismInitialMsr -Disk $disk -RequiredGuid $(if($resume){$job.resume_msr_guid}else{''})
            $knownParts.Add($msrWant)
            $initialized=$true
            $disk=Before-Phase
            $esp=New-Partition -InputObject $disk -Offset 16MB -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -ErrorAction Stop
            $espWant=@{Number=$esp.PartitionNumber;Offset=16MB;Bytes=260MB;Guid=([string]$esp.Guid).Trim('{}');GptType='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'}
            if($espWant.Guid -notmatch '^[0-9a-fA-F-]{36}$'){throw 'ESP GUID missing'};$knownParts.Add($espWant)
            $disk=Before-Phase;$null=Assert-HostDismPartition -Disk $disk -Expected $espWant
            $win=New-Partition -InputObject $disk -Offset 276MB -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -ErrorAction Stop
            if($win.Size -lt 20GB){throw 'Windows partition too small'}
            $winWant=@{Number=$win.PartitionNumber;Offset=276MB;Bytes=$win.Size;Guid=([string]$win.Guid).Trim('{}');GptType='ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'}
            if($winWant.Guid -notmatch '^[0-9a-fA-F-]{36}$'){throw 'Windows GUID missing'};$knownParts.Add($winWant)
            $result.partitions=@($espWant,$msrWant,$winWant)
            $disk=Before-Phase;$part=Assert-HostDismPartition -Disk $disk -Expected $espWant
            Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'SYSTEM' -Force -Confirm:$false -ErrorAction Stop | Out-Null
            $disk=Before-Phase;$part=Assert-HostDismPartition -Disk $disk -Expected $winWant
            Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'WINDOWS' -Force -Confirm:$false -ErrorAction Stop | Out-Null
            $espAlias=Add-Alias $espWant;$winAlias=Add-Alias $winWant
            if($espAlias.alias -eq $winAlias.alias){throw 'Separate ESP and Windows aliases required'}
            $scratch=Join-Path ($winAlias.alias+'\') $scratchName
            $null=Before-Phase
            if(Test-Path -LiteralPath $scratch){throw 'Scratch path already exists'}
            [MiniOsHostDismVhdxNative]::CreateFreshDirectory($scratch)
            Assert-NoReparse $scratch
            $null=Before-Phase
            $dism=Join-Path ([Environment]::GetFolderPath('System')) 'dism.exe'
            $dismArgs=@('/Apply-Image',('/ImageFile:'+ $job.wim),'/Index:2',('/ApplyDir:'+ $winAlias.alias+'\'),('/ScratchDir:'+ $scratch),('/LogPath:'+ (Join-Path $scratch 'dism.log')))
            $dismFailure=$null
            try {$null=Run-Logged $dism $dismArgs 'dism' $scratch;$result.dism_status='success'}
            catch {$dismFailure=$_.Exception.Message;$result.dism_status='failed';$result.dism_error=$dismFailure}
            $result.dism_exit=$script:lastExitCode;$result.dism_stdout=$script:lastStdout;$result.dism_stderr=$script:lastStderr
            try {
                $logDestination=Join-Path $out 'dism-internal.log'
                $result.dism_internal_log_copied=Copy-HostDismLog -Source (Join-Path $scratch 'dism.log') -Destination $logDestination -Prefix $prefix -Guard {Before-Phase} -PathGuard {param($p) Assert-NoReparse $p}
                if($result.dism_internal_log_copied){$result.dism_internal_log=$logDestination}
                elseif(-not $dismFailure){$dismFailure='DISM internal log was absent'}
            } catch {$result.dism_log_error=$_.Exception.Message;if(-not $dismFailure){$dismFailure='DISM log could not be preserved'}}
            if($dismFailure){throw ('DISM failed or evidence could not be saved: '+$dismFailure)}
            $null=Before-Phase;Assert-NoReparse $scratch
            # Host bcdboot is permanently forbidden, even with a verified /s.
            # Apply-only references require separate offline REGF/boot preparation.
            $result.bcdboot_status='permanently_forbidden'
            $result.offline_boot_preparation_required=$true
            $null=Before-Phase;Assert-NoReparse $scratch
            foreach($item in @(Get-ChildItem -LiteralPath $scratch -Recurse -Force -ErrorAction Stop)) {
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse data in temporary tree'}
            }
            $null=Before-Phase
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop
            $null=Before-Phase
            $result.passed=$true
        } catch {$result.error=$_.Exception.Message;$result.passed=$false}
        finally {
            for($i=$aliases.Count-1;$i -ge 0;$i--) {
                $a=$aliases[$i];$buf=[Text.StringBuilder]::new(32768)
                try {
                    Assert-HostDismMutationAvailable
                    try {Capacity $true} catch {$result.passed=$false;$result.cleanup_capacity_error=$_.Exception.Message}
                    $cleanupDisk=Verify-Disk
                    Assert-HostDismAlias -Alias $a.alias -ExpectedTarget $a.target -Disk $cleanupDisk -Partition $a.partition
                    if(-not [MiniOsBcdReference]::DefineDosDevice(15,$a.alias,$a.target)){throw 'Alias removal failed'}
                } catch {$result.passed=$false;$result.alias_cleanup_failed=$true}
            }
            if($mounted -and $diskExpected) {
                try {Assert-HostDismMutationAvailable;try {Capacity $true} catch {$result.passed=$false;$result.cleanup_capacity_error=$_.Exception.Message};$null=Verify-Disk;Dismount-HostDismPinnedImage -FilePin $pin -ImagePath $image;$result.dismounted=$true}
                catch {$result.passed=$false;$result.detach_error=$_.Exception.Message}
            }
            elseif($mounted) {
                # Mount may have succeeded before Get-Disk returned a usable
                # disk identity. Detach by the exact still-pinned image path;
                # do not infer or open any physical disk number.
                try {
                    Assert-HostDismMutationAvailable
                    if(-not $pin){throw 'Mounted image file pin missing'}
                    Dismount-HostDismPinnedImage -FilePin $pin -ImagePath $image
                    $result.dismounted=$true;$result.detached_without_disk_identity=$true
                } catch {$result.passed=$false;$result.detach_error=$_.Exception.Message}
            }
            if($pin){$pin.Dispose()}
            if(Test-Path -LiteralPath $out) {
                if($result.dismounted -and (Test-Path -LiteralPath $image)) {
                    try {Capacity $true;$result.image_bytes=(Get-Item -LiteralPath $image).Length;$result.image_sha256=(Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant()}
                    catch {$result.passed=$false;$result.image_hash_error=$_.Exception.Message}
                }
                $result.head_after=(& git -C $repo rev-parse HEAD).Trim();$result.dirty_after=@(& git -C $repo status --porcelain=v1 -uall).Count
                if($result.head_after -cne $head -or $result.dirty_after -ne 0){$result.passed=$false;$result.tree_changed=$true}
                [IO.File]::WriteAllText((Join-Path $out 'result.json'),(($result | ConvertTo-Json -Depth 8)+"`n"),[Text.UTF8Encoding]::new($false))
            }
        }
        if(-not $result.passed){throw ('Host DISM reference failed: '+$result.error)}
        $result | ConvertTo-Json -Depth 8
    } finally {foreach($lock in $locks){$lock.Dispose()}}
} finally {$jobLock.Dispose()}
