#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic mocked PowerShell observations; no image or disk is opened."""
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'tools'/'minios'/'host_dism_executor.ps1'
CS=ROOT/'tools'/'minios'/'host_dism_file_identity.cs'
NATIVE=ROOT/'tools'/'minios'/'host_dism_vhdx_native.cs'
BOUNDED=ROOT/'tools'/'minios'/'host_dism_bounded_process.cs'
RUNNER=ROOT/'tools'/'minios'/'host_dism_run.ps1'
DETACH=ROOT/'tools'/'minios'/'host_dism_detach_guard.ps1'
LOG_CAPTURE=ROOT/'tools'/'minios'/'host_dism_log_capture.ps1'


def powershell(source):
    result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-Command',source],
                          cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=30)
    if result.returncode:
        raise AssertionError(result.stdout+'\n'+result.stderr)
    return result.stdout


class Tests(unittest.TestCase):
    def test_native_file_identity_compiles_without_opening_a_file(self):
        powershell("$ErrorActionPreference='Stop'; Add-Type -Path '"+str(CS).replace("'","''")+"'; if(-not ('MiniOsHostDismFilePin' -as [type])) {throw 'missing class'}")

    def test_native_creator_compiles_and_rejects_bad_arguments_before_api(self):
        src="$ErrorActionPreference='Stop'; Add-Type -Path '"+str(NATIVE).replace("'","''")+"'; "
        src+=r'''if(-not [MiniOsHostDismVhdxNative]::AbiValid()) {throw 'bad ABI'}
        foreach ($bad in @('relative.vhdx','\\server\file.vhdx','C:\file.img')) {
            $rejected=$false
            try {[MiniOsHostDismVhdxNative]::CreateFreshFixed($bad,16777216)} catch {$rejected=$true}
            if(-not $rejected) {throw 'bad path accepted'}
        }
        '''
        powershell(src)

    def test_bounded_process_limits_output_without_polling(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as tmp:
            src="$ErrorActionPreference='Stop'; Add-Type -Path '"+str(BOUNDED).replace("'","''")+"'; "
            src += "$dir='"+tmp.replace("'","''")+"'; "
            src += r'''
            $exe=(Get-Command python.exe).Source
            $policy=[MiniOsHostDismProcess]::new($exe,(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant())
            $ok=$policy.RunAllowed($exe,@('-c','print("hello")'),(Join-Path $dir 'a'),(Join-Path $dir 'b'),"HEAD=test DIRTY=0`n",1024,30000,$dir)
            if($ok -ne 0) {throw 'unexpected exit'}
            $failed=$false
            try {$policy.RunAllowed($exe,@('-c','print("x"*8192)'),(Join-Path $dir 'c'),(Join-Path $dir 'd'),"HEAD=test DIRTY=0`n",1024,30000,$dir)} catch {$failed=$true}
            if(-not $failed) {throw 'output cap was bypassed'}
            if((Get-Item (Join-Path $dir 'c')).Length+(Get-Item (Join-Path $dir 'd')).Length -gt 1024) {throw 'log size exceeded'}
            '''
            powershell(src)

    def test_exited_parent_with_child_holding_pipe_finishes_bounded(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as tmp:
            src="$ErrorActionPreference='Stop'; Add-Type -Path '"+str(BOUNDED).replace("'","''")+"'; "
            src += "$dir='"+tmp.replace("'","''")+"'; "
            src += r'''
            $exe=(Get-Command python.exe).Source
            $policy=[MiniOsHostDismProcess]::new($exe,(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant())
            $child='import subprocess,sys; subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"])' 
            $clock=[Diagnostics.Stopwatch]::StartNew();$failed=$false
            try {$policy.RunAllowed($exe,@('-c',$child),(Join-Path $dir 'a'),(Join-Path $dir 'b'),"HEAD=test DIRTY=0`n",1048576,20000,$dir)} catch {$failed=$true}
            $clock.Stop()
            if(-not $failed -or $clock.Elapsed.TotalSeconds -gt 15) {throw 'Inherited pipe not bounded'}
            '''
            powershell(src)

    def test_detach_without_disk_number_requires_exact_pinned_path(self):
        src=". '"+str(DETACH).replace("'","''")+"'\n"
        src+=r'''
        $script:checked=0;$script:detached=0
        $pin=[pscustomobject]@{}; $pin | Add-Member -MemberType ScriptMethod -Name AssertUnchanged -Value {$script:checked++}
        $script:image=[pscustomobject]@{Attached=$true;ImagePath='K:\case\image.vhdx'}
        function Get-DiskImage {param($ImagePath) $script:image}
        function Dismount-DiskImage {param($ImagePath) $script:detached++}
        Dismount-HostDismPinnedImage -FilePin $pin -ImagePath 'K:\case\image.vhdx'
        if($script:checked -ne 2 -or $script:detached -ne 1) {throw 'exact detach failed'}
        $script:image.ImagePath='K:\different.vhdx';$failed=$false
        try {Dismount-HostDismPinnedImage -FilePin $pin -ImagePath 'K:\case\image.vhdx'} catch {$failed=$true}
        if(-not $failed -or $script:detached -ne 1) {throw 'wrong image detached'}
        '''
        powershell(src)

    def test_dism_log_copy_survives_subsequent_failure(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as tmp:
            src=". '"+str(LOG_CAPTURE).replace("'","''")+"'\n$dir='"+tmp.replace("'","''")+"'\n"
            src+=r'''
            $source=Join-Path $dir 'inside';$dest=Join-Path $dir 'captured'
            [IO.File]::WriteAllText($source,'DISM result')
            $script:guarded=0;$script:pathguarded=0
            $copied=Copy-HostDismLog -Source $source -Destination $dest -Prefix "HEAD=test DIRTY=0`n" -Guard {$script:guarded++} -PathGuard {param($p) $script:pathguarded++}
            try {throw 'synthetic bcdboot collision'} catch {}
            if(-not $copied -or $script:guarded -ne 1 -or $script:pathguarded -ne 1 -or
               -not (Test-Path -LiteralPath $source) -or -not ([IO.File]::ReadAllText($dest).Contains('DISM result'))) {throw 'DISM evidence lost'}
            $failed=$false
            try {Copy-HostDismLog -Source $source -Destination (Join-Path $dir 'not-created') -Prefix 'HEAD=test' -Guard {throw 'identity changed'} -PathGuard {param($p)}} catch {$failed=$true}
            if(-not $failed -or (Test-Path -LiteralPath (Join-Path $dir 'not-created'))) {throw 'bad identity copied'}
            '''
            powershell(src)

    def test_all_mutations_refuse_without_a_bypass(self):
        script=". '"+str(SCRIPT).replace("'","''")+"' -LibraryOnly\n"
        script += r'''
        foreach($name in @('Create','Attach','Initialize','CreatePartition','Format','Alias','Apply','Bcdboot','Detach')) {
            $failed=$false
            try {Invoke-HostDismMutation -Operation $name} catch {
                if ($_.Exception.Message -notmatch 'HOST_DISM_MUTATION_BLOCKED') {throw}
                $failed=$true
            }
            if(-not $failed) {throw ('mutation did not fail: '+$name)}
        }
        '''
        powershell(script)

    def test_default_entry_fails_closed(self):
        result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-File',str(SCRIPT)],cwd=ROOT,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=30)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('HOST_DISM_MUTATION_BLOCKED',result.stderr)

    def test_runner_parses_and_missing_job_fails_before_any_disk_action(self):
        path=str(RUNNER).replace("'","''")
        powershell("$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('"+path+"',[ref]$t,[ref]$e);if($e.Count){throw $e[0]}")
        result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-File',str(RUNNER),
                               '-Job',str(ROOT/'runtime'/'absent-job.json'),'-JobSha256','a'*64],cwd=ROOT,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=30)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('Mount-DiskImage',result.stderr)

    def test_runner_parses_pinned_job_without_mutation(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as tmp:
            job=Path(tmp)/'job.json'
            job.write_text(json.dumps({'schema':'minios-host-dism-control-v1',
                                      'head':'b'*40,'index':2,'virtual_bytes':32*1024**3}),encoding='utf-8')
            digest=hashlib.sha256(job.read_bytes()).hexdigest()
            src="$ErrorActionPreference='Stop'\n"
            src+="function git { if ($args -contains 'rev-parse') { '"+('b'*40)+"' } }\n"
            src+="function Mount-DiskImage { throw 'unexpected mutation' }\n"
            src+="& '"+str(RUNNER).replace("'","''")+"' -Job '"+str(job).replace("'","''")+"' -JobSha256 '"+digest+"' -ValidateJobOnly\n"
            self.assertIn('Pinned job schema and HEAD validated; no disk action',powershell(src))

    def test_runner_library_only_cannot_bypass_mutation_gate(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as tmp:
            job=Path(tmp)/'job.json'
            job.write_text(json.dumps({'schema':'minios-host-dism-control-v1',
                                      'head':'b'*40,'index':2,'virtual_bytes':32*1024**3}),encoding='utf-8')
            digest=hashlib.sha256(job.read_bytes()).hexdigest()
            src="$ErrorActionPreference='Stop'\n"
            src+="function git { if ($args -contains 'rev-parse') { '"+('b'*40)+"' } }\n"
            src+="function Mount-DiskImage { throw 'unexpected mutation' }\n"
            src+="function Format-Volume { throw 'unexpected mutation' }\n"
            src+="$blocked=$false; try { & '"+str(RUNNER).replace("'","''")+"' -Job '"+str(job).replace("'","''")+"' -JobSha256 '"+digest+"' } catch { if ($_.Exception.Message -notmatch 'HOST_DISM_MUTATION_BLOCKED') { throw }; $blocked=$true }\n"
            src+="if (-not $blocked) { throw 'runner bypassed the mutation guard' }\n"
            powershell(src)
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()),['job.json'])

    def test_disk_mapping_guards_using_only_mocks(self):
        script=". '"+str(SCRIPT).replace("'","''")+"' -LibraryOnly\n"
        script += r'''
        $pin=[pscustomobject]@{}; $pin | Add-Member -MemberType ScriptMethod -Name AssertUnchanged -Value {}
        $script:image=[pscustomobject]@{Attached=$true;ImagePath='K:\fake.vhdx';DevicePath='\\.\PHYSICALDRIVE42'}
        $script:disk=[pscustomobject]@{Number=42;Path='fake-path';UniqueId='fake-unique';Size=32768;LogicalSectorSize=512;IsBoot=$false;IsSystem=$false;IsReadOnly=$false;BusType='File Backed Virtual'}
        function Get-DiskImage {param($ImagePath) $script:image}
        function Get-Disk {param([Parameter(ValueFromPipeline=$true)]$InputObject,$Number) process {$script:disk}}
        $expected=@{Number=42;Path='fake-path';UniqueId='fake-unique';Bytes=32768}
        $result=Get-HostDismVerifiedDisk -FilePin $pin -ImagePath 'K:\fake.vhdx' -Expected $expected
        if($result.Number -ne 42) {throw 'expected mocked match'}
        foreach($field in @('IsBoot','IsSystem','IsReadOnly')) {
            $script:disk.$field=$true; $rejected=$false
            try {Get-HostDismVerifiedDisk -FilePin $pin -ImagePath 'K:\fake.vhdx' -Expected $expected} catch {$rejected=$true}
            $script:disk.$field=$false
            if(-not $rejected) {throw ('did not reject '+$field)}
        }
        $script:disk.BusType='NVMe';$rejected=$false
        try {Get-HostDismVerifiedDisk -FilePin $pin -ImagePath 'K:\fake.vhdx' -Expected $expected} catch {$rejected=$true}
        if(-not $rejected) {throw 'physical disk accepted'}
        '''
        powershell(script)

    def test_partition_guard_uses_mocked_data_only(self):
        script=". '"+str(SCRIPT).replace("'","''")+"' -LibraryOnly\n"
        script += r'''
        $disk=[pscustomobject]@{Number=42;Size=16777216}
        $script:part=[pscustomobject]@{DiskNumber=42;Offset=1048576;Size=4194304;Guid='abcd';GptType='ef01'}
        function Get-Partition {param($DiskNumber,$PartitionNumber) $script:part}
        $want=@{Number=3;Offset=1048576;Bytes=4194304;Guid='abcd';GptType='ef01'}
        $null=Assert-HostDismPartition -Disk $disk -Expected $want
        $script:part.DiskNumber=1;$rejected=$false
        try {Assert-HostDismPartition -Disk $disk -Expected $want} catch {$rejected=$true}
        if(-not $rejected) {throw 'wrong disk accepted'}
        '''
        powershell(script)

    def test_automatic_msr_requires_exact_geometry_and_identity(self):
        script=". '"+str(SCRIPT).replace("'","''")+"' -LibraryOnly\n"
        script+=r'''
        $disk=[pscustomobject]@{Number=42;Size=32GB}
        $guid='e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10'
        $script:part=[pscustomobject]@{DiskNumber=42;PartitionNumber=1;Offset=(34*512);Size=((32768-34)*512);Guid=$guid;GptType='e3c9e316-0b5c-4db8-817d-f92df00215ae'}
        function Get-Partition {param($DiskNumber,$PartitionNumber) $script:part}
        $ok=Get-HostDismInitialMsr -Disk $disk -RequiredGuid $guid
        if($ok.Guid -ne $guid){throw 'MSR was not pinned'}
        foreach($change in @('guid','offset','size','type')) {
          $saved=$script:part.PSObject.Copy()
          switch($change){'guid'{$script:part.Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'} 'offset'{$script:part.Offset+=512} 'size'{$script:part.Size-=512} 'type'{$script:part.GptType='ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'}}
          $failed=$false;try {Get-HostDismInitialMsr -Disk $disk -RequiredGuid $guid} catch {$failed=$true}
          $script:part=$saved;if(-not $failed){throw ('accepted wrong '+$change)}
        }
        '''
        powershell(script)

    def test_resume_accepts_only_the_reviewed_image_and_msr(self):
        script=". '"+str(SCRIPT).replace("'","''")+"' -LibraryOnly\n"
        script+=r'''
        $case='K:\x\host-dism-538d709d-91fb-4e74-a43b-8a123e253760'
        $job=@{mode='resume';resume_image_sha256='f1e226959665d779a6fdc4a3229c57d8ec1211dd67f1376a3210f9a989e8f68b';resume_msr_guid='e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10';resume_name='resume-1234'}
        Assert-HostDismResumeRequest -Case $case -Job $job
        foreach($key in @('mode','resume_image_sha256','resume_msr_guid','resume_name')) {
          $before=$job[$key];$job[$key]='wrong';$failed=$false
          try {Assert-HostDismResumeRequest -Case $case -Job $job} catch {$failed=$true}
          $job[$key]=$before;if(-not $failed){throw ('bad '+$key+' accepted')}
        }
        $failed=$false;try {Assert-HostDismResumeRequest -Case 'K:\x\other' -Job $job} catch {$failed=$true}
        if(-not $failed){throw 'wrong case accepted'}
        '''
        powershell(script)


if __name__=='__main__': unittest.main()
