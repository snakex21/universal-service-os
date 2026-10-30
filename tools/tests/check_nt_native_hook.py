# SPDX-License-Identifier: GPL-3.0-or-later
"""Execute the compiled resident hook for the new NT31/NT4 caps; RAM only."""
from pathlib import Path
import argparse,hashlib,importlib.util,json

ROOT=Path(__file__).resolve().parents[2]
def main():
    p=argparse.ArgumentParser();p.add_argument('--hook',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    spec=importlib.util.spec_from_file_location('native_hook_machine',ROOT/'tools/tests/legacy_bios/test_nt3_e820_hook.py')
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    case=mod.Nt3E820Hook();case.hook=a.hook.read_bytes();results=[]
    for cap in (4,64):
        size=cap*16*1024*1024
        for function in (0x8800,0xe801):
            ax,bx,cx,dx,cf=case.old_sizes(function,mod.BIG_MAP,cap=cap)
            assert (ax,cf)==(0x3c00,0)
            if function==0xe801:
                assert cx==ax and bx==dx==(size-16*1024*1024)//65536
            results.append({'cap_mib':cap*16,'function':hex(function),'ax':ax,'bx':bx,'cf':cf})
        for base,length,kind in mod.BIG_MAP:
            (b,n,k),cf=case.e820(base,length,kind,cap=cap)
            assert cf==0 and (k!=1 or b+n<=size)
        assert case.e820(0xa0000,0x60000,2,cap=cap)[0]==(0xf0000,0x10000,2)
    result={'method':'Actual x86 INT15 resident code executed in Unicorn, not QEMU/hardware',
        'hook_sha256':hashlib.sha256(case.hook).hexdigest(),'old_size_cases':results,
        'e820_cap_and_video_cases':2*(len(mod.BIG_MAP)+1),'pass':True}
    a.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
