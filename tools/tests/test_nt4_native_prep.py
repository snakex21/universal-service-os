# SPDX-License-Identifier: GPL-3.0-or-later
"""NT4 preparation contracts; no hardware write, no product key fixture."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools/tests'))
from check_nt52_driver_imports import pe
from test_w9x_phase1_qemu import sh
from test_nt4_flow import function_text

class NativePrep(unittest.TestCase):
    def test_shared_binaries_unchanged(self):
        for leaf in ('usosnet4.sys','usosnet351.sys','usosnet351n.sys'):
            rel = 'tools/nt/usosnet/bin/i386/'+leaf
            original = subprocess.check_output(['git','show','2d7f2a23:'+rel],cwd=ROOT,timeout=10)
            self.assertEqual((ROOT/rel).read_bytes(), original)

    def test_nt4_kernel_imports_only_in_nt4_variant(self):
        _, imports = pe(ROOT/'tools/nt/usosnet/bin/nt4/i386/usosnet4.sys')
        allowed = {}
        current = None
        for line in ((ROOT/'tools/tests/data/nt4rtm_exports.txt').read_text()+'\n'+
                     (ROOT/'tools/tests/data/nt4sp6a_ndis_exports.txt').read_text()).splitlines():
            if line.startswith('['): current = line.strip('[]').lower(); allowed[current] = set()
            elif current and line and not line.startswith('#'): allowed[current].add(line.split(' -> ')[0])
        for module, name in imports:
            self.assertIn(name, allowed.get(module.lower(), set()), module+'!'+name)
        self.assertIn(('ntoskrnl.exe','ZwFlushKey'),[(m.lower(),n) for m,n in imports])
        self.assertTrue(all(m.lower()=='ndis.sys' for m,n in pe(ROOT/'tools/nt/usosnet/bin/i386/usosnet4.sys')[1]))

    def test_host_finish_refuses_before_io(self):
        exe = ROOT/'tools/nt4/usosfinish/bin/i386/USOSNT4.EXE'
        for opt in ('/early','/finish'):
            self.assertEqual(subprocess.run([str(exe),opt],timeout=5).returncode,3)

    def test_native_routes_preserve_95(self):
        src = (ROOT/'tools/network_setup.sh').read_text()
        self.assertIn('NT4) _un_sys=usosnet4.sys;',src)
        self.assertIn('[ "${USOS_NT4_NATIVE_DIAG:-0}" != 1 ] || _un_sys=nt4/usosnet4.sys',src)
        self.assertIn('95) _un_inf=usosnet95.inf; _un_sys=usosnet4.sys',src)
        self.assertIn('network/\' + relative', (ROOT/'tools/build_micro_linux.py').read_text())
        start=src.index('    _un_sys=usosnet.sys _un_dsys=USOSNET.SYS _un_ndis=04')
        block=src[start:src.index('    mkdir -p "$(dirname "$_un_log")"',start)]
        for system,enabled,expected in (('NT4','1','nt4/usosnet4.sys'),('NT4','0','usosnet4.sys'),('95','1','usosnet4.sys'),('XP','1','usosnet.sys')):
            rc,out,err=sh('_un_os='+system+'; USOS_NT4_NATIVE_DIAG='+enabled+'\n'+block+'\nprintf "%s" "$_un_sys"\n')
            self.assertEqual((rc,out.strip()),(0,expected),err)

    def test_tse_and_other_versions_keep_old_preparation(self):
        src=(ROOT/'tools/nt4_csmwrap_target.sh').read_text()
        start=src.index('NT4_NATIVE_PREP=0\n')
        block=src[start:src.index('\n',src.index('|| NT4_NATIVE_PREP=1',start))]
        for native,major,tse,expected in (('1','4','','1'),('1','4','yes','0'),('0','4','','0'),('1','3','','0')):
            rc,out,err=sh('NATIVE='+native+'; major='+major+'; tse='+tse+'\n'+block+'\nprintf "%s" "$NT4_NATIVE_PREP"\n')
            self.assertEqual((rc,out.strip()),(0,expected),err)

    def test_no_registry_io_from_timer(self):
        src=(ROOT/'tools/nt/usosnet/src/usosnet_nt4_bc.h').read_text()
        tick=src[src.index('static void N4Tick'):src.index('static void N4Drain')]
        self.assertIn('ExQueueWorkItem',tick)
        self.assertNotIn('ZwFlushKey(',tick)
        self.assertIn('KeGetCurrentIrql() != PASSIVE_LEVEL',src)
        self.assertIn('KeWaitForSingleObject',src)

    def test_early_before_post_and_fail_stops_restart(self):
        src=(ROOT/'tools/nt4_csmwrap_target.sh').read_text()
        self.assertIn('USOSNT4.EXE /early',src)
        self.assertIn('if errorlevel 1 goto nativefailed',src)
        self.assertIn('echo native finish FAILED; no restart',src)
        self.assertIn('seek=508 count=1',src)
        self.assertIn('= 64 ]',src)
        self.assertIn('NATIVE.TXT',src)

    def test_profile_key_route_no_embedded_value(self):
        src=(ROOT/'src/flow/answer/root.zig').read_text()
        self.assertIn('const use_key = key orelse p.keyFor(system_id);',src)
        self.assertIn('nt4.render(p, use_key, buffer)',src)
        placeholder='<KLUCZ-Z-PROFILU>'
        self.assertNotIn(placeholder,(ROOT/'src/flow/answer/nt4.zig').read_text().split('test "')[0])
        wrapper=(ROOT/'src/platform/uefi/answer_profiles.zig').read_text()
        self.assertIn('answer.render(profile, system_id, arch, null,',wrapper)

    def test_key_gate_logs_only_presence_with_unformatted_placeholder(self):
        parent=ROOT/'artifacts';parent.mkdir(exist_ok=True)
        fn=function_text(ROOT/'tools/nt4_csmwrap_target.sh','nt4_key_gate')
        with tempfile.TemporaryDirectory(dir=parent) as folder:
            base=Path(folder);answer=base/'profile.sif'
            for body,wanted,code in (('[UserData]\nProductId="KLUCZ-Z-PROFILU"\n','key',0),('[UserData]\n','needed',1)):
                answer.write_text(body)
                rc,out,err=sh(fn+'\nnt4_key_gate "'+answer.as_posix()+'" "'+base.as_posix()+'"\n')
                self.assertEqual((rc,out.strip()),(code,wanted),err)
                self.assertNotIn('KLUCZ-Z-PROFILU',out+err)

if __name__=='__main__': unittest.main()
