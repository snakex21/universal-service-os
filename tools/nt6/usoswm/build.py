"""SPDX-License-Identifier: GPL-3.0-or-later
Build only our user-mode component with the repository's pinned Zig 0.16.0.
All caches and temporary files are local to the supplied output directory.
"""
from pathlib import Path
import argparse,hashlib,json,os,subprocess

def build(tool_root:Path,out:Path):
    source=Path(__file__).resolve().parent
    zig=tool_root/'zig/zig.exe'
    version=subprocess.check_output([str(zig),'version'],text=True).strip()
    if version!='0.16.0':raise ValueError('Expected repository Zig 0.16.0, got '+version)
    out=out.resolve();out.mkdir(parents=True,exist_ok=True)
    temp=out/'tmp';temp.mkdir(exist_ok=True)
    env=dict(os.environ,TMP=str(temp),TEMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(out/'cache/global'),ZIG_LOCAL_CACHE_DIR=str(out/'cache/local'))
    common=[str(zig),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-Wno-missing-declarations','-I'+str(tool_root/'zig/lib/libc/include/any-windows-any'),'-I'+str(source)]
    runtime=str(source/'runtime.c')
    dll=out/'usoswm-desktop.dll';exe=out/'usoswm.exe';register=out/'usoswm-register.exe'
    commands=[common+['-shared',str(source/'desktop.c'),runtime,'-Wl,--entry,DllMain','-lkernel32','-luser32','-lgdi32','-ladvapi32','-lole32','-o',str(dll)],
              common+[str(source/'launcher.c'),runtime,'-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-luser32','-o',str(exe)],
              common+[str(source/'register.c'),runtime,'-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-luser32','-ladvapi32','-lshell32','-lole32','-o',str(register)]]
    with (out/'build.log').open('w',encoding='utf-8') as log:
        for command in commands:subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    manifest={'status':'experimental-unvalidated','target':'Vista/Server 2008 SP2 x64, testsigning ON only','toolchain':'Zig '+version,'files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (dll,exe,register)}}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print('Built own user-mode component; VM acceptance still required',flush=True)
    return manifest
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--tool-root',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();build(a.tool_root,a.out)
