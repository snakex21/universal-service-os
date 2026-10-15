from pathlib import Path
import hashlib,os,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import build_usosnvme_nt6_signed as signing

class ModernNVMe(unittest.TestCase):
    def test_actual_cmd_finalizes_service_after_dism_and_stops_on_failure(self):
        """DISM is allowed to rewrite the shared service; our helper must run last."""
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=out) as tmp:
            folder=Path(tmp)
            source=(ROOT/'tools/windows_nvme_modern.cmd').read_text()
            source=source.replace('dism.exe ', 'call "%~dp0dism-mock.cmd" ')
            source=source.replace('"%~dp0usos-nvme-modern.exe"', 'call "%~dp0helper-mock.cmd"')
            (folder/'route.cmd').write_text(source)
            for name in ('inf','sys','cat','cer'):
                (folder/('modern-usosnvme.'+name)).write_bytes(b'private test placeholder')
            (folder/'dism-mock.cmd').write_text('''@echo off
echo(%*|findstr /i /c:"/ScratchDir:" >nul
if errorlevel 1 exit /b 9
set "add="
set "commit="
for %%A in (%*) do (
 if /i "%%~A"=="/Add-Driver" set "add=1"
 if /i "%%~A"=="/Commit" set "commit=1"
)
if defined add (
 if exist "%USOS_TRACE%\\installed" (
  echo dism-recovery>>"%USOS_TRACE%\\trace"
  if "%USOS_FAIL%"=="recovery" exit /b 5
  echo inbox>"%USOS_TRACE%\\recovery-state"
 ) else (
  echo dism-installed>>"%USOS_TRACE%\\trace"
  if "%USOS_FAIL%"=="installed" exit /b 5
  echo inbox>"%USOS_TRACE%\\installed-state"
  echo ready>"%USOS_TRACE%\\installed"
 )
)
if defined commit echo commit>>"%USOS_TRACE%\\trace"
exit /b 0
''')
            (folder/'helper-mock.cmd').write_text('''@echo off
if not exist "%USOS_TRACE%\\installed" exit /b 6
if exist "%USOS_TRACE%\\helper-installed" (
 if not exist "%USOS_TRACE%\\recovery-state" exit /b 6
 echo helper-recovery>>"%USOS_TRACE%\\trace"
 echo owned>"%USOS_TRACE%\\recovery-state"
) else (
 echo helper-installed>>"%USOS_TRACE%\\trace"
 echo owned>"%USOS_TRACE%\\installed-state"
 echo ready>"%USOS_TRACE%\\helper-installed"
)
exit /b 0
''')
            for fail in ('none','installed','recovery'):
                trace=folder/fail;trace.mkdir()
                target=trace/'target'
                config=target/'Windows/System32/config';config.mkdir(parents=True)
                (config/'SYSTEM').write_bytes(b'not a real hive')
                recovery=target/'Windows/System32/Recovery';recovery.mkdir()
                (recovery/'winre.wim').write_bytes(b'not a real WIM')
                env=dict(os.environ,USOS_TRACE=str(trace),USOS_FAIL=fail)
                result=subprocess.run(['cmd.exe','/d','/c',str(folder/'route.cmd'),str(target),'6.2','19041'],env=env,capture_output=True)
                events=(trace/'trace').read_text().splitlines()
                with self.subTest(failure=fail):
                    if fail=='none':
                        self.assertEqual(result.returncode,0,result.stdout)
                        self.assertEqual(events,['dism-installed','helper-installed','dism-recovery','helper-recovery','commit'])
                        for image in ('installed','recovery'):
                            self.assertEqual((trace/(image+'-state')).read_text().strip(),'owned')
                    else:
                        self.assertNotEqual(result.returncode,0)
                        self.assertNotIn('commit',events)
                        self.assertNotIn('helper-recovery',events)
                        if fail=='installed':self.assertNotIn('helper-installed',events)

    def test_mount_lifecycle_and_collision_refusal(self):
        source=(ROOT/'tools/windows_nvme_modern.c').read_text()
        function=source[source.index('static LONG load_hive('):source.index('static BOOL configure(void)')]
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=out) as tmp:
            folder=Path(tmp)
            code=r'''#include <windows.h>
#include <assert.h>
static int scenario,opens,loads,closes;
static LONG open_key(HKEY root,LPCWSTR name,DWORD zero,REGSAM access,PHKEY key){
 assert(root==HKEY_LOCAL_MACHINE&&!zero&&!lstrcmpW(name,L"USOS_PRIVATE_TEST"));opens++;
 if(opens==1){assert(access==KEY_READ);if(scenario==1){*key=(HKEY)2;return 0;}return scenario==2?ERROR_ACCESS_DENIED:ERROR_FILE_NOT_FOUND;}
 assert(access==KEY_ALL_ACCESS);*key=(HKEY)1;return scenario==3?ERROR_ACCESS_DENIED:0;
}
static LONG load_key(HKEY root,LPCWSTR name,LPCWSTR file){assert(root==HKEY_LOCAL_MACHINE&&!lstrcmpW(name,L"USOS_PRIVATE_TEST")&&!lstrcmpW(file,L"VIRTUAL_SOFTWARE"));loads++;return scenario==4?ERROR_BADDB:0;}
static LONG close_key(HKEY key){assert(key==(HKEY)2);closes++;return 0;}
#define RegOpenKeyExW open_key
#define RegLoadKeyW load_key
#define RegCloseKey close_key
/* FUNCTION */
int main(void){
 for(scenario=0;scenario<5;scenario++){
  HKEY key=0;BOOL loaded=FALSE;opens=loads=closes=0;
  LONG e=load_hive(L"VIRTUAL_SOFTWARE",L"USOS_PRIVATE_TEST",&key,&loaded);
  if(scenario==0)assert(!e&&loaded&&loads==1&&key==(HKEY)1);
  if(scenario==1)assert(e==ERROR_ALREADY_EXISTS&&!loaded&&!loads&&closes==1);
  if(scenario==2)assert(e==ERROR_ACCESS_DENIED&&!loaded&&!loads);
  if(scenario==3)assert(e==ERROR_ACCESS_DENIED&&loaded&&loads==1);
  if(scenario==4)assert(e==ERROR_BADDB&&!loaded&&loads==1);
 }
 return 0;
}
'''
            (folder/'mount.c').write_text(code.replace('/* FUNCTION */',function))
            exe=folder/'mount.exe'
            subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-O2',str(folder/'mount.c'),'-o',str(exe)],check=True,capture_output=True)
            subprocess.run([str(exe)],check=True,capture_output=True)

    def test_actual_cmd_version_guard_uses_build(self):
        source=(ROOT/'tools/windows_nvme_modern.cmd').read_text()
        function=source[source.index(':supported_nt\n'):]
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=out) as tmp:
            script=Path(tmp)/'guard.cmd'
            script.write_text('@echo off\ncall :supported_nt "%~1" "%~2"\nexit /b %errorlevel%\n'+function)
            for version,build,expected in [('6.2','19041',0),('6.2','9600',0),('10.0','19041',0),('6.3','9600',0),('6.2','9200',1),('6.0','6002',1),('10.0','22000',1),('10.0','',1),('6.2','oops',1)]:
                with self.subTest(version=version,build=build):
                    r=subprocess.run(['cmd.exe','/d','/c',str(script),version,build],capture_output=True)
                    self.assertEqual(r.returncode,expected)

    def test_package_keeps_inbox_file_intact_and_targets_reviewed_ids(self):
        inf=signing.nt6_inf(ROOT,modern=True)
        self.assertIn(b'AddService = stornvme,',inf)
        self.assertIn(b'ServiceBinary  = %12%\\usosnvme.sys',inf)
        self.assertIn(b'PCI\\VEN_1344&DEV_5407',inf);self.assertIn(b'PCI\\VEN_1B36&DEV_0010',inf)
        self.assertNotIn(b'PCI\\CC_010802',inf)
        raw=subprocess.check_output(['git','show','d7ef2fb:tools/nt/usosnvme/usosnvme.inf'],cwd=ROOT)
        expected=raw.replace(signing.INF_DATE_IN,signing.INF_DATE_OUT+b'\r\nCatalogFile=usosnvme.cat').replace(b'\r\n',b'\n').replace(b'\n',b'\r\n')
        self.assertEqual(signing.nt6_inf(ROOT),expected)

    def test_scoped_opt_in(self):
        sh=Path(r'C:\Program Files\Git\bin\sh.exe')
        OUT=ROOT/'zig-out/modern-tests';OUT.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=OUT) as folder:
            data=Path(folder);flag=data/'Systems/Windows/Windows 10/Unattended/nvme-experimental.txt';flag.parent.mkdir(parents=True)
            code='. "$1"; vista_modern_nvme_enabled "$2" "$3" "$4"'
            def run(profile,name):return subprocess.run([str(sh),'-c',code,'test',str(ROOT/'tools/vista_csmwrap_prepare.sh'),profile,str(data),name],capture_output=True).returncode
            self.assertNotEqual(run('win-x86-uefi-csmwrap','Windows 10'),0)
            flag.touch();self.assertEqual(run('win-x86-uefi-csmwrap','Windows 10'),0)
            def external(profile,name):
                code='. "$1"; vista_modern_external_donor_enabled "$2" "$3" "$4"'
                return subprocess.run([str(sh),'-c',code,'test',str(ROOT/'tools/vista_csmwrap_prepare.sh'),profile,str(data),name],capture_output=True).returncode
            self.assertNotEqual(external('win-x86-uefi-csmwrap','Windows 10'),0)
            self.assertNotEqual(external('win-x86-uefi-csmwrap','Windows 8.1'),0)
            for name in ('Windows 8.1','Windows Embedded 8.1 Industry'):
                donor_flag=data/'Systems/Windows'/name/'Unattended/nvme-experimental.txt'
                donor_flag.parent.mkdir(parents=True);donor_flag.touch()
                self.assertEqual(external('win-x86-uefi-csmwrap',name),0)
                self.assertNotEqual(external('win-nt6-x86-uefi-csmwrap',name),0)
            for profile,name in [('win-nt6-x86-uefi-csmwrap','Windows 10'),('vista-x64-sp2-uefi-csmwrap','Windows 10'),('win-x86-uefi-csmwrap','Windows 7')]:self.assertNotEqual(run(profile,name),0)

    def test_service_api_contract_and_failures(self):
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True);exe=out/'service.exe'
        subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-O2',str(ROOT/'tools/tests/nvme_modern_service_harness.c'),'-ladvapi32','-lcrypt32','-lshell32','-o',str(exe)],check=True,capture_output=True)
        subprocess.run([str(exe)],check=True,capture_output=True)

    def test_host_is_refused_before_writes(self):
        exe=ROOT/'zig-out/windows-modern/usos-nvme-modern.exe'
        self.assertTrue(exe.is_file(),'build the helper before running this test')
        self.assertEqual(subprocess.run([str(exe)],capture_output=True).returncode,2)

if __name__=='__main__':unittest.main()
