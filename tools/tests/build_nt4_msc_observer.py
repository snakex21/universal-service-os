"""Build only the own quiet MSC fixture observer, with actual host refusals."""
from pathlib import Path
import hashlib,json,os,subprocess,sys
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'artifacts/nt4-msc/build04'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 if OUT.exists():raise FileExistsError('Preserve previous build')
 OUT.mkdir(parents=True);tmp=OUT/'tmp';tmp.mkdir();src=ROOT/'tools/tests/nt4_msc_observer.c'
 wdk=Path(r'C:\Users\ASRock\Desktop\universal-service-os\tools\WinDDK71');script=OUT/'build.cmd'
 lines=['@echo off',f'call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr','if errorlevel 1 exit /b 2',f'cd /d "{OUT}"',
 f'cl /nologo /c /W3 /O1 /Gd /GS- /Zl /DWIN32 /D_WIN32_WINNT=0x0400 /DWINVER=0x0400 /I"{wdk}\\inc\\api" /I"{wdk}\\inc\\crt" /Fomsc.obj "{src}"','if errorlevel 1 exit /b 3',
 f'link /nologo /nodefaultlib /entry:entry /subsystem:windows /machine:x86 /out:MSC4TEST.EXE msc.obj "{wdk}\\lib\\wxp\\i386\\kernel32.lib"','if errorlevel 1 exit /b 4']
 script.write_text('\n'.join(lines)+'\n',encoding='utf-8',newline='\r\n');env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),APPDATA=str(tmp),LOCALAPPDATA=str(tmp))
 r=subprocess.run(['cmd','/d','/c',str(script)],env=env,capture_output=True);(OUT/'build-output.txt').write_text((r.stdout+r.stderr).decode('mbcs',errors='replace'),encoding='utf-8')
 if r.returncode:raise RuntimeError('Own observer build failed; see own build output')
 exe=OUT/'MSC4TEST.EXE';subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/nt4/pe_nt4_version.py'),'--version','4.00',str(exe)],env=env,check=True,capture_output=True)
 for mode in ('/startup','/hot','/replug'):
  result=subprocess.run([str(exe),mode],env=env,capture_output=True,timeout=10)
  if result.returncode!=3 or b'REFUSED_OS' not in (OUT/'MSC4LOG.TXT').read_bytes():raise ValueError('Actual host refusal failed')
 record=dict(helper_sha256=sha(exe),helper_bytes=exe.stat().st_size,source_sha256=sha(src),host_refusals=3,subsystem='GUI4.00',driver_rebuilt=False,guest_pass=False)
 (OUT/'build.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record,indent=2))
if __name__=='__main__':main()
