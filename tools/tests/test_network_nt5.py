"""Host-only: usosnet LAN staging for Windows XP x86 and Server 2003 x86
(tools/network_setup.sh, prepare_xp_windows_partition.sh,
prepare_xp_ntfs_target.sh). X470 2026-10-22: a fresh USOS XP SP3 install had
no driver for the I211 (setupapi.log: PCI\\VEN_8086&DEV_1539&SUBSYS_15391849,
0xe0000228 "no compatible drivers", null driver installed)."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'tools/tests')]
import test_network_defaults as nd  # noqa: E402
from test_network_defaults import shell, q, OUT  # noqa: E402

class Nt5Stage(unittest.TestCase):
    # The fixtures of test_network_defaults.Stage, without its tests.
    setUp = nd.Stage.setUp; config = nd.Stage.config; card = nd.Stage.card
    driver = nd.Stage.driver; run_stage = nd.Stage.run_stage
    def stage_sif(self, sif_text, keep='no'):
        sif = self.tmp/'in.sif'; sif.write_text(sif_text)
        out = self.tmp/'out.sif'
        r = self.run_stage('; USOS_NET_KEEP='+keep+' usos_net_w2k_sif < '+q(sif)+' > '+q(out))
        self.assertEqual(r.returncode, 0, r.stderr.decode(errors='replace'))
        return r, out.read_bytes()

    def test_config_system_tag(self):
        for tag in ('XP', 'W2K3', 'W2K'):
            r = shell('usos_net_w2k_config "" '+tag)
            self.assertEqual(r.returncode, 0)
            self.assertTrue(r.stdout.startswith(('system='+tag+'\n').encode()), r.stdout)
        self.assertTrue(shell('usos_net_w2k_config ""').stdout.startswith(b'system=W2K\n'))
        self.assertNotEqual(shell('usos_net_w2k_config "" XP64').returncode, 0)
        ini = self.tmp/'usos-xp.ini'; ini.write_text('user=USOS\nip=192.168.1.20/24\ngateway=192.168.1.1\n')
        r = shell('usos_net_w2k_config '+q(ini)+' XP')
        self.assertIn(b'system=XP\nnetwork=on\nip=192.168.1.20/24\ngateway=192.168.1.1\n', r.stdout)

    def test_xp_and_2003_path_without_oem_preinstall(self):
        for tag in ('XP', 'W2K3'):
            with self.subTest(tag=tag):
                shutil.rmtree(self.target); self.target.mkdir(); shutil.rmtree(self.pci); self.pci.mkdir()
                self.config(tag); self.card(); self.driver()
                r, data = self.stage_sif('[Data]\nmsdosinitiated="1"\n[Unattended]\nDriverSigningPolicy=Ignore\n'
                                         'OemPreinstall=No\nOemPnPDriversPath="USOS\\Drivers\\User\\USB-01"\n')
                text = data.decode()
                self.assertIn(b'staged PCI\\VEN_8086&DEV_1539', r.stdout)
                self.assertEqual(text.count('OemPreinstall='), 1)
                self.assertIn('OemPreinstall=No\r\n', text)
                self.assertNotIn('OemPreinstall=Yes', text)
                self.assertIn('OemPnPDriversPath="USOS\\Drivers\\USOSNET;USOS\\Drivers\\User\\USB-01"', text)
                self.assertEqual(text.count('OemPnPDriversPath='), 1)
                for token in ('[Networking]\r\nInstallDefaultComponents=No', 'MS_MSClient=USOS.MSClient',
                              'MS_TCPIP=USOS.TCPIP', '[NetServices]', 'JoinWorkgroup=WORKGROUP'):
                    self.assertIn(token, text)
                self.assertNotIn('MS_Server', text); self.assertNotIn('DHCP=No', text)
                self.assertNotIn(b'\n', data.replace(b'\r\n', b''))
                # No $OEM$ tree (OemPreinstall=No): the package lies on C: itself.
                self.assertFalse(list(self.target.rglob('$OEM$')))
                pkg = self.target/'USOS/Drivers/USOSNET'
                self.assertEqual((pkg/'USOSNET.SYS').read_bytes(), (self.lib/'network/usosnet.sys').read_bytes())
                self.assertEqual((pkg/'USOSNET.INF').read_bytes(), (self.lib/'network/usosnet.inf').read_bytes())
                app = self.target/'USOS'/tag
                self.assertIn(('system='+tag+'\r\n').encode(), (app/'NETCFG.INI').read_bytes())
                self.assertIn(b'driver=staged\r\n', (app/'NETCFG.INI').read_bytes())
                self.assertEqual((app/'USOSLAN.EXE').read_bytes(), b'own helper fixture')
                reg = (app/'LAN.REG').read_bytes()
                self.assertIn(('"USOSLan"="C:\\\\USOS\\\\'+tag+'\\\\USOSLAN.EXE"').encode(), reg)

    def test_xp_static_address_for_one_card(self):
        self.config('XP', ip='192.168.1.20/24', gateway='192.168.1.1', dns='1.1.1.1'); self.card(); self.driver()
        _, data = self.stage_sif('[Unattended]\nOemPreinstall=No\n')
        text = data.decode()
        for token in ('AdapterSections=USOS.LAN.TCPIP', 'InfID="PCI\\VEN_8086&DEV_1539"', 'SpecificTo=USOSLAN',
                      'IPAddress=192.168.1.20', 'SubnetMask=255.255.255.0', 'DefaultGateway=192.168.1.1',
                      'DNSServerSearchOrder=1.1.1.1'):
            self.assertIn(token, text)

    def test_no_card_keeps_answer_driver_keys(self):
        self.config('XP'); self.driver()
        r, data = self.stage_sif('[Unattended]\nOemPreinstall=No\nOemPnPDriversPath="X"\n')
        self.assertIn(b'no Ethernet card', r.stdout)
        text = data.decode()
        self.assertIn('OemPnPDriversPath="X"', text); self.assertNotIn('USOSNET', text)
        self.assertIn('MS_TCPIP=USOS.TCPIP', text)  # client + TCP/IP even without a card
        self.assertFalse((self.target/'USOS/Drivers').exists())

    def test_user_sif_network_sections_are_kept(self):
        self.config('XP'); self.card(); self.driver()
        _, data = self.stage_sif('[Unattended]\nOemPreinstall=No\n[Networking]\nInstallDefaultComponents=Yes\n'
                                 '[NetServices]\nMS_SERVER=params.MS_SERVER\n', keep='yes')
        text = data.decode()
        self.assertIn('OemPnPDriversPath="USOS\\Drivers\\USOSNET"', text)
        self.assertIn('[Networking]\r\nInstallDefaultComponents=Yes', text)
        self.assertIn('MS_SERVER=params.MS_SERVER', text)
        self.assertNotIn('USOS.TCPIP', text); self.assertEqual(text.count('[Networking]'), 1)

    def test_w2k_still_sets_oem_preinstall(self):
        self.config('W2K'); self.card(); self.driver()
        _, data = self.stage_sif('[Unattended]\nOemPreinstall=No\n')
        text = data.decode()
        self.assertIn('OemPreinstall=Yes', text); self.assertNotIn('OemPreinstall=No', text)
        self.assertTrue((self.target/'$WIN_NT$.~LS/$OEM$/$1/USOS/Drivers/USOSNET/USOSNET.SYS').is_file())

class Nt5Wiring(unittest.TestCase):
    def test_partition_preparer_selects_x86_nt5_systems(self):
        text = (ROOT/'tools/prepare_xp_windows_partition.sh').read_text()
        block = text[text.index('net_system=\n'):text.index('put_verified "$work/winnt.sif"')]
        for line in ('windows-2000:*) net_system=W2K', 'windows-xp:I386) net_system=XP',
                     'windows-server-2003:I386) net_system=W2K3',
                     'usos_net_w2k_config "${XP_USER_SETTINGS:-}" "$net_system"', 'USOS_NET_KEEP=yes'):
            self.assertIn(line, block)
        self.assertNotIn('windows-xp-x64', block)

    def test_setup_end_imports_lan_reg(self):
        text = (ROOT/'tools/prepare_xp_ntfs_target.sh').read_text()
        xp = text[text.index('if [ "${USOS_PLAN_PROFILE:-}" = xp-x86-sp3-uefi-csm ]; then\nmkdir'):text.index('# Installer-chosen language')]
        self.assertIn('usos_nt52_insert_before_exit "$work/volume/USOS/XP/usos-users.cmd" '
                      '\'if exist "%SystemDrive%\\USOS\\XP\\LAN.REG" %SystemRoot%\\regedit.exe /s "%SystemDrive%\\USOS\\XP\\LAN.REG"\'', xp)
        self.assertLess(xp.index('usos_nt52_display_only_cmd'), xp.index('LAN helper (network_setup.sh'))
        self.assertIn('if [ "$NT5_SYSTEM" = windows-2000 ] || [ "$NT5_SYSTEM" = windows-server-2003 ]; then\n'
                      '        printf \'if exist "%%USOS_DIR%%\\\\USOSLAN.EXE"', text)

    def test_xp_hook_renders_into_the_setup_end_script(self):
        """The XP hook inserts the import before exit /b 0 of a minimal
        usos-users.cmd (no accounts, no display helper)."""
        text = (ROOT/'tools/prepare_xp_ntfs_target.sh').read_text()
        fn = text[text.index('usos_nt52_insert_before_exit() {'):]
        fn = fn[:fn.index('\n}\n')+3]
        hook = text[text.index('if [ -f "$work/volume/USOS/XP/USOSLAN.EXE" ]'):text.index('# Installer-chosen language')]
        tmp = Path(tempfile.mkdtemp(prefix='nt5hook-', dir=OUT)); self.addCleanup(shutil.rmtree, tmp)
        xp = tmp/'volume/USOS/XP'; xp.mkdir(parents=True)
        (xp/'USOSLAN.EXE').write_bytes(b'x'); (xp/'LAN.REG').write_bytes(b'REGEDIT4\r\n')
        script = tmp/'hook.sh'
        script.write_text('fail() { echo "$1" >&2; exit 1; }\nwork='+q(tmp)+'\n'+fn+hook)
        r = subprocess.run([nd.SH, str(script)], env=nd.ENV, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        cmd = (xp/'usos-users.cmd').read_bytes()
        self.assertTrue(cmd.startswith(b'@echo off\r\n'))
        self.assertTrue(cmd.endswith(b'if exist "%SystemDrive%\\USOS\\XP\\LAN.REG" %SystemRoot%\\regedit.exe /s '
                                     b'"%SystemDrive%\\USOS\\XP\\LAN.REG"\r\nexit /b 0\r\n'), cmd)

    def test_usosnet_imports_resolve_on_xp_sp3(self):
        from check_nt52_driver_imports import pe
        from test_usosnet import export_table
        xp = export_table('xpsp3_ndis_exports.txt')['ndis.sys']
        imports = pe(ROOT/'tools/nt/usosnet/bin/i386/usosnet.sys')[1]
        self.assertTrue(imports)
        for mod, name in imports:
            self.assertEqual(mod, 'ndis.sys', name)
            self.assertIn(name, xp, 'XP SP3 NDIS.SYS: ' + name)

    def test_nt5_inf_lists_the_x470_card(self):
        inf = (ROOT/'tools/nt/usosnet/inf/usosnet.inf').read_text()
        for line in ('Signature="$Windows NT$"', 'Class=Net', '%I211.DeviceDesc%=USOSNET.ndi, PCI\\VEN_8086&DEV_1539',
                     'Characteristics=0x84', 'BusType=5', 'AddService=usosnet, 2,', 'HKR,Ndi\\Interfaces,UpperRange,0,"ndis5"'):
            self.assertIn(line, inf)

    def test_lan_helper_accepts_xp_and_2003(self):
        lan = (ROOT/'tools/windows_usos_lan.c').read_text()
        self.assertIn('return eq(system_id,"NT4")||eq(system_id,"W2K")||eq(system_id,"XP")||eq(system_id,"W2K3");', lan)

if __name__ == '__main__':
    unittest.main()
