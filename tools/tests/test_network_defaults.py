"""Host-only LAN policy/staging tests. Never starts a helper on the host."""
from pathlib import Path
import importlib.util
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'tools'), str(ROOT/'tools/tests')]
from build_windows_usos_lan import build, stage_driver
from check_nt52_driver_imports import pe

OUT = ROOT/'artifacts/network-defaults/host'
OUT.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(OUT)
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'
ENV = dict(os.environ, PATH=str(Path(SH).parent)+os.pathsep+os.environ.get('PATH',''))
def q(p): return "'"+str(p).replace('\\','/')+"'"
def shell(code):
    return subprocess.run([SH,'-c','. '+q(ROOT/'tools/network_setup.sh')+'; '+code],
                          cwd=ROOT, env=ENV, capture_output=True)

class Stage(unittest.TestCase):
    def setUp(self):
        self.tmp=Path(tempfile.mkdtemp(prefix='net-'))
        self.addCleanup(shutil.rmtree,self.tmp)
        self.cfg=self.tmp/'config';self.target=self.tmp/'target';self.lib=self.tmp/'lib';self.pci=self.tmp/'pci'
        self.target.mkdir();self.pci.mkdir();(self.lib/'network').mkdir(parents=True)
        self.config()
    def config(self,os_id='ME',ip='dhcp',gateway='',dns='',home='about:blank',network='on'):
        self.cfg.write_text(f'system={os_id}\nnetwork={network}\nip={ip}\ngateway={gateway}\ndns={dns}\nhome_page={home}\ndialup=off\n')
    def card(self,device='1539',index='0000-08-00.0',vendor='8086'):
        p=self.pci/index;p.mkdir()
        for name,value in dict(vendor='0x'+vendor,device='0x'+device,subsystem_vendor='0x1849',subsystem_device='0x1539',revision='0x03',**{'class':'0x020000'}).items():
            (p/name).write_text(value+'\n')
    def driver(self,id='PCI\\VEN_8086&DEV_1539'):
        for name in ('usosnet.inf','usosnet9x.inf'):
            (self.lib/'network'/name).write_text('[Models]\n%Card%=Install,'+id+'\n[Settings]\nHKR,,PollMode,0x10001,1\n')
        (self.lib/'network/usosnet.sys').write_bytes(b'own test fixture, not a driver')
        for name in ('USOSLAN9X.EXE','USOSLANNT.EXE','USOSLOG.EXE'):
            (self.lib/'network'/name).write_bytes(b'own helper fixture')
    def run_stage(self,extra=''):
        return shell('usos_net_stage '+' '.join(map(q,(self.cfg,self.target,self.lib,self.pci)))+extra)
    def state(self,r,want):
        self.assertEqual(r.returncode,0,r.stderr.decode(errors='replace'))
        self.assertIn(want,r.stdout.decode())
    def test_supported_present_readback_and_log(self):
        self.card();self.driver();r=self.run_stage();self.state(r,'staged PCI\\VEN_8086&DEV_1539')
        for name in ('INF','SYS'):
            source='usosnet9x.inf' if name=='INF' else 'usosnet.sys'
            self.assertEqual((self.target/'USOS9X/NET'/('USOSNET.'+name)).read_bytes(),(self.lib/'network'/source).read_bytes())
        self.assertIn('PollMode unchanged',(self.target/'USOS9X/LOGS/NETSETUP.TXT').read_text())
    def test_supported_missing_package(self):
        self.card();self.state(self.run_stage(),'brak w kompilacji');self.assertFalse((self.target/'USOS9X/NET').exists())
    def test_no_card(self):
        self.driver();self.state(self.run_stage(),'no Ethernet card');self.assertFalse((self.target/'USOS9X/NET').exists())
    def test_unsupported(self):
        self.driver();self.card('9999');self.state(self.run_stage(),'card not listed in INF');self.assertFalse((self.target/'USOS9X/NET').exists())
    def test_inf_drives_matching_including_subsystem_revision(self):
        self.card(vendor='1234',device='5678');self.driver('PCI\\VEN_1234&DEV_5678&SUBSYS_15391849&REV_03')
        self.state(self.run_stage(),'staged PCI\\VEN_1234')
        (self.pci/'0000-08-00.0/revision').write_text('0x02\n')
        # Fresh root: a previous install is never a staging input.
        shutil.rmtree(self.target);self.target.mkdir()
        self.state(self.run_stage(),'card not listed in INF')
    def driver4(self,id='PCI\\VEN_8086&DEV_1539'):
        (self.lib/'network/usosnet95.inf').write_text('[Models]\n%Card%=Install,'+id+'\n')
        (self.lib/'network/usosnet4.sys').write_bytes(b'own NDIS 4 test fixture, not a driver')
    def fresh(self):
        shutil.rmtree(self.target);self.target.mkdir()
    def test_95_nt4_never_receive_ndis5(self):
        self.card();self.driver()
        for os_id in ('95','NT4'):
            self.fresh();self.config(os_id);self.state(self.run_stage(),'brak w kompilacji')
            self.assertFalse(list(self.target.rglob('USOSNET*.SYS')))
            self.assertFalse(list(self.target.rglob('USOSNET.REG')))
    def test_95_stages_ndis4_build_as_usosnet_sys(self):
        self.card();self.driver();self.driver4();self.config('95')
        self.state(self.run_stage(),'usosnet4.sys as USOSNET.SYS')
        net=self.target/'USOS9X/NET'
        self.assertEqual((net/'USOSNET.SYS').read_bytes(),(self.lib/'network/usosnet4.sys').read_bytes())
        self.assertEqual((net/'USOSNET.INF').read_bytes(),(self.lib/'network/usosnet95.inf').read_bytes())
        self.assertIn('driver=staged',(self.target/'USOS9X/NETCFG.INI').read_text())
        self.fresh()
        (self.lib/'network/usosnet95.inf').write_text('[Models]\n%Card%=Install,PCI\\VEN_8086&DEV_10C9\n')
        self.state(self.run_stage(),'card not listed in INF')
    def test_nt4_stages_ndis4_and_loopback_takeover_reg(self):
        self.card();self.driver();self.driver4();self.config('NT4')
        self.state(self.run_stage(),'USOSNET.REG staged')
        self.assertEqual((self.target/'USOS/Drivers/USOSNET/USOSNET4.SYS').read_bytes(),(self.lib/'network/usosnet4.sys').read_bytes())
        self.assertFalse((self.target/'USOS/Drivers/USOSNET/USOSNET.SYS').exists())
        reg=(self.target/'USOS/NT4/USOSNET.REG').read_bytes()
        self.assertTrue(reg.startswith(b'REGEDIT4\r\n'));self.assertNotIn(b'\n',reg.replace(b'\r\n',b''))
        text=reg.decode('ascii')
        for token in ('[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\NDISLoop]\r\n"ImagePath"="\\\\SystemRoot\\\\System32\\\\drivers\\\\usosnet4.sys"',
                      '"ImagePath"="\\\\SystemRoot\\\\System32\\\\drivers\\\\usosnet4.sys"\r\n"Start"=dword:00000002',
                      'Services\\NDISLoop1\\Parameters]\r\n"BusType"=dword:00000005','"EnableDHCP"=dword:00000001',
                      '"IPAddress"=hex(7):30,2e,30,2e,30,2e,30,00,00','"DefaultGateway"=hex(7):00,00','Services\\DHCP]\r\n"Start"=dword:00000002'):
            self.assertIn(token,text)
        self.assertIn('driver=staged',(self.target/'USOS/NT4/NETCFG.INI').read_text())
        self.fresh();self.config('NT4',ip='192.168.1.20/26',gateway='192.168.1.1',dns='1.1.1.1,8.8.8.8')
        r=self.run_stage();self.state(r,'static LAN IP in USOSNET.REG')
        text=(self.target/'USOS/NT4/USOSNET.REG').read_text()
        hx=lambda s:','.join('%02x'%c for c in s.encode())+',00,00'
        for token in ('"EnableDHCP"=dword:00000000','"IPAddress"=hex(7):'+hx('192.168.1.20'),
                      '"SubnetMask"=hex(7):'+hx('255.255.255.192'),'"DefaultGateway"=hex(7):'+hx('192.168.1.1'),
                      '"NameServer"="1.1.1.1 8.8.8.8"'):
            self.assertIn(token,text)
        self.assertNotIn('Services\\DHCP]',text)
    def test_nt4_without_card_keeps_loopback_only(self):
        self.driver();self.driver4();self.config('NT4')
        self.state(self.run_stage(),'no Ethernet card')
        self.assertFalse((self.target/'USOS/NT4/USOSNET.REG').exists())
    def test_nt4_silent_logger_is_copied_and_read_back(self):
        self.driver();self.config('NT4')
        self.assertEqual(self.run_stage().returncode,0)
        self.assertEqual((self.target/'USOS/NT4/USOSLOG.EXE').read_bytes(),(self.lib/'network/USOSLOG.EXE').read_bytes())
    def test_nt4_missing_logger_stops_preparation(self):
        self.driver();self.config('NT4');(self.lib/'network/USOSLOG.EXE').unlink()
        r=self.run_stage()
        self.assertNotEqual(r.returncode,0)
        self.assertIn(b'silent network evidence helper missing',r.stdout)
    def test_network_off_writes_nothing(self):
        self.config(network='off');self.card();self.driver();self.state(self.run_stage(),'original flow')
        self.assertEqual(list(self.target.iterdir()),[])
    def test_validation_rejects_bad_addresses_before_any_write(self):
        cases=[('192.168.1.0/24','',''),('192.168.1.255/24','',''),('1.2.3.4/024','',''),
               ('dhcp','1.1.1.1',''),('192.168.1.9/24','10.0.0.1',''),('dhcp','','8.8.8.8,'),('dhcp','','127.0.0.1')]
        for ip,gw,dns in cases:
            self.config(ip=ip,gateway=gw,dns=dns)
            self.assertNotEqual(self.run_stage().returncode,0,(ip,gw,dns))
            self.assertEqual(list(self.target.iterdir()),[])
    def test_data_url_with_query_is_never_a_command(self):
        self.config(home='http://example.test/?a=1&b=2');self.driver()
        self.assertEqual(self.run_stage().returncode,0)
        self.assertIn('home_page=http://example.test/?a=1&b=2',(self.target/'USOS9X/NETCFG.INI').read_text())
    def test_me_metadata_forces_dialup_off_and_duplicates_fail(self):
        answer=self.tmp/'answer.inf';answer.write_text(';USOS-NETWORK=on\n;USOS-DIALUP=on\n')
        r=shell('usos_net_answer_config '+q(answer)+' ME');self.assertIn(b'dialup=off',r.stdout)
        answer.write_text(answer.read_text()*2);self.assertNotEqual(shell('usos_net_answer_config '+q(answer)+' ME').returncode,0)
    def test_missing_helper_has_no_broken_run_registration(self):
        app=self.target/'USOS9X';app.mkdir();(app/'MSBATCH.INF').write_text('HKLM,"Software\\Microsoft\\Windows\\CurrentVersion\\Run",USOSLan,,"C:\\USOS9X\\USOSLAN.EXE"\n')
        self.assertEqual(self.run_stage().returncode,0)
        self.assertNotIn('USOSLan',(app/'MSBATCH.INF').read_text())
    def test_w2k_oem_merge_and_exact_static_adapter(self):
        self.config('W2K',ip='192.168.1.20/24',gateway='192.168.1.1',dns='1.1.1.1,8.8.8.8');self.card();self.driver()
        sif=self.tmp/'in.sif';sif.write_text('[Unattended]\nOemPreinstall=Yes\nOemPnPDriversPath="Drivers\\Other"\n[Networking]\nInstallDefaultComponents=Yes\n')
        out=self.tmp/'out.sif';r=self.run_stage('; usos_net_w2k_sif < '+q(sif)+' > '+q(out));self.assertEqual(r.returncode,0,r.stderr)
        data=out.read_bytes();text=data.decode()
        for token in ('USOS\\Drivers\\USOSNET;Drivers\\Other','InfID="PCI\\VEN_8086&DEV_1539"','SpecificTo=USOSLAN','DHCP=No','SubnetMask=255.255.255.0','DNSServerSearchOrder=1.1.1.1,8.8.8.8','InstallDefaultComponents=No','MS_MSClient=','MS_TCPIP='):
            self.assertIn(token,text)
        self.assertNotIn('MS_Server=',text);self.assertNotIn(b'\n',data.replace(b'\r\n',b''))
        self.assertEqual(text.count('[Networking]'),1)
        self.assertEqual((self.target/'USOS/W2K/LAN.REG').read_bytes(),shell('usos_net_run_reg W2K').stdout)
    def test_w2k_ambiguous_static_not_assigned_to_arbitrary_nic(self):
        self.config('W2K',ip='10.0.0.20/24');self.card();self.card(index='0000-09-00.0');self.driver()
        r=self.run_stage('; printf "[Unattended]\\n" | usos_net_w2k_sif')
        self.assertEqual(r.returncode,0,r.stderr);self.assertIn(b'static IP not applied',r.stdout);self.assertNotIn(b'SpecificTo=',r.stdout)

class Builds(unittest.TestCase):
    def test_retry_policy_native_config_and_target_matching(self):
        zig=Path(os.environ.get('USOS_ZIG',ROOT/'tools/zig/zig.exe'));out=OUT/'policy';out.mkdir(exist_ok=True)
        env=dict(os.environ,TEMP=str(out),TMP=str(out),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
        for name in ('lan_policy_test','desktop_wait_test'):
            exe=out/(name+'.exe')
            subprocess.run([str(zig),'cc','-target','x86_64-windows-gnu','-Os','-nostdlib','-fno-builtin','-fms-extensions',
                            '-isystem',str(zig.parent/'lib/libc/include/any-windows-any'),str(ROOT/'tools/tests'/(name+'.c')),
                            '-Wl,--entry,entry','-lkernel32','-ladvapi32','-o',str(exe)],env=env,check=True)
            self.assertEqual(subprocess.run([str(exe)],env=env).returncode,0,name)
    def test_windowless_pe4_no_crt_and_nt4_exports(self):
        files=build(ROOT,OUT/'build')
        table={};current=None
        for line in (ROOT/'tools/tests/data/nt4rtm_lan_exports.txt').read_text().splitlines():
            if not line or line.startswith('#'):continue
            if line.startswith('['):current=table.setdefault(line[1:-1].lower(),set())
            else:current.add(line.split(' -> ')[0])
        for name,file in files.items():
            data=file.read_bytes();opt=struct.unpack_from('<I',data,0x3c)[0]+24
            self.assertEqual(struct.unpack_from('<HH',data,opt+48),(4,0))
            self.assertEqual(struct.unpack_from('<H',data,opt+68)[0],2)
            imports=pe(file)[1]
            self.assertEqual({m.lower() for m,_ in imports},{'kernel32.dll','advapi32.dll'})
            for dll,symbol in imports:
                self.assertIn(symbol,table.get(dll.lower(),set()),(name,dll,symbol))
            if '9X' in name:
                self.assertFalse({'RegLoadKeyA','OpenProcessToken','AdjustTokenPrivileges'} & {n for _,n in imports})
    def test_stage_real_driver_copies_bytes_only(self):
        for file in stage_driver(ROOT,OUT/'driver'):
            sub='bin/i386' if file.suffix=='.sys' else 'inf'
            self.assertEqual(file.read_bytes(),(ROOT/'tools/nt/usosnet'/sub/file.name).read_bytes())

class RunValueAndStartPage(unittest.TestCase):
    """95 X470 2026-10-20: the 9x shell starts Run values inside its
    RegEnumValue(index) loop, so USOSLan's immediate self-delete made the
    shell skip USOSDisplay; IE 3 cannot open about:blank."""
    def test_helpers_wait_before_deleting_their_run_value(self):
        lan=(ROOT/'tools/windows_usos_lan.c').read_text()
        body=lan[lan.index('static void unregister(void)'):]
        body=body[:body.index('\n}')+2] if '\n}' in body[:400] else body[:400]
        self.assertIn('#define USOS_RUN_DELETE_DELAY 15000',lan)
        self.assertLess(body.index('Sleep(USOS_RUN_DELETE_DELAY);'),body.index('RegDeleteValueA'))
        self.assertLess(body.index('#ifndef USOS_LAN_NT'),body.index('Sleep('))
        res=(ROOT/'tools/windows_usos_res.c').read_text()
        fin=res[res.index('static int finish(const char *reason)'):]
        fin=fin[:fin.index('\n}\n')]
        self.assertLess(fin.index('Sleep(15000);'),fin.index('RegDeleteValueA(key,"USOSDisplay")'))
    def test_95_start_page_is_local_file(self):
        lan=(ROOT/'tools/windows_usos_lan.c').read_text()
        page=lan[lan.index('static const char *start_page(void)'):]
        page=page[:page.index('return home;}')]
        for part in ('eq(system_id,"95")','!lstrcmpA(home,"about:blank")','local(path,"START.HTM")',
                     'GetFileAttributesA(path)!=INVALID_FILE_ATTRIBUTES','lstrcpyA(page,"file://")'):
            self.assertIn(part,page)
        self.assertIn('set(root,main_key,"Start Page",REG_SZ,page,len(page)+1);',lan)
        self.assertIn('set(root,main_key,"First Home Page",REG_SZ,page,len(page)+1);',lan)
        self.assertIn('config_hash',lan)
        self.assertNotIn('page',lan[lan.index('static unsigned long config_hash'):lan.index('static void initial_state')])

class Render(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([os.environ.get('USOS_ZIG',str(ROOT/'tools/zig/zig.exe')),'build','answer-tool',
                        '--cache-dir','tools/cache/zig-local','--global-cache-dir','tools/cache/zig-global'],cwd=ROOT,check=True)
    def test_off_matches_pre_network_answers_byte_for_byte(self):
        profile=OUT/'off.ini';profile.write_bytes((ROOT/'src/flow/answer/testdata/options.profile.ini').read_bytes()+b'\nnetwork=off\naddons_preset=none\n')
        for os_id in ('windows-95','windows-98-se','windows-me','windows-nt-4'):
            out=OUT/(os_id+'.answer')
            subprocess.run([str(ROOT/'zig-out/bin/usos-answer.exe'),'render',str(profile),os_id,'x86',str(out)],check=True)
            expected=ROOT/'tools/tests/data'/('network-off.'+os_id+'.txt')
            self.assertEqual(out.read_bytes(),expected.read_bytes())
    def test_default_source_and_renderer_have_same_lan_section(self):
        profile=OUT/'default.ini';profile.write_text('name=LAN\nuser=USOS\n')
        out=OUT/'default.inf'
        subprocess.run([str(ROOT/'zig-out/bin/usos-answer.exe'),'render',str(profile),'windows-98-se','x86',str(out)],check=True)
        def section(text,name):
            body=text.split('['+name+']\n',1)[1].split('\n[',1)[0]
            return '\n'.join(line for line in body.splitlines() if line.strip() and not line.lstrip().startswith(';'))
        default=(ROOT/'src/platform/bios/win9x/msbatch.inf').read_text()
        for name in ('MSTCP','USOS.Lan'):
            self.assertEqual(section(default,name),section(out.read_text(),name))

    def test_first_logon_dns_and_nt4_service_dependencies(self):
        p=OUT/'first.ini';p.write_text('name=LAN\nuser=Tester\n')
        for os_id in ('windows-98-se','windows-me','windows-nt-4'):
            out=OUT/'first.answer';subprocess.run([str(ROOT/'zig-out/bin/usos-answer.exe'),'render',str(p),os_id,'x86',str(out)],check=True)
            text=out.read_text()
            if os_id=='windows-nt-4':
                for service in ('LanmanServer','Browser'):self.assertIn('Services\\'+service+'|Start|dword|4',text)
            else:
                self.assertIn('DNS=1\nHostname=',text);self.assertNotIn('DNSServers=',text)
                for value in ('AutoAdminLogon,,"1"','DefaultUserName,,"Tester"','DefaultPassword,,""','"First Home Page",,"about:blank"'):self.assertIn(value,text)

    def test_dos_native_carries_the_same_helper(self):
        native=(ROOT/'src/platform/bios/dos_native_iso.zig').read_text();builder=(ROOT/'tools/build_win9x_support.py').read_text();install=(ROOT/'src/platform/bios/dos_startup.cmd').read_text()
        self.assertIn('"USOSLAN.EXE"',native);self.assertIn("out / 'USOSLAN.EXE'",builder)
        self.assertIn('IF EXIST %U9T%\\USOSLAN.EXE COPY /Y %U9T%\\USOSLAN.EXE C:\\USOS9X',install)
        self.assertIn('COPY /Y %U9T%\\MSBATCH.INF C:\\USOS9X\\MSBATCH.INF',install)
        # Disk mode (U9T=C:\USOS9X): no copy onto itself, and the Setup
        # MSBATCH copy keeps its own ERRORLEVEL check.
        lines=install.splitlines();setup=lines.index('COPY /Y %U9T%\\MSBATCH.INF C:\\%U9SRC%\\MSBATCH.INF >NUL')
        self.assertEqual(lines[setup+1],'IF ERRORLEVEL 1 GOTO FAILED')
        guard=lines.index('IF NOT "%U9T%"=="A:" GOTO LANDONE');end=lines.index(':LANDONE')
        copies=[i for i,l in enumerate(lines) if 'USOSLAN.EXE C:\\USOS9X' in l or 'C:\\USOS9X\\MSBATCH.INF' in l]
        self.assertTrue(len(copies)==2 and all(guard<i<end for i in copies))

if __name__=='__main__':unittest.main()
