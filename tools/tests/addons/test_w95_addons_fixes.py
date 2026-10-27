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
            'dcom95': ('now', ''),
            'ie55sp2-pl': ('now', ''),
            'ie55sp2-q810847-pl': ('', r'file:%SYS%\MSHTML.DLL>=5.50.4923.2500')})
        # ordinary reboot=/check= unchanged: OSR2 and later restart once at the end
        self.assertEqual(m.find('ie55sp2-pl').get('reboot'), 'end')
        self.assertEqual(m.find('dcom95').get('reboot'), 'end')
        self.assertEqual(m.find('ie55sp2-q810847-pl').get('check'), '')
        for os_ in ('95OSR2', '95OSR21', '95OSR25', '98FE', '98SE', 'ME'):
            plan = lm.resolve(m, os_, 'PL', '', True, [])
            if os_.startswith('95'):
                now = [i for i in plan.order if m.find(i).get('reboot') == 'now']
                self.assertEqual(now, [], os_)
            else:  # 98 / Me plans carry no coordinator-only value at all
                self.assertFalse([i for i in plan.order if i in scoped], os_)
        # 950 / OSR1: dcom95 -> restart -> IE -> restart -> the rest -> final restart
        rest = ['ie55sp2-q810847-pl', 'msi20-9x', 'dx80-pl', 'vbrun6sp6', 'vcredist6sp6', 'mslu']
        for os_ in ('95RTM', '95OSR1'):
            plan = lm.resolve(m, os_, 'PL', '', True, [])
            self.assertEqual(plan.order, ['dcom95', 'ie55sp2-pl'] + rest, os_)
            self.assertNotIn('ws2-95', plan.why, os_)
            # still selectable through addons_options
            _, full, options, exclude = lm.selection(m, {'options': 'ws2-95'})
            plan = lm.resolve(m, os_, 'PL', '', full, options, exclude)
            self.assertEqual(plan.order, ['dcom95', 'ws2-95', 'ie55sp2-pl'] + rest, os_)
            self.assertEqual(plan.why['ws2-95'], 'option', os_)
        # 95 EN: DUN 1.4 needs ws2:2 and still pulls it in
        self.assertEqual(lm.resolve(m, '95RTM', 'EN', '', True, []).why.get('ws2-95'), 'needed')
        # OSR2 and later 95 keep it in the full pack
        for os_ in ('95OSR2', '95OSR21', '95OSR25'):
            self.assertEqual(lm.resolve(m, os_, 'PL', '', True, []).why.get('ws2-95'), 'full', os_)
        self.assertEqual(m.find('ws2-95').get('answer1'), 'Winsock2 Setup|1')
        bad = lm.Manifest.load()
        bad.find('ws2-95').keys['option_os'] = '95XYZ'
        self.assertTrue(any('unknown option_os 95XYZ' in e for e in lm.validate(bad)))
        bad = lm.Manifest.load()
        bad.find('msi20-9x').keys['reboot_setup'] = 'now'  # os=9X: also 98 / Me
        self.assertTrue(any('reboot_setup/check_setup only for Windows 95' in e for e in lm.validate(bad)))

    def test_ws2_needs_tcpip_and_osr2_runs_under_the_coordinator(self):
        # X470 95 OSR2.1 PL native (2026-10-27): no MSTCP instance after the
        # first boot's PnP, socket 10047, W95WS2 "TCP NOT currently installed"
        # boxes and the retry restart; MSBATCH's Run USOSAddons ran the chain
        # under Explorer next to the first desktop.
        m = lm.Manifest.load()
        self.assertEqual(lm.validate(m), [])
        self.assertEqual(m.find('ws2-95').get('requires'), 'tcpip')
        self.assertEqual([p.id for p in m.packages if p.get('requires')], ['ws2-95'])
        for os_ in ('95OSR2', '95OSR21', '95OSR25'):    # still in the OSR2 full pack
            self.assertEqual(lm.resolve(m, os_, 'PL', '', True, []).why.get('ws2-95'), 'full', os_)
        bad = lm.Manifest.load()
        bad.find('ws2-95').keys['requires'] = 'tcpip,ipx'
        self.assertTrue(any("requires 'ipx'" in e for e in lm.validate(bad)))
        src = (ROOT/'src/platform/win32_legacy/usosadd/main.c').read_text()
        probe = src[src.index('static int tcpip_present(char *how, int cap) {'):src.index('typedef DWORD (WINAPI *PFN_VSIZE)')]
        self.assertIn('"Enum\\\\Network\\\\MSTCP"', probe)
        self.assertIn('!ua_ieqn(drv, "NetTrans\\\\", 9)', probe)
        self.assertIn('"System\\\\CurrentControlSet\\\\Services\\\\Class\\\\"', probe)
        self.assertIn('reg_key_exists(HKEY_LOCAL_MACHINE, key)', probe)
        self.assertIn('LoadLibraryA("WSOCK32.DLL")', probe)
        self.assertIn('sock(2, 1, 6)', probe)
        self.assertIn('FreeLibrary(w);', probe)
        chain = src[src.index('static void run_chain(void)'):src.index('static void finish(void)')]
        pre = chain.index('if (*p->requires) {')
        # after the resume / installed / status / needs decisions, before files and commands
        for before in ('check = run_check(p);', 'if (*p->status)', 'ua_needs_met(&g_m, &g_p, &g_state, &g_sys, x, unmet'):
            self.assertLess(chain.index(before), pre, before)
        for after in ('if (!files_present(p))', 'g_state.tries[x]++;', 'ok = run_one(p, cmd);'):
            self.assertLess(pre, chain.index(after), after)
        block = chain[pre:chain.index('if (!files_present(p))')]
        self.assertIn('"TCP/IP not installed"', block)
        self.assertIn('set_why(x, UA_ST_SKIPPED,', block)
        self.assertIn('continue;', block)
        self.assertNotIn('restart()', block); self.assertNotIn('MessageBox', block)
        start = src[src.index('void __cdecl ua_start(void) {'):]
        self.assertIn('!coordinated_build(g_facts.minor,g_facts.build)||!display_boundary()', start)
        self.assertNotIn('!=950', start)
        build = src[src.index('static int coordinated_build(int minor, int build) {'):src.index('static int display_boundary(void) {')]
        self.assertIn('if (minor == 0) return build == 950 || build == 1111 || build == 1212 || build == 1214 || build == 1216;', build)
        # 98 FE / 98 SE (4.10) under the coordinator too; Me (4.90) not
        self.assertIn('return minor == 10 && (build == 1998 || build == 2222);', build)
        self.assertIn('g_facts.major!=4||!coordinated_build(', start)
        disp = src[src.index('static int display_boundary(void) {'):src.index('static int setup_busy(void)')]
        self.assertIn('if (exists("C:\\\\USOS9X\\\\VESALATE.BAT")) return exists("C:\\\\USOS9X\\\\VLATE.OK");', disp)
        # a Run start while USOSFB owns the chain does nothing and keeps the value
        defer = start[start.index('if(!g_setup_mode && !g_facts.nt && exists("C:\\\\USOS9X\\\\FIRSTBT.ON")'):]
        defer = defer[:defer.index('/* Coordinator only:')]
        self.assertIn('!exists("C:\\\\USOS9X\\\\FIRSTBT.ERR")', defer)
        self.assertIn('if(exists("C:\\\\USOS9X\\\\FIRSTBT.OK")){', defer)
        self.assertEqual(defer.count('unregister();'), 1)
        self.assertEqual(defer.count('ExitProcess(0);'), 2)
        self.assertLess(start.index('/* Coordinator only:'), start.index('register_run();'))
        self.assertLess(start.index(defer[:40]), start.index('window_open();'))

    def test_ie55_rundll_box_confirmed_and_runonce_watched(self):
        # X470 95 RTM PL (2026-10-27): ADDONS.LOG "dialog seen: RUNDLL"
        # (IEDKCS32.DLL,BrandCleanInstallStubs) during the IE 5.5 install.
        m = lm.Manifest.load()
        self.assertEqual(lm.validate(m), [])
        self.assertEqual(m.find('ie55sp2-pl').get('answer1'), 'RUNDLL|1')
        self.assertNotIn('RUNDLL', '\n'.join(v for s, k, v in m.entries if s == 'pack'))
        # the DCOM95 restart that fixed advpack / rpcrt4 stays
        self.assertEqual(m.find('dcom95').get('reboot_setup'), 'now')
        src = (ROOT/'src/platform/win32_legacy/usosadd/main.c').read_text()
        body = src[src.index('static DWORD spawn('):src.index('static int code_ok(')]
        self.assertIn('if (g_answer_pkg && GetTickCount() - watched >= 2000) {', body)
        self.assertIn('runonce_watch(0);', body)
        watch = src[src.index('static void runonce_watch(int start)'):src.index('static DWORD spawn(')]
        self.assertIn('"    RunOnce now (tick "', watch)
        self.assertNotIn('RegDeleteValue', watch)
        self.assertNotIn('RegSetValue', watch)
        chain = src[src.index('static void run_chain(void)'):]
        self.assertLess(chain.index('g_answer_pkg = p;'), chain.index('runonce_watch(1);'))
        self.assertLess(chain.index('runonce_watch(1);'), chain.index('ok = run_one(p, cmd);'))

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
        # 950: DCOM95 + IE restarts, a Q810847 retry and one spare
        self.assertIn('if(mid>=mid_limit())fail(', src)
        self.assertIn('static int mid_limit(void){return win98?9:4;}', src)
        self.assertIn('rundll32.exe C:\\\\WINDOWS\\\\SYSTEM\\\\iernonce.dll,RunOnceExProcess', src)
        self.assertIn('RegDeleteValueA(key,"PrimaryProvider")', src)
        # code 2 (nothing to remove) is "absent", not a failure (run 2026-10-27)
        self.assertIn('else if(code==ERROR_FILE_NOT_FOUND)lstrcpyA(line,"Network\\\\Logon PrimaryProvider absent");', src)
        final =src[src.index('if(!lstrcmpA(phase,"reboot\\r\\n")){'):src.index('mid=mid_phase(phase);')]
        self.assertLess(final.index('finish_runonceex();'), final.index('USOSADD.EXE /setup /check'))
        self.assertLess(final.index('windows_logon();'), final.index('FIRSTBT.OK'))
        tail = src[src.index('mid=mid_phase(phase);'):]
        # display request only on the first package pass, RunOnceEx before resuming
        self.assertLess(tail.index('finish_runonceex();'), tail.index('USOSADD.EXE /setup'))
        self.assertLess(tail.index('}else{'), tail.index('USOSRES.EXE /setup'))

    def test_coordinator_time_zone_ready_without_deferral(self):
        # X470 95 RTM native (2026-10-26): TZFIX.OK not-pending and no
        # TZDST.OK stopped the chain ("late real-mode preparation did not
        # complete"). Ready: TZDST.OK, or TZFIX.OK without TZDST.PND, or no TZFIX.
        src = (ROOT/'src/platform/win32_legacy/usosfb.c').read_text()
        body = src[src.index('static int tz_ready('):src.index('static int late_ready(')]
        self.assertIn('if(exists("TZDST.OK")||!exists("TZFIX.BAT"))return 1;', body)
        self.assertIn('return exists("TZFIX.OK")&&!exists("TZDST.PND");', body)
        self.assertEqual(src.count('!tz_ready()'), 2)
        self.assertNotIn('!exists("TZDST.OK")', src)
        self.assertIn('exists("TZFIX.BAD")', src[src.index('static int late_ready('):])

    def test_coordinator_failure_is_closable(self):
        src = (ROOT/'src/platform/win32_legacy/usosfb.c').read_text()
        body = src[src.index('static void fail('):src.index('static int setup_done(')]
        self.assertIn('MB_RETRYCANCEL|MB_ICONERROR|MB_SETFOREGROUND|MB_TOPMOST', body)
        # the box in the installed system's language: PL (0x15) or EN (OSR1)
        self.assertIn('(GetSystemDefaultLangID()&0x3ff)==0x15?fail_pl:fail_en', body)
        self.assertIn('static const char fail_en[]="USOS could not finish the installation.', src)
        self.assertIn('Retry = try again after a restart', src)
        self.assertIn('Cancel = go to the desktop', src)
        self.assertIn(r'static const char fail_pl[]="USOS nie m\363g\263 doko', src)
        self.assertIn('MoveFileA(path,aside)', body)
        self.assertIn('ExitWindowsEx(EWX_REBOOT,0)', body)
        # the box is a MessageBox, no own window; the only window is the
        # hidden WM_ENDSESSION listener (session_window), never visible
        self.assertNotIn('WS_POPUP', body)
        self.assertEqual(src.count('WS_POPUP'), 1)
        self.assertIn('"USOSFB",WS_POPUP,0,0,0,0,', src[src.index('static void session_window('):])
        self.assertNotIn('WS_VISIBLE', src)
        self.assertNotIn('WM_CLOSE', src)
        # an existing FIRSTBT.ERR exits quietly instead of showing the box every boot
        self.assertNotIn('fail("previous firstboot failure', src)

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
