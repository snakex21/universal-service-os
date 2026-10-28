"""Dynamic negative tests: every case must fail BEFORE conversion or mount."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess

def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as f:
        while data:=f.read(1024*1024): digest.update(data)
    return digest.hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--workspace',type=Path,required=True);p.add_argument('--qemu-dir',type=Path,required=True)
    a=p.parse_args();root=a.workspace.resolve()
    if root==Path(root.anchor) or root.exists():raise ValueError('A new explicit fixture workspace is required')
    root.mkdir(parents=True)
    source=root/'source.raw'; receipt=root/'result.json'; rows=[]
    try:
        with source.open('xb') as f:f.truncate(64*1024*1024)
        source.chmod(stat.S_IREAD); original=sha(source)
        shell=shutil.which('pwsh.exe')
        if not shell:raise ValueError('PowerShell7 required')
        script=Path(__file__).resolve().with_name('minios_chkdsk_readonly.ps1')
        tests=[('physical-device',r'\\.\PhysicalDrive0',64*1024*1024,original,'Only a file below'),
               ('wrong-size',str(source),65*1024*1024,original,'Exact expected image size differs'),
               ('wrong-sha',str(source),64*1024*1024,'0'*64,'Raw copy SHA-256 differs'),
               ('writable-source',str(source),64*1024*1024,original,'read-only attribute')]
        for name,path,size,expected,error in tests:
            if name=='writable-source':source.chmod(stat.S_IREAD|stat.S_IWRITE)
            output=root/name
            args=[shell,'-NoLogo','-NoProfile','-File',str(script),'-Workspace',str(root),'-RawCopy',path,'-ExpectedImageBytes',str(size),'-ExpectedSha256',expected,'-QemuImg',str(a.qemu_dir/'qemu-img.exe'),'-Out',str(output)]
            # These guard paths never launch a subprocess or attach a disk.
            result=subprocess.run(args,capture_output=True,text=True,encoding='utf-8',errors='replace',check=False)
            text=result.stdout+result.stderr
            passed=result.returncode!=0 and error in text and not output.exists() and sha(source)==original
            rows.append({'test':name,'passed':passed,'exit':result.returncode,'out_created':output.exists(),'stdout':result.stdout,'stderr':result.stderr})
            if not passed:raise AssertionError('Pre-mount guard failed: '+name)
        receipt.write_text(json.dumps({'passed':True,'tests':rows,'source_sha256':original,'mount_or_conversion_reached':False},indent=2)+'\n')
        print(json.dumps({'passed':True,'tests':len(rows),'result':str(receipt)}))
    finally:
        if source.exists():source.chmod(stat.S_IREAD|stat.S_IWRITE);source.unlink()

if __name__=='__main__':main()
