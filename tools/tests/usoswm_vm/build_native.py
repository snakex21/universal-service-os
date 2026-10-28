"""SPDX-License-Identifier: GPL-3.0-or-later
Build the own lab-only RDP host using the installed Windows ActiveX runtime.
No Microsoft DLL/type-library binary is copied into the output directory.
"""
from pathlib import Path
import argparse,hashlib,json,os,subprocess

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--tool-root',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();tools=args.tool_root.resolve();out=args.out.resolve()
    out.mkdir(parents=True,exist_ok=True);temp=out/'tmp';temp.mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(temp),TMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(out/'global'),ZIG_LOCAL_CACHE_DIR=str(out/'local'))
    zig=tools/'zig/zig.exe'
    if subprocess.check_output([str(zig),'version'],text=True).strip()!='0.16.0':raise ValueError('Pinned Zig 0.16.0 required')
    source=Path(__file__).resolve().with_name('native_client.c');target=out/'native-client.exe'
    command=[str(zig),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-Wno-missing-declarations','-I'+str(tools/'zig/lib/libc/include/any-windows-any'),str(source),'-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-luser32','-lgdi32','-lole32','-loleaut32','-lshell32','-o',str(target)]
    with (out/'build.log').open('wb') as log:subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    (out/'manifest.json').write_text(json.dumps({'toolchain':'Zig 0.16.0','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'purpose':'lab-only; requires installed MsRdpClient9 ActiveX'},indent=2))
    print(target,flush=True)

if __name__=='__main__':main()
