from pathlib import Path
import hashlib,os,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
sys.path.insert(0,str(ROOT/'tools/tests'))
import depguard
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
            for version,build,expected in [('6.2','19041',0),('6.2','9600',0),('10.0','19041',0),('6.3','9600',0),('6.2','9200',0),('6.2','8400',1),('6.1','9200',1),('6.0','6002',1),('10.0','22000',1),('10.0','',1),('6.2','oops',1)]:
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

    def test_default_on_with_scoped_opt_out(self):
        # X470 Micron PASS 2026-10-22 (Embedded 8.1 Industry Pro x86, Windows
        # 10 22H2 x86): default on, Unattended/nvme-off.txt turns it off.
        sh=Path(r'C:\Program Files\Git\bin\sh.exe')
        OUT=ROOT/'zig-out/modern-tests';OUT.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=OUT) as folder:
            data=Path(folder)
            def call(fn,profile,name):
                code='. "$1"; '+fn+' "$2" "$3" "$4"'
                return subprocess.run([str(sh),'-c',code,'test',str(ROOT/'tools/vista_csmwrap_prepare.sh'),profile,str(data),name],capture_output=True).returncode
            run=lambda p,n:call('vista_modern_nvme_enabled',p,n)
            external=lambda p,n:call('vista_modern_external_donor_enabled',p,n)
            # Windows 8 RTM (NT 6.2, build 9200) has no inbox NVMe driver either:
            # the same "modern" package, default on (unchecked on media).
            for name in ('Windows 10','Windows 8.1','Windows Embedded 8.1 Industry','Windows 8'):
                self.assertEqual(run('win-x86-uefi-csmwrap',name),0)
            self.assertNotEqual(external('win-x86-uefi-csmwrap','Windows 10'),0)
            for name in ('Windows 8.1','Windows Embedded 8.1 Industry','Windows 8'):
                self.assertEqual(external('win-x86-uefi-csmwrap',name),0)
                self.assertNotEqual(external('win-nt6-x86-uefi-csmwrap',name),0)
            # The old opt-in flag changes nothing.
            old=data/'Systems/Windows/Windows 10/Unattended/nvme-experimental.txt';old.parent.mkdir(parents=True);old.touch()
            self.assertEqual(run('win-x86-uefi-csmwrap','Windows 10'),0)
            for name in ('Windows 10','Windows 8.1','Windows Embedded 8.1 Industry','Windows 8'):
                off=data/'Systems/Windows'/name/'Unattended/nvme-off.txt';off.parent.mkdir(parents=True,exist_ok=True);off.touch()
                self.assertNotEqual(run('win-x86-uefi-csmwrap',name),0)
                if name!='Windows 10':self.assertNotEqual(external('win-x86-uefi-csmwrap',name),0)
            for profile,name in [('win-nt6-x86-uefi-csmwrap','Windows 10'),('vista-x64-sp2-uefi-csmwrap','Windows 10'),('win-x86-uefi-csmwrap','Windows 7'),('win-x86-uefi-csmwrap','Windows Vista')]:self.assertNotEqual(run(profile,name),0)

    def test_disk_gate_keeps_checks_and_sata_keeps_own_pe(self):
        prep=(ROOT/'tools/vista_csmwrap_prepare.sh').read_text(encoding='utf-8')
        nv=prep[prep.index('case "$TARGET_DEVICE" in /dev/nvme*)'):prep.index('        model=$(usos_disk_model')]
        modern=nv[nv.index('                win-x86-uefi-csmwrap)'):]
        self.assertNotIn('nvme-experimental',modern)
        self.assertIn('vista_modern_nvme_enabled "$profile" /mnt/data "$folder" "$source_directory" || stop',modern)
        self.assertIn('[ "$donor" != "$iso" ] || stop',modern)
        self.assertIn('pe_nvme=usosnvme-modern',modern)
        # Windows 8 RTM takes the modern package and the external donor too.
        self.assertEqual(modern.count("'Windows 8'"),2,modern)
        self.assertIn('[ "$nvme_lbs" = 512 ] || stop',nv)
        self.assertIn('stage_donor=$iso',prep)
        self.assertIn('VISTA_DONOR_ISO="/mnt/data/$stage_donor"',prep)
        self.assertLess(prep.index('usos_xp_confirm "$screen"'),prep.index('stage_donor=$donor'))
        target=(ROOT/'tools/vista_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn("case \"$modern_id\" in 'PCI\\VEN_1344&DEV_5407'|'PCI\\VEN_1B36&DEV_0010') ;; *) fail",target)
        zig=(ROOT/'src/platform/uefi/windows_native_iso.zig').read_text(encoding='utf-8')
        self.assertNotIn('nvme-experimental.txt',zig)
        self.assertIn('"nvme-off.txt"',zig)
        self.assertIn('!(try modernNvmeOff(state, folder))',zig)

    def test_service_api_contract_and_failures(self):
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True);exe=out/'service.exe'
        subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-O2',str(ROOT/'tools/tests/nvme_modern_service_harness.c'),'-ladvapi32','-lcrypt32','-lshell32','-o',str(exe)],check=True,capture_output=True)
        subprocess.run([str(exe)],check=True,capture_output=True)

    def test_cmd_retries_the_helper_once(self):
        # X470 B261022-130215: one helper failure stopped the install; the
        # .cmd now tries once more (the helper starts again from its hive
        # copies) and still refuses the restart after a second failure.
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=out) as tmp:
            folder=Path(tmp)
            source=(ROOT/'tools/windows_nvme_modern.cmd').read_text()
            source=source.replace('dism.exe ', 'call "%~dp0dism-mock.cmd" ').replace('ping -n 3 127.0.0.1 >nul','rem no wait in the test')
            source=source.replace('"%~dp0usos-nvme-modern.exe"', 'call "%~dp0helper-mock.cmd"')
            (folder/'route.cmd').write_text(source)
            for name in ('inf','sys','cat','cer'):
                (folder/('modern-usosnvme.'+name)).write_bytes(b'private test placeholder')
            (folder/'dism-mock.cmd').write_text('@echo off\necho dism>>"%USOS_TRACE%\\trace"\nexit /b 0\n')
            (folder/'helper-mock.cmd').write_text('''@echo off
echo helper>>"%USOS_TRACE%\\trace"
if "%USOS_FAIL%"=="always" exit /b 4
if "%USOS_FAIL%"=="once" if not exist "%USOS_TRACE%\\failed" (echo x>"%USOS_TRACE%\\failed" & exit /b 4)
exit /b 0
''')
            for fail,code,helpers in (('once',0,3),('always',1,2)):
                trace=folder/fail;trace.mkdir()
                target=trace/'target'
                (target/'Windows/System32/config').mkdir(parents=True)
                (target/'Windows/System32/config/SYSTEM').write_bytes(b'not a real hive')
                (target/'Windows/System32/Recovery').mkdir()
                (target/'Windows/System32/Recovery/winre.wim').write_bytes(b'not a real WIM')
                env=dict(os.environ,USOS_TRACE=str(trace),USOS_FAIL=fail)
                r=subprocess.run(['cmd.exe','/d','/c',str(folder/'route.cmd'),str(target),'6.2','19041'],env=env,capture_output=True,text=True)
                with self.subTest(fail=fail):
                    self.assertEqual(r.returncode,code,r.stdout)
                    events=(trace/'trace').read_text().split()
                    self.assertEqual(events.count('helper'),helpers)
                    self.assertIn('second attempt',r.stdout)
                    if code:self.assertIn('restart refused',r.stdout);self.assertEqual(events.count('dism'),1)

    def test_trust_store_reports_no_stale_code_and_reads_back(self):
        # CertAddEncodedCertificateToStore leaves CRYPT_E_NOT_FOUND in
        # GetLastError on success; the X470 log reported exactly that code.
        certs=sorted(ROOT.glob('zig-out/**/usosnvme.cer'))
        if not certs:self.skipTest('build the signed usosnvme package first')
        source=(ROOT/'tools/windows_nvme_modern.c').read_text()
        self.assertNotIn('operation="trust-certificate-stores"',source)
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=out) as tmp:
            folder=Path(tmp)
            code=r'''#include <windows.h>
#include <assert.h>
#include <stdio.h>
static int flush_fail;
static LONG WINAPI flush_fake(HKEY h){(void)h;if(flush_fail){flush_fail--;return ERROR_REGISTRY_IO_FAILED;}return ERROR_SUCCESS;}
#define RegFlushKey flush_fake
#define entry unused_entry
#include "SOURCE"
int main(int argc,char**argv){
 FILE*f=fopen(argv[1],"rb");DWORD size=(DWORD)fread(cert,1,sizeof cert,f);fclose(f);assert(size>100);
 assert(make_thumbprint(size)&&lstrlenW(thumb)==40);
 HKEY base;assert(!RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-modern",0,0,0,KEY_ALL_ACCESS,0,&base,0));
 failure_code=0;assert(trusted_store(base,ROOT_STORE,size,0));assert(trusted_store(base,PUBLISHER_STORE,size,1));
 assert(failure_code==0);
 assert(has_certificate(base,ROOT_STORE,size)&&has_certificate(base,PUBLISHER_STORE,size));
 assert(!has_certificate(base,L"Microsoft\\SystemCertificates\\CA",size)&&failure_code==ERROR_FILE_NOT_FOUND);
 flush_fail=2;assert(flush_retry(base)==ERROR_SUCCESS&&!flush_fail);
 flush_fail=5;assert(flush_retry(base)==ERROR_REGISTRY_IO_FAILED);
 RegCloseKey(base);RegDeleteTreeW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-modern");RegDeleteKeyW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-modern");
 return 0;
}
'''
            (folder/'trust.c').write_text(code.replace('SOURCE',str(ROOT/'tools/windows_nvme_modern.c').replace('\\','/')))
            exe=folder/'trust.exe'
            subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-O2',str(folder/'trust.c'),'-ladvapi32','-lcrypt32','-lshell32','-o',str(exe)],check=True,capture_output=True)
            r=subprocess.run([str(exe),str(certs[-1])],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)

    def test_host_is_refused_before_writes(self):
        exe=depguard.require_path('zig-out/windows-modern/usos-nvme-modern.exe', 'brak helpera NVMe - uruchom build.bat')
        self.assertTrue(exe.is_file(),'build the helper before running this test')
        self.assertEqual(subprocess.run([str(exe)],capture_output=True).returncode,2)

    def test_failed_flush_falls_back_to_saved_hive(self):
        # X470 B261022-130215 / -133852: RegFlushKey on the loaded SOFTWARE
        # hive returned 1016 on every try. commit_hive then saves the loaded
        # hive with RegSaveKeyExW, unloads it, puts the saved file in place
        # and sets the stale .LOG1/.LOG2 aside. A good flush keeps the old path.
        source=(ROOT/'tools/windows_nvme_modern.c').read_text()
        self.assertIn('e=commit_hive(&software,soft,wm,&soft_loaded,0);',source)
        self.assertIn('e=commit_hive(&hive,sys,sm,&sys_loaded,1);',source)
        self.assertIn('operation="verify-system-service"',source)
        self.assertNotIn('operation="flush-system";e=flush_retry(hive)',source)
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=out) as tmp:
            folder=Path(tmp)
            code=r'''#include <windows.h>
#include <assert.h>
#include <stdio.h>
static int flush_fail,unloads;
static LONG WINAPI flush_fake(HKEY h){(void)h;if(flush_fail){flush_fail--;return ERROR_REGISTRY_IO_FAILED;}return ERROR_SUCCESS;}
static LONG WINAPI unload_fake(HKEY h,LPCWSTR n){(void)h;(void)n;unloads++;return ERROR_SUCCESS;}
static void Sleep_fake(DWORD ms){(void)ms;}
#define RegFlushKey flush_fake
#define RegUnLoadKeyW unload_fake
#define Sleep Sleep_fake
#define entry unused_entry
#include "SOURCE"
static void put(const WCHAR *p,const char *t,DWORD attr){HANDLE h=CreateFileW(p,GENERIC_WRITE,0,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);DWORD w;assert(h!=INVALID_HANDLE_VALUE);WriteFile(h,t,lstrlenA(t),&w,0);CloseHandle(h);if(attr)SetFileAttributesW(p,attr);}
static BOOL there(const WCHAR *p){return GetFileAttributesW(p)!=INVALID_FILE_ATTRIBUTES;}
int main(int argc,char**argv){
 (void)argc;WCHAR dir[MAX_PATH],hive[MAX_PATH],p[MAX_PATH];MultiByteToWideChar(CP_ACP,0,argv[1],-1,dir,MAX_PATH);
 lstrcpyW(package,dir);join(hive,dir,L"\\SOFTWARE");
 put(hive,"old hive",0);join(p,hive,L".LOG1");put(p,"log1",FILE_ATTRIBUTE_HIDDEN|FILE_ATTRIBUTE_SYSTEM);join(p,hive,L".LOG2");put(p,"log2",FILE_ATTRIBUTE_HIDDEN|FILE_ATTRIBUTE_SYSTEM);
 assert(enable_privilege(L"SeBackupPrivilege"));
 HKEY base;BOOL loaded=TRUE;DWORD v=0x5553;
 assert(!RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-commit",0,0,0,KEY_ALL_ACCESS,0,&base,0));
 assert(!RegSetValueExW(base,L"marker",0,REG_DWORD,(const BYTE*)&v,4));
 /* good flush: no save, plain unload */
 flush_fail=0;unloads=0;assert(commit_hive(&base,hive,L"X",&loaded,0)==ERROR_SUCCESS);
 assert(!base&&!loaded&&unloads==1&&!lstrcmpA(operation,"unload-software"));
 join(p,hive,L".LOG1.usos-stale");assert(!there(p));
 /* flush fails on every try: saved copy replaces the hive, logs set aside */
 assert(!RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-commit",0,KEY_ALL_ACCESS,&base));
 loaded=TRUE;flush_fail=99;unloads=0;assert(commit_hive(&base,hive,L"X",&loaded,1)==ERROR_SUCCESS);
 assert(!base&&!loaded&&unloads==1&&!lstrcmpA(operation,"replace-system"));
 HANDLE h=CreateFileW(hive,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);char head[4];DWORD n=0;assert(h!=INVALID_HANDLE_VALUE);ReadFile(h,head,4,&n,0);CloseHandle(h);
 assert(n==4&&head[0]=='r'&&head[1]=='e'&&head[2]=='g'&&head[3]=='f');
 join(p,hive,L".LOG1");assert(!there(p));join(p,hive,L".LOG2");assert(!there(p));
 join(p,hive,L".LOG1.usos-stale");assert(there(p));join(p,hive,L".LOG2.usos-stale");assert(there(p));
 join(p,hive,L".usos-saved");assert(!there(p));join(p,dir,L"\\flush-probe.bin");assert(!there(p));
 /* save refused: the step is reported, the hive file stays */
 assert(!RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-commit",0,KEY_ALL_ACCESS,&base));
 join(p,hive,L".usos-saved");CreateDirectoryW(p,0);
 loaded=TRUE;flush_fail=99;unloads=0;assert(commit_hive(&base,hive,L"X",&loaded,0)!=ERROR_SUCCESS);
 assert(base&&loaded&&!unloads&&!lstrcmpA(operation,"save-software"));RemoveDirectoryW(p);
 RegCloseKey(base);RegDeleteTreeW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-commit");RegDeleteKeyW(HKEY_CURRENT_USER,L"Software\\USOS-test-nvme-commit");
 return 0;
}
'''
            (folder/'commit.c').write_text(code.replace('SOURCE',str(ROOT/'tools/windows_nvme_modern.c').replace('\\','/')))
            exe=folder/'commit.exe'
            subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-O2',str(folder/'commit.c'),'-ladvapi32','-lcrypt32','-lshell32','-o',str(exe)],check=True,capture_output=True)
            r=subprocess.run([str(exe),str(folder)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertIn('SYSTEM hive RegFlushKey failed; saving the hive to a new file instead. Win32 code=1016',r.stdout)
            self.assertIn('flush probe (4 KiB write + FlushFileBuffers on the target), Win32 code=0',r.stdout)
            self.assertIn('SYSTEM hive replaced by its saved copy.',r.stdout)

    def test_driver_diag_line_and_probe_after_every_flush(self):
        # X470 B261022: RegFlushKey 1016 in 2 of 3 WinPE runs. Every flush try
        # and the flush probe (now also after a good flush) are followed by
        # the usosnvme counters (IOCTL_SCSI_MINIPORT "USOSNVME", only from
        # entry(); the host tests never send it to a real adapter).
        source=(ROOT/'tools/windows_nvme_modern.c').read_text()
        commit=source[source.index('static LONG commit_hive('):source.index('static BOOL service_points_to_usosnvme(')]
        self.assertLess(commit.index('flush_probe()'),commit.index('if(e==ERROR_SUCCESS){'))
        self.assertIn('nvme_diag("after flush probe");',commit)
        self.assertIn('nvme_diag("after RegFlushKey");',source[source.index('static LONG flush_retry('):])
        entry=source[source.index('void entry(void)'):]
        self.assertLess(entry.index('MiniNT'),entry.index('diag_enabled=TRUE'))
        out=ROOT/'zig-out/modern-tests';out.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=out) as tmp:
            folder=Path(tmp)
            code=r'''#include <windows.h>
#include <assert.h>
#include <string.h>
static int opened_ours,ioctls;
static HANDLE WINAPI create_fake(LPCWSTR n,DWORD a,DWORD s,LPSECURITY_ATTRIBUTES sa,DWORD d,DWORD f,HANDLE t){
 (void)a;(void)s;(void)sa;(void)d;(void)f;(void)t;
 if(!lstrcmpW(n,L"\\\\.\\Scsi1:")||!lstrcmpW(n,L"\\\\.\\Scsi12:")){opened_ours++;return (HANDLE)(n[9]==L'2'?(HANDLE)12:(HANDLE)1);}
 SetLastError(ERROR_FILE_NOT_FOUND);return INVALID_HANDLE_VALUE;}
static BOOL WINAPI close_fake(HANDLE h){(void)h;return TRUE;}
#include "DIAGH"
static int answer=1;
static BOOL WINAPI ioctl_fake(HANDLE h,DWORD code,LPVOID in,DWORD inl,LPVOID out,DWORD outl,LPDWORD got,LPOVERLAPPED o){
 (void)o;assert(code==0x0004D008UL&&in==out&&inl==outl);ioctls++;
 PUSOSNVME_SRB_IO_CONTROL hd=(PUSOSNVME_SRB_IO_CONTROL)in;
 assert(hd->HeaderLength==28&&!memcmp(hd->Signature,"USOSNVME",8)&&hd->ControlCode==USOSNVME_DIAG_CODE&&hd->Length==sizeof(USOSNVME_DIAG));
 if(h==(HANDLE)1){SetLastError(ERROR_INVALID_FUNCTION);return FALSE;}   /* another miniport */
 if(!answer){SetLastError(ERROR_INVALID_FUNCTION);return FALSE;}
 PUSOSNVME_DIAG d=(PUSOSNVME_DIAG)((BYTE*)in+28);
 d->Version=1;d->Size=sizeof(*d);d->PciId=0x54071344;d->Vwc=7;d->State=11;d->Writes=99;d->FlushRequests=5;d->FlushSent=3;d->FlushSkipped=2;
 d->FlushOk=2;d->FlushErrors=1;d->FlushTimeouts=1;d->LastFlushUs=10200000;d->LastFlushStatus=0xFFFFFFFF;d->FlushSeq=9;
 d->Ring[1].Seq=9;d->Ring[1].Source=1;d->Ring[1].Us=10200000;d->Ring[1].Status=0xFFFFFFFF;
 d->Ring[0].Seq=8;d->Ring[0].Source=0x10002;d->Ring[0].Us=0;d->Ring[0].Status=0;
 hd->ReturnCode=0;*got=outl;return TRUE;}
#define CreateFileW create_fake
#define CloseHandle close_fake
#define DeviceIoControl ioctl_fake
#define entry unused_entry
#include "SOURCE"
int main(void){
 nvme_diag("off");assert(!opened_ours&&!ioctls);
 diag_enabled=TRUE;nvme_diag("test");assert(opened_ours==2&&ioctls==2);
 answer=0;nvme_diag("none");
 return 0;
}
'''
            code=code.replace('DIAGH',str(ROOT/'tools/nt/usosnvme/src/usosnvme_diag.h').replace('\\','/'))
            (folder/'diag.c').write_text(code.replace('SOURCE',str(ROOT/'tools/windows_nvme_modern.c').replace('\\','/')))
            exe=folder/'diag.exe'
            r=subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-O2',str(folder/'diag.c'),'-ladvapi32','-lcrypt32','-lshell32','-o',str(exe)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)
            r=subprocess.run([str(exe)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            lines=r.stdout.splitlines()
            self.assertEqual(len(lines),2,r.stdout)
            self.assertTrue(lines[0].startswith('[USOS] Modern NVMe diag test: scsi12 pci 1344:5407 vwc 0x07 state 0xB'),lines[0])
            for want in (' wr 99 ',' | flush req 5 sent 3 skip 2 ok 2 err 1 to 1 last-us 10200000 ',' last-st timeout ',
                         ' | ring #9:00000001:10200000us:timeout #8:00010002:0us:0x000'):
                self.assertIn(want,lines[0])
            self.assertEqual(lines[1],'[USOS] Modern NVMe diag none: no usosnvme adapter answered IOCTL_SCSI_MINIPORT; last DeviceIoControl Win32 code=1')

if __name__=='__main__':unittest.main()
