"""Portable fresh-directory build of own NT3 posthelper; never executes it."""
from pathlib import Path
import argparse,hashlib,json,os,re,subprocess,sys
ROOT=Path(__file__).resolve().parents[2]
def main():
 p=argparse.ArgumentParser();p.add_argument('--wdk',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 out=a.out.resolve();wdk=a.wdk.resolve()
 if not out.is_relative_to(ROOT/'artifacts') or out.exists():raise ValueError('Fresh owned artifacts output required')
 if not (wdk/'bin/setenv.bat').is_file() or not re.fullmatch(r'[A-Za-z0-9_:\\./-]+',str(wdk)):raise ValueError('Existing no-space WDK required')
 out.mkdir(parents=True);tmp=out/'tmp';tmp.mkdir();src=ROOT/'tools/nt3/usosnt3/src/usosnt3.c';script=out/'build.cmd'
 lines=['@echo off',f'call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr','if errorlevel 1 exit /b 2',f'cd /d "{out}"',
 f'cl /nologo /c /W3 /O1 /Oi- /GS- /Gy /Zl /DWIN32 /D_WIN32_WINNT=0x0400 /DWINVER=0x0400 /I"{wdk}\\inc\\api" /I"{wdk}\\inc\\crt" /Fousosnt3.obj "{src}"',
 'if errorlevel 1 exit /b 3',f'link /nologo /NODEFAULTLIB /ENTRY:entry /SUBSYSTEM:CONSOLE /MACHINE:X86 /OPT:REF /RELEASE /FIXED:NO /OUT:USOSNT3.EXE usosnt3.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib" "{wdk}\\lib\\wxp\\i386\\advapi32.lib"','if errorlevel 1 exit /b 4']
 script.write_text('\n'.join(lines)+'\n',encoding='utf-8');env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp))
 r=subprocess.run(['cmd','/d','/c',str(script)],env=env,capture_output=True)
 (out/'build-output.txt').write_text((r.stdout+r.stderr).decode('mbcs',errors='replace'),encoding='utf-8')
 if r.returncode:raise RuntimeError('See owned build-output.txt')
 binary=out/'USOSNT3.EXE';subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/nt4/pe_nt4_version.py'),'--version','3.10',str(binary)],env=env,check=True,capture_output=True)
 record={'binary':str(binary),'bytes':binary.stat().st_size,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'runtime_pass':False,'not_executed_on_host':True}
 (out/'build.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record))
if __name__=='__main__':main()
