#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded NT4 preparation build, entered only through build.bat.

No release/signing step and no shared SYS overwritten. Caller holds the
project's global build.lock. WDK and Zig are explicit existing toolchains.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import re

ROOT = Path(__file__).resolve().parents[1]

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    if os.environ.get('USOS_NT_NATIVE_PREP') != '4':
        raise ValueError('Only the explicit NT4 preparation target is supported')
    out = Path(os.environ['USOS_NT_NATIVE_OUT']).resolve()
    wdk = Path(os.environ['WDKROOT']).resolve()
    zig = Path(os.environ['USOS_ZIG']).resolve()
    if out.exists() or not out.is_relative_to(ROOT / 'artifacts'):
        raise ValueError('Fresh artifacts directory in this worktree required')
    if not (wdk/'bin/setenv.bat').is_file() or not zig.is_file():
        raise ValueError('Existing WDK7.1 and Zig required')
    protected = {p: sha(p) for p in (ROOT/'tools/nt/usosnet/bin/i386').rglob('*.sys')}
    out.mkdir(parents=True)
    env = dict(os.environ, TEMP=str(out), TMP=str(out), PYTHONDONTWRITEBYTECODE='1',
        ZIG_GLOBAL_CACHE_DIR=str(out/'zig-global'), ZIG_LOCAL_CACHE_DIR=str(out/'zig-local'),
        BUILD_MULTIPROCESSOR='2')
    def run(name, command):
        r = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=120)
        (out/(name+'.log')).write_bytes(r.stdout+r.stderr)
        if r.returncode:
            raise RuntimeError(name+' failed; see '+str(out/(name+'.log')))
        return r.stdout
    src = out/'src'
    shutil.copytree(ROOT/'tools/nt/usosnet/src', src)
    shutil.copy(ROOT/'tools/nt/usosnet/src4/usosnet4.rc', src/'usosnet4.rc')
    shutil.copy(ROOT/'tools/nt/usosnet/srcnt4/sources', src/'sources')
    # Compile-time isolation proof, not merely an unchanged committed SYS:
    # preprocess exactly the NT351 configuration before/after at one path.
    shared = src/'usosnet.c'
    current = shared.read_bytes()
    old = subprocess.check_output(['git','show','2d7f2a23:tools/nt/usosnet/src/usosnet.c'],cwd=ROOT,timeout=10)
    cpp_script=out/'cpp.cmd'
    cpp_script.write_text('@echo off\n'+
        f'call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr >nul 2>&1\n'+
        f'cl /nologo /EP /D_X86_=1 /DNDIS_MINIPORT_DRIVER=1 /DNDIS50_MINIPORT=1 /DUSOSNET_NDIS4=1 /DUSOSNET_NT351=1 '
        f'/I"{wdk}/inc/ddk" /I"{wdk}/inc/api" /I"{wdk}/inc/crt" "{shared}"\n',encoding='ascii')
    cpp = ['cmd','/d','/c',str(cpp_script)]
    try:
        shared.write_bytes(old); before = run('nt351-cpp-before',cpp)
        shared.write_bytes(current); after = run('nt351-cpp-after',cpp)
    finally:
        shared.write_bytes(current)
    # /EP preserves source blank lines. Only omit empty/indentation-only
    # lines; every nonempty preprocessed line must remain byte-identical.
    normalize=lambda data: b'\n'.join(line.strip() for line in data.splitlines() if line.strip())
    if normalize(before) != normalize(after): raise ValueError('NT351 preprocessed compilation input changed')
    cpp_sha = hashlib.sha256(normalize(after)).hexdigest()
    script = out/'driver.cmd'
    script.write_text('@echo off\n'+f'call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr\n'
        f'if errorlevel 1 exit /b 2\ncd /d "{src}"\nset "BUILD_ALT_DIR=fre"\nbuild -cZ\n'
        'if not exist objfre\\i386\\usosnet4.sys exit /b 3\n', encoding='ascii')
    run('driver', ['cmd','/d','/c',str(script)])
    sys.path.insert(0, str(ROOT/'tools/nt4'))
    from pe_nt4_version import set_nt4
    destinations = {}
    binary = ROOT/'tools/nt/usosnet/bin/nt4/i386/usosnet4.sys'
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(set_nt4((src/'objfre/i386/usosnet4.sys').read_bytes(),4,0))
    destinations[str(binary.relative_to(ROOT))] = sha(binary)
    helper_dir = ROOT/'tools/nt4/usosfinish/bin/i386'
    helper_dir.mkdir(parents=True, exist_ok=True)
    for name, source, libs, defs in (
        ('USOSNT4.EXE', 'tools/nt4/usosfinish/usosfinish.c', ['-lkernel32','-ladvapi32'], []),
        ('USOSANS4.EXE', 'tools/nt3/usosans3/usosans3.c', ['-lkernel32','-luser32'], ['-DUSOSANS_NT4=1']),
    ):
        target = helper_dir/name
        run(name, [str(zig),'cc','-target','x86-windows-gnu','-mcpu=i586','-Os','-nostdlib',
            '-fno-builtin','-fno-stack-protector','-I'+str(zig.parent/'lib/libc/include/any-windows-any'),
            '-DWINVER=0x0400','-D_WIN32_WINNT=0x0400',
            *defs,str(ROOT/source),'-Wl,--entry,entry','-Wl,--subsystem,windows',*libs,'-o',str(target)])
        target.write_bytes(set_nt4(target.read_bytes(),4,0))
        destinations[str(target.relative_to(ROOT))] = sha(target)
    # Exercise the actual production formatter and durability guards with
    # every file API replaced by an in-memory model. Never a host C: test.
    def function(text,name):
        lines=text.splitlines()
        start=next(i for i,line in enumerate(lines) if line.startswith('static ') and
            re.search(r'\b'+re.escape(name)+r'\(',line) and not line.rstrip().endswith(';'))
        end=next(i for i in range(start,len(lines)) if lines[i]=='}')
        return '\n'.join(lines[start:end+1])+'\n'
    nt3=(ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_text()
    nt4=(ROOT/'tools/nt4/usosfinish/usosfinish.c').read_text()
    helpers=''.join(function(nt3,n) for n in ('read_small','copy_bytes','lower','has_ci','native_options','out_add','drop_maxmem'))
    helpers+=''.join(function(nt4,n) for n in ('finish_create','finish_flush','boot_valid','finish_delete'))
    (out/'finish_helpers_actual.inc').write_text(helpers)
    (out/'finish_boot_actual.inc').write_text(function(nt3,'boot_ini_finish')+function(nt4,'finish_boot'))
    harness=out/'finish-test.exe'
    run('finish-test-compile',[str(zig),'cc','-target','x86-windows-gnu','-mcpu=i586','-Os','-nostdlib',
        '-fno-builtin','-fno-stack-protector','-I'+str(zig.parent/'lib/libc/include/any-windows-any'),'-I'+str(out),
        str(ROOT/'tools/tests/native_nt4_finish_test.c'),'-Wl,--entry,entry','-lkernel32','-o',str(harness)])
    run('finish-test',[str(harness)])
    if protected != {p:sha(p) for p in protected}:
        raise ValueError('Protected shared/NT351 SYS changed')
    result = {'outputs':destinations,'protected_unchanged':True,'nt351_preprocessed_identical':True,
        'nt351_preprocessed_sha256':cpp_sha,'finish_contract_cases':7,'finish_contract_pass':True,
        'protected':{str(p.relative_to(ROOT)):s for p,s in protected.items()}, 'runtime_pass':False}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))

if __name__ == '__main__':
    main()
