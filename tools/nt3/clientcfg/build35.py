"""Build just the owned NT35 GUI policy helper; never rebuild any SYS."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--out',type=Path,required=True);args=parser.parse_args()
    out=args.out.resolve()
    if out.exists() or not out.is_relative_to(ROOT/'artifacts/nt35-client'):
        raise ValueError('Fresh owned output required')
    out.mkdir(parents=True);tmp=out/'tmp';tmp.mkdir();src=out/'src';src.mkdir()
    inputs={}
    for name in ('client35.c','service_policy.h','scm_policy.h','policy_test.c'):
        data=(HERE/name).read_bytes();(src/name).write_bytes(data);inputs[name]=sha(src/name)
    wdk=Path(r'C:\Users\ASRock\Desktop\universal-service-os\tools\WinDDK71')
    if not (wdk/'bin/setenv.bat').is_file():raise ValueError('Existing WDK required')
    script=out/'build.cmd'
    script.write_text(f'''@echo off
call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr
if errorlevel 1 exit /b 2
cd /d "{src}"
cl /nologo /c /W3 /O1 /Gd /GS- /Zl /DWIN32 /D_WIN32_WINNT=0x0400 /DWINVER=0x0400 /I"{wdk}\\inc\\api" /I"{wdk}\\inc\\crt" /Foclient35.obj client35.c
if errorlevel 1 exit /b 3
link /nologo /nodefaultlib /entry:entry /subsystem:windows /machine:x86 /out:"{out}\\CLNT35.EXE" client35.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib" "{wdk}\\lib\\wxp\\i386\\advapi32.lib"
if errorlevel 1 exit /b 4
cl /nologo /c /W3 /O1 /Gd /GS- /Zl /Fopolicy_test.obj policy_test.c
if errorlevel 1 exit /b 5
link /nologo /nodefaultlib /entry:entry /subsystem:console /machine:x86 /out:"{out}\\policy-test.exe" policy_test.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib"
if errorlevel 1 exit /b 6
''',encoding='utf-8',newline='\r\n')
    env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),APPDATA=str(tmp),LOCALAPPDATA=str(tmp),PYTHONDONTWRITEBYTECODE='1')
    result=subprocess.run(['cmd','/d','/c',str(script)],env=env,capture_output=True)
    (out/'build-output.txt').write_text((result.stdout+result.stderr).decode('mbcs',errors='replace'),encoding='utf-8')
    if result.returncode:raise RuntimeError('Build failed; see owned build-output.txt')
    test=subprocess.run([str(out/'policy-test.exe')],env=env,capture_output=True,timeout=10)
    if test.returncode:raise RuntimeError('Actual policy contract failed line '+str(test.returncode))
    helper=out/'CLNT35.EXE'
    subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/nt4/pe_nt4_version.py'),'--version','3.10',str(helper)],env=env,check=True,capture_output=True)
    for mode in ('/apply','/check'):
        denied=subprocess.run([str(helper),mode],env=env,capture_output=True,timeout=10)
        if denied.returncode!=3 or b'REFUSED_OS' not in (out/'CLNT35.LOG').read_bytes():raise RuntimeError('Host refusal failed')
    record=dict(scope='Owned NT35 client-only helper; not runtime PASS',sha256=sha(helper),bytes=helper.stat().st_size,
                subsystem='GUI',source_sha256=inputs,actual_policy_contract_cases=12,actual_policy_contract_pass=True,
                host_refusal_modes=2,driver_rebuilt=False,registry_app_data=False,runtime_pass=False)
    (out/'build.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record,indent=2))

if __name__=='__main__':main()
