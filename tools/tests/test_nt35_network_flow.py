"""Actual NT35 answer rendering, portable staging and fail-closed INF patch.
No VM, mounted disk, registry or physical-device access.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest

from test_w9x_phase1_qemu import shell

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'tools/nt35_network_setup.sh'
BIN = ROOT / 'tools/nt/usosnet/bin/i386/usosnet35.sys'


class Nt35Network(unittest.TestCase):
    def setUp(self):
        parent = ROOT / 'artifacts/nt35-network/flow-tests'
        parent.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='case-', dir=parent))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.profile = self.tmp/'profile.ini'
        self.profile.write_text('[profile]\nname=Fixture\nuser=USOS\nworkgroup=TESTLAB\n', encoding='utf-8')
        self.answer = self.tmp/'WINNT.SIF'

    def render(self, system='windows-nt-3-5', off=False):
        if off:
            self.profile.write_text(self.profile.read_text()+'network=off\n', encoding='utf-8')
        tool = ROOT / 'zig-out/bin/usos-answer.exe'
        result = subprocess.run([str(tool),'render',str(self.profile),system,'x86',str(self.answer),'-'], capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        return self.answer.read_text()

    def sh(self, code, input=None):
        script=self.tmp/'run.sh'
        script.write_text(f'. "{LIB.as_posix()}"\n'+'''usos_nt35_sysfs_address() {
 case "${1##*/}" in card3) usos_nt35_pci_address 0000:02:03.1 ;; card4) usos_nt35_pci_address 0000:03:04.0 ;; *) return 1 ;; esac
}
'''+code, encoding='utf-8', newline='\n')
        return subprocess.run([shell(), str(script)], input=input, capture_output=True)

    def stage_inputs(self):
        lib=self.tmp/'lib';(lib/'nt3').mkdir(parents=True);(lib/'network').mkdir()
        shutil.copy(ROOT/'tools/network_setup.sh',lib/'network_setup.sh')
        shutil.copy(ROOT/'tools/nt/usosnet/inf/usosnet.inf',lib/'network/usosnet.inf')
        shutil.copy(BIN,lib/'nt3/USOSNET35.SYS')
        sha=hashlib.sha256(BIN.read_bytes()).hexdigest()
        (lib/'nt3/USOSNET35.SHA256').write_text(sha+'  USOSNET35.SYS\n',encoding='utf-8')
        logger=b'Own host-only logger staging fixture; no executable runtime claim'
        (lib/'nt3/USOSLOG35.EXE').write_bytes(logger)
        (lib/'nt3/USOSLOG35.SHA256').write_text(hashlib.sha256(logger).hexdigest()+'  USOSLOG35.EXE\n',encoding='utf-8')
        pci=self.tmp/'pci';card=pci/'card3';card.mkdir(parents=True)
        for key,value in {'class':'0x020000','vendor':'0x8086','device':'0x10c9','revision':'0x01'}.items():
            (card/key).write_text(value+'\n',encoding='utf-8')
        return lib,pci

    def test_actual_renderer_is_system_bound_and_network_off(self):
        for system in ('windows-nt-3-5','windows-nt-3-5-server'):
            self.assertIn(';USOS-NT35-NETWORK=on',self.render(system))
        self.assertIn(';USOS-NT35-NETWORK=off',self.render(off=True))
        for system in ('windows-nt-3-51','windows-nt-3-1'):
            self.assertNotIn('USOS-NT35-NETWORK',self.render(system))

    def test_actual_render_then_dhcp_answer_and_staging(self):
        self.render();lib,pci=self.stage_inputs();target=self.tmp/'target';output=self.tmp/'NETWORK.SIF'
        result=self.sh(f'usos_nt35_preflight "{self.answer.as_posix()}" "{lib.as_posix()}" "{pci.as_posix()}" || exit 7\n'
            f'usos_nt35_answer "{self.answer.as_posix()}" > "{output.as_posix()}" || exit 8\n'
            f'usos_nt35_stage "{target.as_posix()}" || exit 9\n')
        self.assertEqual(result.returncode,0,result.stderr.decode())
        text=output.read_bytes()
        for value in (b'!SetupNetWork = YES',b'!AutoNetOption = LOOP',b'!InstallTCPIP = 1',
                      b'!InstallNetBEUI = 0',b'!InstallNWLink = 0',b'Medium = 0',b'!AutoWorkGroup = TESTLAB'):
            self.assertIn(value,text)
        self.assertNotIn(b'\n',text.replace(b'\r\n',b''))
        staged=target/'USOS/NT3/USOSNET35.SYS'
        self.assertEqual(staged.read_bytes(),BIN.read_bytes())
        self.assertFalse((target/'USOS/NT3/USOSNET4.SYS').exists())
        self.assertIn('adapter=NDISLoop1',(target/'USOS/NT3/NET35.ON').read_text())
        self.assertIn('bus=2',(target/'USOS/NT3/NET35.ON').read_text())
        self.assertIn('slot=35',(target/'USOS/NT3/NET35.ON').read_text())
        self.assertIn('[NetCardParameterList]',text.decode())

    def test_wrong_driver_hash_refused_before_target_created(self):
        self.render();lib,pci=self.stage_inputs();target=self.tmp/'target'
        (lib/'nt3/USOSNET35.SYS').write_bytes(b'wrong image')
        result=self.sh(f'usos_nt35_preflight "{self.answer.as_posix()}" "{lib.as_posix()}" "{pci.as_posix()}" || exit 7\n'
            f'usos_nt35_stage "{target.as_posix()}"')
        self.assertEqual(result.returncode,7)
        self.assertFalse(target.exists())

    def test_two_cards_and_static_request_refused(self):
        self.render();lib,pci=self.stage_inputs()
        shutil.copytree(pci/'card3',pci/'card4')
        result=self.sh(f'usos_nt35_preflight "{self.answer.as_posix()}" "{lib.as_posix()}" "{pci.as_posix()}"')
        self.assertNotEqual(result.returncode,0)
        shutil.rmtree(pci/'card4')
        self.answer.write_text(self.answer.read_text().replace(';USOS-IP=dhcp',';USOS-IP=192.0.2.2/24'),encoding='utf-8')
        result=self.sh(f'usos_nt35_preflight "{self.answer.as_posix()}" "{lib.as_posix()}" "{pci.as_posix()}"')
        self.assertNotEqual(result.returncode,0)

    def test_off_needs_no_driver_and_duplicate_marker_rejected(self):
        self.render(off=True)
        result=self.sh(f'usos_nt35_preflight "{self.answer.as_posix()}" /missing /missing')
        self.assertEqual(result.returncode,0)
        self.answer.write_text(self.answer.read_text()+';USOS-NT35-NETWORK=on\n',encoding='utf-8')
        result=self.sh(f'usos_nt35_requested "{self.answer.as_posix()}"')
        self.assertNotEqual(result.returncode,0)

    def test_owned_patch_transform_is_narrow_and_malformed_input_refused(self):
        # Own synthetic input only. Original Microsoft bytes are validated
        # in RAM by audit_nt35_ndis_exports.py --loop-patch.
        data=b'[InstallOption]\r\nadapteroptions = +\r\n    set MediaChoice = first\r\n    ui start "InputDlg"\r\nskipoptions = +\r\n    continue\r\n'
        result=self.sh('usos_nt35_loop_inf\n',input=data)
        self.assertEqual(result.returncode,0)
        self.assertEqual(result.stdout.count(b';USOS-NT35-LOOP-AUTO'),1)
        self.assertLess(result.stdout.index(b'goto skipoptions'),result.stdout.index(b'ui start'))
        self.assertNotEqual(self.sh('usos_nt35_loop_inf\n',input=b'[Other]\r\n').returncode,0)

    def test_actual_pci_address_parser_bounds(self):
        good=self.sh('usos_nt35_pci_address 0000:ff:1f.7 || exit 9; printf "%s %s" "$_u35_bus" "$_u35_slot"')
        self.assertEqual(good.returncode,0);self.assertEqual(good.stdout,b'255 255')
        for bdf in ('0001:00:03.0','0000:00:20.0','0000:00:03.8','card3','0000:zz:03.0'):
            self.assertNotEqual(self.sh('usos_nt35_pci_address '+bdf).returncode,0)

    def test_wiring_keeps_nt4_95_and_other_nt3_minors_out(self):
        target=(ROOT/'tools/nt4_csmwrap_target.sh').read_text()
        self.assertIn('if [ "$major:$minor" = 3:50 ]; then',target)
        self.assertIn('[ "$minor" != 50 ] || usos_nt35_stage',target)
        self.assertIn('yes:51|yes:50|yes:10',target)
        self.assertIn(r'^version=3\.50[[:space:]]*$',LIB.read_text())
        self.assertNotIn(r'^version=3\.5[[:space:]]*$',LIB.read_text())
        helper=(ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_text()
        self.assertIn('((version >> 8) & 0xff) != 50)',helper)
        self.assertIn('!net351_equal_files(DIR "USOSNET35.SYS",dst)',helper)
        self.assertIn('!net351_has_binding(linkage)',helper)
        self.assertIn('installed_runtime_pass=false',helper)
        build=(ROOT/'tools/build_micro_linux.py').read_text()
        self.assertIn("'usr/lib/usos/nt3/USOSNET35.SYS'",build)
        self.assertIn("'usr/lib/usos/nt3/USOSNET35.SHA256'",build)

    def test_cache_hunks_preserve_unrelated_later_base_features(self):
        from build_nt35_fixture_cache import owned_hunks
        before=''.join(f'line{i}\n' for i in range(16)).encode()
        after=before.replace(b'line12\n',b'line12\nNT35 only\n')
        base=before.replace(b'line1\n',b'line1\nNT4 USB Storage retained\n')
        changed=owned_hunks(base,before,after)
        self.assertIn(b'NT4 USB Storage retained',changed)
        self.assertIn(b'NT35 only',changed)

    def test_cache_hunks_refuse_changed_or_ambiguous_context(self):
        from build_nt35_fixture_cache import owned_hunks
        with self.assertRaises(ValueError):owned_hunks(b'different\n',b'original\n',b'new\n')
        with self.assertRaises(ValueError):owned_hunks(b'original\noriginal\n',b'original\n',b'new\n')

    def test_actual_nt35_utc_alias_and_nt4_mapping_preserved(self):
        from test_nt4_flow import function_text
        function=function_text(ROOT/'tools/nt4_csmwrap_target.sh','nt4_resolve_time_zone')
        script=self.tmp/'timezone.sh'
        script.write_text(function+'\nnt4_resolve_time_zone 0409 yes\n',encoding='utf-8',newline='\n')
        result=subprocess.run([shell(),str(script)],input=b';USOS-TZ=Greenwich\r\n',capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertEqual(result.stdout,b'!TimeZone = "(GMT) Monrovia, Casablanca"\r\n')
        script.write_text(function+'\nnt4_resolve_time_zone 0409\n',encoding='utf-8',newline='\n')
        result=subprocess.run([shell(),str(script)],input=b';USOS-TZ=Greenwich\r\n',capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertNotIn(b'Monrovia',result.stdout)


if __name__ == '__main__':
    unittest.main()
