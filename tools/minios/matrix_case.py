"""One bounded, sequential six-case firmware/independent-verification run.

Each operation waits for actual completion. There are no progress probes;
reruns require a fresh workspace, not overwriting previous evidence.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--workspace',type=Path,required=True)
    p.add_argument('--qemu-dir',type=Path,required=True)
    p.add_argument('--source-root',type=Path,required=True)
    args=p.parse_args()
    repo=Path(__file__).resolve().parents[2]
    root=args.workspace.resolve(); cases=root/'cases'; oracle=root/'oracle'
    api=load('matrix_firmware',Path(__file__).with_name('uefi_case.py'))
    v=load('matrix_verify',Path(__file__).with_name('verify_case.py'))
    api.configure(cases,args.qemu_dir)
    v.configure(cases,oracle,args.qemu_dir,args.source_root)
    results=[]
    for arch in ('x64','ia32','bios'):
        for kind in ('gpt','mbr'):
            case=cases/f'final-{arch}-{kind}'
            target={'x64':'x86_64','ia32':'ia32','bios':'bios'}[arch]
            program=repo/'zig-out/test-assets'/('usosprep-bios.img' if arch=='bios' else f'usosprep-{target}.efi')
            api.prepare(case,target,kind,program,2*1024**3)
            if not api.execute(case,64,600): raise ValueError('Firmware failed: '+case.name)
            result=v.verify(case,True); results.append(result)
            if not result['linux'] or not result['readonly_chkdsk_pass']:
                raise ValueError('Independent verification failed: '+case.name)
            print('COMPLETED '+case.name,flush=True)
    v.write_json(oracle/'matrix-completed.json',{'qemu_only':True,'cases':results,'passed':True})
    print(json.dumps({'cases':len(results),'passed':True}))

if __name__=='__main__': main()
