"""Build only the portable NT31 service-policy helper, never rebuild the SYS."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
PIN='b49f2445a2e48dbf75b50f426ccc1cef09943a84e779d351747d4cbc8df27a8d'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args();out=a.out.resolve()
    if out.exists() or not out.is_relative_to(ROOT/'artifacts/nt31-client-policy'):raise ValueError('Fresh owned helper build only')
    driver=ROOT/'artifacts/nt31-fullmac-build/build16/usosnet31.sys'
    if sha(driver)!=PIN:raise ValueError('Existing frozen SYS required')
    protected=[driver,ROOT.parent/'nt351-net/tools/nt/usosnet/bin/i386/usosnet4.sys',ROOT.parent/'nt351-net/tools/nt/usosnet/bin/i386/usosnet.sys',ROOT.parent/'nt351-net/tools/nt/usosnet/bin/i386/usosnet351.sys',ROOT.parent/'nt35-net/tools/nt/usosnet/bin/i386/usosnet35.sys']
    before={str(f):sha(f) for f in protected};out.mkdir(parents=True);src=out/'src';src.mkdir();tmp=out/'tmp';tmp.mkdir()
    inputs={}
    for name in ('net31cfg.c','cfg31_policy.h','client31_policy.h','client31_win32.h','client31_test.c'):
        f=HERE/'src31'/name;shutil.copyfile(f,src/name);inputs[name]=sha(f)
    wdk=ROOT.parent.parent/'Desktop/universal-service-os/tools/WinDDK71'
    if not (wdk/'bin/setenv.bat').is_file():raise ValueError('Existing WDK required')
    script=out/'build.cmd'
    script.write_bytes((f'@echo off\ncall "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr\nif errorlevel 1 exit /b 2\ncd /d "{src}"\n'
        f'cl /nologo /c /W3 /O1 /Gd /GS- /Zl /DWIN32 /D_WIN32_WINNT=0x0400 /DWINVER=0x0400 /I"{wdk}\\inc\\api" /I"{wdk}\\inc\\crt" /Fonet31cfg.obj net31cfg.c\nif errorlevel 1 exit /b 3\n'
        f'link /nologo /nodefaultlib /entry:entry /subsystem:console /machine:x86 /out:"{out}\\NET31CFG.EXE" net31cfg.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib" "{wdk}\\lib\\wxp\\i386\\advapi32.lib"\nif errorlevel 1 exit /b 4\n'
        f'cl /nologo /c /W3 /O1 /Gd /GS- /Zl /Foclient31_test.obj client31_test.c\nif errorlevel 1 exit /b 5\n'
        f'link /nologo /nodefaultlib /entry:entry /subsystem:console /machine:x86 /out:"{out}\\client-policy-test.exe" client31_test.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib"\nif errorlevel 1 exit /b 6\n').encode('utf-8'))
    env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),PYTHONDONTWRITEBYTECODE='1')
    build=subprocess.run(['cmd','/d','/c',str(script)],env=env,capture_output=True)
    (out/'build-output.txt').write_bytes((build.stdout+build.stderr).decode('mbcs',errors='replace').encode('utf-8'))
    if build.returncode:raise RuntimeError('Helper build failed: '+str(out/'build-output.txt'))
    test=subprocess.run([str(out/'client-policy-test.exe')],env=env,capture_output=True,timeout=10)
    if test.returncode:raise RuntimeError('Actual client policy contract failed line '+str(test.returncode))
    helper=out/'NET31CFG.EXE'
    subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/nt4/pe_nt4_version.py'),'--version','3.10',str(helper)],env=env,check=True,capture_output=True)
    for mode in ('/client','/clientcheck','/configure'):
        refusal=subprocess.run([str(helper),mode],env=env,capture_output=True,timeout=10)
        if refusal.returncode!=3 or b'REFUSED_OS' not in (out/'CFG31.LOG').read_bytes():raise RuntimeError('Host OS gate failed')
    if before!={str(f):sha(f) for f in protected}:raise ValueError('Protected SYS changed')
    result=dict(scope='NT31 helper-only SCM client policy; no runtime PASS',helper_sha256=sha(helper),helper_size=helper.stat().st_size,
        source_sha256=inputs,driver_sha256=PIN,protected_binaries=before,protected_binaries_unchanged=True,actual_policy_contract_cases=12,
        actual_policy_contract_pass=True,host_os_refusal_modes=3,runtime_pass=False)
    (out/'build.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
