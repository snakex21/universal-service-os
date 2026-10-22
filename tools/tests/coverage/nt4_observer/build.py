"""Reproducible own GUI test helper; no download, console, driver or profile writes."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,struct,subprocess
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
def main():
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--zig',type=Path,required=True);a=p.parse_args()
 out=a.out.resolve()
 if not out.is_relative_to(ROOT/'artifacts') or out.exists():raise ValueError('Fresh own artifacts output required')
 out.mkdir(parents=True);tmp=out/'tmp';tmp.mkdir()
 env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),ZIG_GLOBAL_CACHE_DIR=str(out/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-local'))
 exe=out/'NT4OBS.EXE'
 subprocess.run([str(a.zig),'cc','-target','x86-windows-gnu','-mcpu=i586','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-fms-extensions','-Wall','-Wextra','-Werror','-isystem',str(a.zig.parent/'lib/libc/include/any-windows-any'),str(HERE/'observer.c'),'-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-ladvapi32','-o',str(exe)],env=env,check=True)
 spec=importlib.util.spec_from_file_location('observer_pe',ROOT/'tools/nt4/pe_nt4_version.py');pe=importlib.util.module_from_spec(spec);spec.loader.exec_module(pe)
 data=bytearray(exe.read_bytes());offset=struct.unpack_from('<I',data,0x3c)[0];data[offset+8:offset+12]=b'\0'*4;exe.write_bytes(pe.set_nt4(bytes(data),4,0))
 record=dict(exe=str(exe),sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),source={n:hashlib.sha256((HERE/n).read_bytes()).hexdigest() for n in ('observer.c','observer_core.h','build.py')},runtime_pass=False)
 (out/'build.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record,indent=2))
if __name__=='__main__':main()
