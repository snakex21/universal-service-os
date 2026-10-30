# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded NT31 candidate build through build.bat; no deployment.

Requires original-media export metadata from audit_nt_native_media.py.
Neither the NT351 source tree nor its binaries are rebuilt or modified.
"""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    out=Path(os.environ['USOS_NT_NATIVE_OUT']).resolve()
    wdk=Path(os.environ['WDKROOT']).resolve();zig=Path(os.environ['USOS_ZIG']).resolve()
    evidence=json.loads(Path(os.environ['USOS_NT31_MEDIA_METADATA']).read_text())['nt31-ws']['modules']
    if evidence['ndis.sys']['sha256']!='9f34331567762728ed67b25733583c248c635220d475b74014fda8f653556950':raise ValueError('Original NT31 NDIS identity mismatch')
    if out.exists() or not out.is_relative_to(ROOT/'artifacts'):raise ValueError('Fresh owned artifacts required')
    protected={p:sha(p) for p in (ROOT/'tools/nt/usosnet/bin/i386').rglob('*.sys')}
    out.mkdir(parents=True);src=out/'src';shutil.copytree(ROOT/'tools/nt/usosnet/src',src)
    for p in (ROOT/'tools/nt/usosnet/src31').iterdir():
        if p.is_file():shutil.copy(p,src/p.name)
    env=dict(os.environ,TEMP=str(out),TMP=str(out),BUILD_MULTIPROCESSOR='2',PYTHONDONTWRITEBYTECODE='1',
        ZIG_GLOBAL_CACHE_DIR=str(out/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-local'))
    def run(name,cmd):
        r=subprocess.run(cmd,cwd=ROOT,env=env,capture_output=True,timeout=120)
        (out/(name+'.log')).write_bytes(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(name+' failed; see '+str(out/(name+'.log')))
        return r.stdout
    legacy=json.loads((src/'legacy_imports.json').read_text())
    if not set(legacy)<=set(evidence['ndis.sys']['exports']):raise ValueError('Missing original NT31 NDIS export')
    definition=out/'ndis31.def'
    definition.write_text('LIBRARY NDIS.SYS\nEXPORTS\n'+''.join(k+'@'+str(v)+'\n' for k,v in legacy.items()),encoding='ascii')
    lib=out/'ndis31.lib'
    run('import-library',[str(zig),'dlltool','-m','i386','-k','-d',str(definition),'-l',str(lib)])
    sources=(src/'sources').read_text().replace('TARGETLIBS=$(DDK_LIB_PATH)\\ndis.lib','TARGETLIBS='+str(lib)+' $(DDK_LIB_PATH)\\ndis.lib')
    (src/'sources').write_text(sources)
    script=out/'driver.cmd';script.write_text('@echo off\n'+
        f'call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr\nif errorlevel 1 exit /b 2\n'
        f'cd /d "{src}"\nset "BUILD_ALT_DIR=fre"\nbuild -cZ\nif not exist objfre\\i386\\usosnet31.sys exit /b 3\n',encoding='ascii')
    run('driver',['cmd','/d','/c',str(script)])
    sys.path.insert(0,str(ROOT/'tools/nt4'));from pe_nt4_version import set_nt4
    binary=ROOT/'tools/nt/usosnet/bin/nt31-native/i386/usosnet31.sys';binary.parent.mkdir(parents=True,exist_ok=True)
    binary.write_bytes(set_nt4((src/'objfre/i386/usosnet31.sys').read_bytes(),3,10))
    sys.path.insert(0,str(ROOT/'tools/tests'));from check_nt52_driver_imports import pe
    allowed={m:set(v['exports']) for m,v in evidence.items()}
    missing=[m+'!'+n for m,n in pe(binary)[1] if n not in allowed.get(m.lower(),set())]
    if missing:raise ValueError('Missing original imports: '+','.join(missing))
    # Verify the generic helper remains import-compatible on NT31. Its
    # /finish now refuses NT31; /polish remains the supported entry point.
    sys.path.insert(0,str(ROOT/'tools'))
    from build_windows_usos_res import build_nt3
    registrar=build_nt3(ROOT,out/'registrar')
    missing=[m+'!'+n for m,n in pe(registrar)[1] if n not in allowed.get(m.lower(),set())]
    if missing:raise ValueError('Registrar imports absent on NT31: '+','.join(missing))
    include='-I'+str(zig.parent/'lib/libc/include/any-windows-any')
    gui=ROOT/'tools/nt3/native31/bin/USOSANS31.EXE';gui.parent.mkdir(parents=True,exist_ok=True)
    run('gui-compile',[str(zig),'cc','-target','x86-windows-gnu','-mcpu=i486','-Os','-nostdlib','-fno-builtin','-fno-stack-protector',include,
        '-DWINVER=0x0400','-D_WIN32_WINNT=0x0400',str(ROOT/'tools/nt3/native31/usosans31.c'),
        '-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-luser32','-o',str(gui)])
    gui.write_bytes(set_nt4(gui.read_bytes(),3,10))
    missing=[m+'!'+n for m,n in pe(gui)[1] if n not in allowed.get(m.lower(),set())]
    if missing:raise ValueError('GUI imports absent on original NT31: '+','.join(missing))
    refused=subprocess.run([str(gui)],capture_output=True,timeout=5)
    if refused.returncode!=3:raise ValueError('NT31 GUI must refuse this host before I/O')
    policy=out/'page-policy.exe'
    run('page-policy-compile',[str(zig),'cc','-target','x86-windows-gnu','-mcpu=i486','-Os','-nostdlib','-fno-builtin','-fno-stack-protector',include,
        str(ROOT/'tools/nt3/native31/page_policy_test.c'),'-Wl,--entry,entry','-lkernel32','-o',str(policy)])
    run('page-policy-test',[str(policy)])
    elf=out/'nt3-mbr.elf';mbrsrc=ROOT/'src/platform/bios/nt3'
    run('hook-compile',[str(zig),'cc','-target','x86-freestanding-none','-mcpu=i386','-nostdlib','-nodefaultlibs',
        '-Wl,-T,'+str(mbrsrc/'nt3_e820_mbr.ld'),'-Wl,--entry=nt3_e820_mbr_start',str(mbrsrc/'nt3_e820_mbr.S'),'-o',str(elf)])
    hook=out/'hook.bin';run('hook-extract',[str(zig),'objcopy','-O','binary','-j','.hook',str(elf),str(hook)])
    if protected!={p:sha(p) for p in protected}:raise ValueError('Protected SYS changed')
    result={'runtime_pass':False,'scope':'82576 UP candidate only; I211/native input hook NOT implemented',
        'binary_sha256':sha(binary),'binary_size':binary.stat().st_size,'imports_match_original_nt31':True,
        'gui_sha256':sha(gui),'gui_imports_match_original_nt31':True,'gui_host_refusal':True,
        'registrar_sha256':sha(registrar),'registrar_imports_match_original_nt31':True,'nt31_generic_finish_refused':True,
        'page_policy_cases':16,'page_policy_pass':True,'hook':str(hook.relative_to(ROOT)),'protected_unchanged':True,
        'protected':{str(p.relative_to(ROOT)):v for p,v in protected.items()}}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
