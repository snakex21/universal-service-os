"""Build the isolated experimental NT31 full-MAC; no VM and no shared output."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser();p.add_argument('--wdk',required=True,type=Path);p.add_argument('--out',required=True,type=Path)
    p.add_argument('--zig',type=Path,default=ROOT.parent/'dokumentacja-9x/tools/zig/zig.exe')
    a=p.parse_args();out=a.out.resolve();wdk=a.wdk.resolve()
    if out.exists() or not out.is_relative_to(ROOT/'artifacts'):raise ValueError('Fresh owned artifacts directory required')
    if not (wdk/'bin/setenv.bat').is_file() or not re.fullmatch(r'[A-Za-z0-9_:\\./-]+',str(wdk)):raise ValueError('Existing safe WDK7.1 path required')
    protected={str(p):sha(p) for tree,leaf in [('nt351-net','usosnet4.sys'),('nt351-net','usosnet.sys'),('nt351-net','usosnet351.sys'),('nt35-net','usosnet35.sys')] for p in [ROOT.parent/tree/'tools/nt/usosnet/bin/i386'/leaf]}
    out.mkdir(parents=True);tmp=out/'tmp';tmp.mkdir();src=out/'src';src.mkdir()
    inputs={}
    for folder,names in [('src',('usosnet.h','usosnet_proto.h','usosnet_irq.h','usosnet_igb.c','makefile')),('src31',('usosnet31.h','usosnet31.c','u31_policy.h','policy_test.c','net31cfg.c','igb31.c','sources','legacy_imports.json'))]:
        for name in names:
            source=HERE/folder/name;shutil.copy(source,src/name);inputs[folder+'/'+name]=sha(source)
    # Own import library: public names/stdcall sizes, no MS code.
    legacy=json.loads((HERE/'src31/legacy_imports.json').read_text(encoding='utf-8'))
    measured=json.loads((ROOT/'artifacts/nt31-fullmac-contract/lifecycle-06.json').read_text(encoding='utf-8'))['modules']['ndis.sys']['exports_rva']
    if not set(legacy)<=set(measured):raise ValueError('Legacy import absent in original NDIS')
    definition=out/'ndis31.def'
    definition.write_bytes(('LIBRARY NDIS.SYS\nEXPORTS\n'+''.join(name+'@'+str(size)+'\n' for name,size in legacy.items())).encode('ascii'))
    lib=out/'ndis31.lib'
    if not a.zig.is_file():raise ValueError('Existing zig lib required for short COFF archive')
    env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),PYTHONDONTWRITEBYTECODE='1',ZIG_GLOBAL_CACHE_DIR=str(tmp/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(tmp/'zig-local'))
    subprocess.run([str(a.zig),'dlltool','-m','i386','-k','-d',str(definition),'-l',str(lib)],check=True,capture_output=True,env=env)
    sources=(src/'sources').read_text(encoding='utf-8').replace('TARGETLIBS=$(DDK_LIB_PATH)\\ndis.lib','TARGETLIBS='+str(lib)+' $(DDK_LIB_PATH)\\ndis.lib')
    (src/'sources').write_bytes(sources.encode('utf-8'))
    script=out/'build.cmd'
    script.write_bytes((f'@echo off\ncall "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr\nif errorlevel 1 exit /b 2\ncd /d "{src}"\nset "BUILD_ALT_DIR=fre"\nbuild -cZ\nif not exist objfre\\i386\\usosnet31.sys exit /b 3\n'
        f'cl /nologo /c /W3 /O2 /Gd /GS- /Zl /Fopolicy_test.obj policy_test.c\nif errorlevel 1 exit /b 4\nlink /nologo /nodefaultlib /entry:entry /subsystem:console /machine:x86 /out:"{out}\\policy-test.exe" policy_test.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib"\nif errorlevel 1 exit /b 5\n'
        f'cl /nologo /c /W3 /O1 /Gd /GS- /Zl /DWIN32 /D_WIN32_WINNT=0x0400 /DWINVER=0x0400 /I"{wdk}\\inc\\api" /I"{wdk}\\inc\\crt" /Fonet31cfg.obj net31cfg.c\nif errorlevel 1 exit /b 6\nlink /nologo /nodefaultlib /entry:entry /subsystem:console /machine:x86 /out:"{out}\\NET31CFG.EXE" net31cfg.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib" "{wdk}\\lib\\wxp\\i386\\advapi32.lib"\nif errorlevel 1 exit /b 7\n').encode('utf-8'))
    r=subprocess.run(['cmd','/d','/c',str(script)],env=env,capture_output=True)
    (out/'build-output.txt').write_bytes((r.stdout+r.stderr).decode('mbcs',errors='replace').encode('utf-8'))
    if {p:sha(Path(p)) for p in protected}!=protected:raise ValueError('Protected other OS binaries changed')
    if r.returncode:raise RuntimeError('Build failed: '+str(out/'build-output.txt'))
    host=subprocess.run([str(out/'policy-test.exe')],env=env,capture_output=True,timeout=10)
    if host.returncode:raise RuntimeError('Actual policy test failed at C source line '+str(host.returncode))
    binary=out/'usosnet31.sys';shutil.copy(src/'objfre/i386/usosnet31.sys',binary)
    for image in (binary,out/'NET31CFG.EXE'):
        subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/nt4/pe_nt4_version.py'),'--version','3.10',str(image)],env=env,check=True,capture_output=True)
    helper=out/'NET31CFG.EXE'
    refused=subprocess.run([str(helper),'/configure'],env=env,capture_output=True,timeout=10)
    if refused.returncode!=3 or b'REFUSED_OS' not in (out/'CFG31.LOG').read_bytes():raise RuntimeError('Host configurator OS guard failed')
    result=dict(scope='Experimental NT31 full-MAC 3.0 UP/QEMU 82576 only; no runtime PASS',binary=str(binary),sha256=sha(binary),size=binary.stat().st_size,source_sha256=inputs,protected_binaries=protected,protected_binaries_unchanged=True,host_policy_cases=38,host_policy_pass=True,helper_sha256=sha(helper),helper_size=helper.stat().st_size,helper_host_os_refusal_pass=True,runtime_pass=False)
    (out/'build.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
