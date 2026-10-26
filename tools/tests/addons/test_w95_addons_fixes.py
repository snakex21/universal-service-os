"""Host-only regression: Patcher9x NDIS bytes, WININIT queue and manifest rules."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT/'tools/tests'), str(ROOT/'tools/addons')]
import depguard
import legacy_manifest as lm

OUT = ROOT/'artifacts/w95-addons-fixes'


class AddonsFixes(unittest.TestCase):
    def test_winsock_answer_is_package_scoped(self):
        m = lm.Manifest.load()
        self.assertEqual(lm.validate(m), [])
        self.assertEqual(m.find('ws2-95').get('answer1'), 'Winsock2 Setup|1')
        self.assertNotIn('Winsock2 Setup', '\n'.join(v for s,k,v in m.entries if s=='pack'))

    def test_950_mid_restart_after_ie_is_coordinator_only(self):
        m = lm.Manifest.load()
        scoped = {p.id: (p.get('reboot_setup'), p.get('check_setup')) for p in m.packages
                  if p.get('reboot_setup') or p.get('check_setup')}
        self.assertEqual(scoped, {
            'ie55sp2-pl': ('now', ''),
            'ie55sp2-q810847-pl': ('', r'file:%SYS%\MSHTML.DLL>=5.50.4923.2500')})
        # ordinary reboot=/check= unchanged: OSR2 and later restart once at the end
        self.assertEqual(m.find('ie55sp2-pl').get('reboot'), 'end')
        self.assertEqual(m.find('ie55sp2-q810847-pl').get('check'), '')
        for os_ in ('95OSR2', '95OSR21', '95OSR25', '98FE', '98SE', 'ME'):
            plan = lm.resolve(m, os_, 'PL', '', True, [])
            if os_.startswith('95'):
                now = [i for i in plan.order if m.find(i).get('reboot') == 'now']
                self.assertEqual(now, [], os_)
            else:  # 98 / Me plans carry no coordinator-only value at all
                self.assertFalse([i for i in plan.order if i in scoped], os_)
        # 950: dcom95, ws2-95, IE -> restart -> the rest -> final restart
        order = lm.resolve(m, '95RTM', 'PL', '', True, []).order
        cut = order.index('ie55sp2-pl') + 1
        self.assertEqual(order[:cut], ['dcom95', 'ws2-95', 'ie55sp2-pl'])
        self.assertEqual(order[cut:], ['ie55sp2-q810847-pl', 'msi20-9x', 'dx80-pl', 'vbrun6sp6',
                                       'vcredist6sp6', 'mslu'])
        bad = lm.Manifest.load()
        bad.find('msi20-9x').keys['reboot_setup'] = 'now'  # os=9X: also 98 / Me
        self.assertTrue(any('reboot_setup/check_setup only for Windows 95' in e for e in lm.validate(bad)))

    def test_answerer_polls_every_wakeup_and_logs(self):
        src = (ROOT/'src/platform/win32_legacy/usosadd/main.c').read_text()
        body = src[src.index('static DWORD spawn('):src.index('static int code_ok(')]
        self.assertIn('MsgWaitForMultipleObjects(1, &pi.hProcess, FALSE, 250, QS_ALLINPUT)', body)
        self.assertIn('GetTickCount() - last >= 250', body)
        self.assertNotIn('if (r == WAIT_TIMEOUT) EnumWindows', body)
        self.assertIn('"    dialog seen: "', src)
        self.assertIn('log_runonce();', src)
        self.assertIn('ua_setup_overrides(&g_m,&g_p)', src)
        self.assertLess(src.index('g_setup_mode=exact_switch'), src.index('ua_setup_overrides(&g_m,&g_p)'))

    def test_coordinator_resumes_after_package_restart(self):
        src = (ROOT/'src/platform/win32_legacy/usosfb.c').read_text()
        self.assertTrue(src.isascii())
        self.assertIn('if(code==1001){', src)
        self.assertIn('wsprintfA(next,"mid%d\\r\\n",mid+1)', src)
        self.assertIn('if(mid>=3)fail(', src)
        self.assertIn('rundll32.exe C:\\\\WINDOWS\\\\SYSTEM\\\\iernonce.dll,RunOnceExProcess', src)
        self.assertIn('RegDeleteValueA(key,"PrimaryProvider")', src)
        final = src[src.index('if(!lstrcmpA(phase,"reboot\\r\\n")){'):src.index('mid=mid_phase(phase);')]
        self.assertLess(final.index('finish_runonceex();'), final.index('USOSADD.EXE /setup /check'))
        self.assertLess(final.index('windows_logon();'), final.index('FIRSTBT.OK'))
        tail = src[src.index('mid=mid_phase(phase);'):]
        # display request only on the first package pass, RunOnceEx before resuming
        self.assertLess(tail.index('finish_runonceex();'), tail.index('USOSADD.EXE /setup'))
        self.assertLess(tail.index('}else{'), tail.index('USOSRES.EXE /setup'))

    def test_byte_patch_matches_pinned_patcher9x(self):
        folder = ROOT/'tools/vendor/patcher9x/0.9.91'
        lock = __import__('json').loads((folder/'manifest.json').read_text())
        source = folder/'source.zip'
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), lock['files']['source.zip'])
        with zipfile.ZipFile(source) as z:
            prefix = z.namelist()[0].split('/')[0]+'/'
            for version in (1, 4):
                before = z.read(prefix+f'cpuspeed/speedndis_v{version}_orig.bin')
                after = z.read(prefix+f'cpuspeed/speedndis_v{version}.bin')
                diffs = [i for i, (a,b) in enumerate(zip(before,after)) if a!=b]
                lo, hi = min(diffs), max(diffs)+1
                self.assertEqual(hi-lo, 18)
                self.assertEqual(before[lo:hi].hex(), '100090e2fecd203f00010029d0b9e8030000')
                self.assertEqual(after[lo:hi].hex(), '4006e2fecd203f00010029d07501406a0a59')

    def test_compiled_repair_offsets_queue_idempotence_and_failures(self):
        zig = depguard.require_zig()
        OUT.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, TEMP=str(OUT), TMP=str(OUT),
                   ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),
                   ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
        exe = OUT/'ndis_repair_host.exe'
        subprocess.run([str(zig), 'cc', '-target', 'x86_64-windows-gnu', '-Os', '-nostdlib',
                        '-fno-builtin', '-fno-stack-protector',
                        '-isystem', str(zig.parent/'lib/libc/include/any-windows-any'),
                        str(ROOT/'tools/tests/addons/ndis_repair_host.c'), '-Wl,--entry,entry',
                        '-lkernel32', '-o', str(exe)], env=env, check=True)
        for case in range(13):
            with self.subTest(case=case):
                # Keep all run evidence; no cleanup of prior fixture outputs.
                import tempfile
                folder = Path(tempfile.mkdtemp(prefix=f'case-{case}-', dir=OUT))
                dest = folder/exe.name
                shutil.copyfile(exe, dest)
                result = subprocess.run([str(dest), str(case)], env=env, timeout=15)
                self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
