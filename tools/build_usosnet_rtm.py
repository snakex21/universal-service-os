"""Build the separate NDIS 3.0 usosnet4 variant; existing binaries stay intact.

Uses the locally installed mingw-w64 DDK declarations and Zig/LLVM. Two
bounded header corrections reconcile the installed DDK with ntddndis.h;
the copied headers, objects and caches stay under the explicit output dir.
No Microsoft driver or source is copied into the project.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess

def build(root, out, zig, include, objdump):
    root,out,zig,include,objdump=[p.resolve() for p in (root,out,zig,include,objdump)]
    out.mkdir(parents=True,exist_ok=True)
    original=(include/'ddk/ndis.h').read_bytes()
    header=original.decode().replace('\r\n','\n')
    old='NdisMWanIndicateReceiveComplete(\n\tIN NDIS_HANDLE  MiniportAdapterHandle\n'
    if old in header: header=header.replace(old,old.rstrip('\n')+',\n',1)
    header,n=re.subn(r'typedef enum _NDIS_REQUEST_TYPE \{.*?\} NDIS_REQUEST_TYPE, \*PNDIS_REQUEST_TYPE;',
        '/* NDIS_REQUEST_TYPE is supplied by ntddndis.h. */',header,flags=re.S)
    if n!=1:raise ValueError('Unrecognized mingw-w64 DDK request declaration')
    (out/'ndis.h').write_text(header)
    (out/'compat.h').write_text('#include <intrin.h>\n#include <ndis.h>\n'
        '#define NDIS_STRING_CONST(x) {sizeof(L##x)-sizeof(WCHAR),sizeof(L##x),L##x}\n'
        'NDISAPI NDIS_STATUS NTAPI NdisMPciAssignResources(NDIS_HANDLE,ULONG,PNDIS_RESOURCE_LIST *);\n')
    env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(out/'cache/global'),
        ZIG_LOCAL_CACHE_DIR=str(out/'cache/local'),TMP=str(out),TEMP=str(out))
    def run(args):
        r=subprocess.run([str(x) for x in args],env=env,capture_output=True,text=True)
        with (out/'build.log').open('a') as log:log.write(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError('Build failed; see '+str(out/'build.log'))
        return r.stdout
    (out/'build.log').write_text('')
    objects=[]
    for leaf in ('usosnet','usosnet_igb'):
        obj=out/(leaf+'.obj');objects.append(obj)
        run([zig,'cc','-target','x86-windows-gnu','-I',out,'-I',include/'ddk','-I',include,
            '-include',out/'compat.h','-DNDIS_MINIPORT_DRIVER=1','-DNDIS50_MINIPORT=1',
            '-DUSOSNET_NDIS4=1','-DUSOSNET_NDIS31=1','-DBINARY_COMPATIBLE=0',
            '-DEXPORT=__declspec(dllimport) __stdcall','-ffreestanding','-fno-builtin',
            '-fno-stack-protector','-fms-extensions','-mrtd','-mcpu=i586',
            '-mno-sse','-mno-sse2','-mno-mmx','-msoft-float','-Os',
            '-c',root/'tools/nt/usosnet/src'/ (leaf+'.c'),'-o',obj])
    names=set()
    for obj in objects:
        symbols=run([objdump,'-t',obj])
        names.update(re.findall(r'\(sec  0\).* __imp__([A-Za-z0-9]+(?:@\d+)?)\s*$',symbols,re.M))
    if not names or any(not n.startswith(('Ndis','EthFilter')) for n in names):
        raise ValueError('Unexpected driver import module')
    definition=out/'ndis.def'
    definition.write_text('LIBRARY NDIS.SYS\nEXPORTS\n'+'\n'.join(sorted(names))+'\n')
    library=out/'ndis.lib'
    run([zig,'dlltool','-m','i386','-k','-d',definition,'-l',library])
    driver=out/'usosnet4.sys'
    run([objdump.with_name('ld.exe'),'-m','i386pe',*objects,library,
         '--subsystem','native','--entry','_DriverEntry@8','--image-base','0x10000',
         '--file-alignment','128','--section-alignment','128',
         '--major-subsystem-version','4','--minor-subsystem-version','0',
         '--major-os-version','4','--minor-os-version','0','--no-insert-timestamp',
         '--disable-dynamicbase','--disable-nxcompat',
         '-o',driver])
    manifest={'kind':'NDIS3_VARIANT_RUNTIME_UNVERIFIED','source':'own usosnet shared core + igb',
        'driver_sha256':hashlib.sha256(driver.read_bytes()).hexdigest(),
        'ndis_header_sha256':hashlib.sha256(original).hexdigest(),
        'imports':sorted(n.split('@')[0] for n in names),'toolchain':'Zig cc + mingw-w64 DDK',
        'source_sha256':{obj.stem:hashlib.sha256((root/'tools/nt/usosnet/src'/(obj.stem+'.c')).read_bytes()).hexdigest() for obj in objects}}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return driver

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project-root',type=Path,required=True)
    p.add_argument('--output-dir',type=Path,required=True)
    p.add_argument('--zig',type=Path,required=True)
    p.add_argument('--mingw-include',type=Path,default=Path(r'C:\msys64\mingw64\include'))
    p.add_argument('--objdump',type=Path,default=Path(r'C:\msys64\mingw64\bin\objdump.exe'))
    a=p.parse_args()
    print(build(a.project_root,a.output_dir,a.zig,a.mingw_include,a.objdump))
