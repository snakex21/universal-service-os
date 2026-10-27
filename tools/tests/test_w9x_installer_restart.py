"""Installer-initiated restarts inside the 95 / 98 first-desktop chain
(host-only; real Windows behaviour is X470 evidence).

X470 98 FE PL native, 2026-10-27: WMP 7.1's inner setup_wm.exe restarted
Windows itself inside USOSADD /setup (STATE.INI wmp71-pl=running:1). USOSFB
saw USOSADD end, took it for the end of the chain, restored Explorer, and
its own final ExitWindowsEx was rejected (a shutdown already in progress):
"restart request rejected" -> FIRSTBT.ERR, every later boot refused.

Here: the pure parts of usosfb.c (STATE.INI running entry, the phase
names) compiled for the host with zig cc; source checks for the restart
guard in USOSADD, the deferred retry, CHAIN.END and the coordinator's
handling of a rejected restart; the WMP 7.1 command line."""
from pathlib import Path
import os
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard  # noqa: E402

FB = ROOT / 'src/platform/win32_legacy/usosfb.c'
ADD = ROOT / 'src/platform/win32_legacy/usosadd/main.c'
PACK = ROOT / 'src/addons/legacy-pack.ini'


def section(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i)]


def func(src, head):
    """The one-line-header function starting with head, up to the next 'static '."""
    i = src.index(head)
    j = src.index('\nstatic ', i + 1)
    return src[i:j + 1]


HARNESS = r'''
#include <stdio.h>
#include <string.h>
static void lstrcpynA(char *d, const char *s, int n) { strncpy(d, s, n - 1); d[n - 1] = 0; }
static int lstrcmpA(const char *a, const char *b) { return strcmp(a, b); }
static int win98;
%s
%s
%s
%s
int main(int argc, char **argv)
{
    char why[64], text[2048];
    int i, n = 0;
    if (argc > 2 && !strcmp(argv[1], "s")) {
        /* STATE.INI text with \n escapes */
        for (i = 0; argv[2][i] && n < 2000; i++) {
            if (argv[2][i] == '\\' && argv[2][i + 1] == 'n') { text[n++] = '\r'; text[n++] = '\n'; i++; }
            else text[n++] = argv[2][i];
        }
        text[n] = 0;
        n = running_entry(text, why, sizeof why);
        printf("%%d %%s\n", n, why);
        return 0;
    }
    for (i = 2; i < argc; i++) {
        char phase[32];
        win98 = argv[1][0] == '8';
        snprintf(phase, sizeof phase, "%%s\r\n", argv[i]);
        printf("%%d ", mid_phase(phase));
    }
    printf("\n");
    return 0;
}
'''


class Coordinator(unittest.TestCase):
    src = FB.read_text(encoding='ascii')

    @classmethod
    def setUpClass(cls):
        s = cls.src
        contains_n = func(s, 'static int contains_n(')
        running = func(s, 'static int running_entry(')
        limit = func(s, 'static int mid_limit(void)')
        mid = section(s, 'static int mid_phase(const char*phase){', 'void __cdecl fb_start(')
        work = ROOT / 'zig-out/usosfb-restart-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS % (contains_n, running, limit, mid), encoding='ascii')
        cls.exe = work / ('harness.exe' if os.name == 'nt' else 'harness')
        zig = depguard.require_zig()
        subprocess.run([str(zig), 'cc', '-O1', '-Wall', '-Werror', '-Wno-unused-function', str(work / 'harness.c'),
                        '-o', str(cls.exe)], check=True, cwd=work, timeout=110,
                       env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})

    def run_h(self, *args):
        return subprocess.run([str(self.exe), *args], capture_output=True, text=True, check=True).stdout.strip()

    def test_running_entry_in_state_ini(self):
        # the X470 98 FE PL STATE.INI of 2026-10-27, shortened
        evidence = (r'; USOSADD state - written by C:\USOS\ADDONS\USOSADD.EXE\n[state]\nstarts=3\npending_reboot=1\n'
                    r'dcom98=done:1\nmslu=done:1\nwmp71-pl=running:1\n[why]\n')
        self.assertEqual(self.run_h('s', evidence), '1 wmp71-pl')
        self.assertEqual(self.run_h('s', r'[state]\nstarts=4\nnusb33-pl=RUNNING\n'), '1 nusb33-pl')
        self.assertEqual(self.run_h('s', r'[state]\nstarts=4\npending_reboot=0\ndcom98=done:1\nx=failed:2\n[why]\nx=error, exit code 2\n'), '0')
        self.assertEqual(self.run_h('s', r'; running=1\n[running]\n=running\nrun=runnin\n'), '0')
        self.assertEqual(self.run_h('s', ''), '0')

    def test_resume_phases_count_as_package_boundaries(self):
        self.assertEqual(self.run_h('8', 'mid1', 'mid9', 'resume1', 'resume9', 'resume0', 'late', 'install', 'reboot', 'resume10', 'resumeX'),
                         '1 9 1 9 0 0 0 0 0 0')
        self.assertEqual(self.run_h('5', 'mid4', 'mid5', 'resume4', 'resume5'), '4 0 4 0')

    def test_rejected_restart_writes_no_err_and_keeps_phase(self):
        body = section(self.src, 'static void reboot(', 'static DWORD child(const char*command){')
        self.assertNotIn('fail("restart request rejected")', self.src)
        self.assertIn('if(!ExitWindowsEx(EWX_REBOOT|EWX_FORCE,0))rejected();', body)
        # phase journalled and armed before the request
        self.assertLess(body.index('save("FIRSTBT.STA",phase)'), body.index('ExitWindowsEx(EWX_REBOOT|EWX_FORCE,0))rejected();'))
        rej = section(self.src, 'static void rejected(void){', 'static void reboot(')
        self.assertNotIn('FIRSTBT.ERR"', rej.replace('no FIRSTBT.ERR', ''))
        self.assertIn('MsgWaitForMultipleObjects(0,0,FALSE,60000-gone,QS_ALLINPUT)', rej)
        self.assertLess(rej.index('MsgWaitForMultipleObjects'), rej.index('fail("restart request rejected twice")'))

    def test_open_chain_is_a_package_restart(self):
        start = self.src[self.src.index('void __cdecl fb_start(void){'):]
        tail = start[start.index('code=child("C:\\\\USOS\\\\ADDONS\\\\USOSADD.EXE /setup");'):]
        self.assertIn('if(code!=1001){char why[64],line[200];int open=chain_open(why,sizeof why);', tail)
        self.assertIn('if(open==1||(open==2&&(code==0||code==3010))){', tail)
        self.assertLess(tail.index('code=1001;}}'), tail.index('if(code==1001){'))
        self.assertLess(tail.index('if(code==1001){'), tail.index('reboot("reboot\\r\\n"'))
        chain = section(self.src, 'static int chain_open(', '/* FIRSTBT.STA phases')
        self.assertIn('C:\\\\USOS\\\\ADDONS\\\\STATE.INI', chain)
        self.assertIn('C:\\\\USOS\\\\ADDONS\\\\CHAIN.END', chain)

    def test_session_end_under_a_child_keeps_the_boundary(self):
        proc = section(self.src, 'static LRESULT CALLBACK session_proc(', 'static void session_window(')
        self.assertIn('if(msg==WM_ENDSESSION&&wp&&running){', proc)
        self.assertIn('arm();drop("SHELLRUN.FLG");', proc)
        self.assertNotIn('WM_QUERYENDSESSION', proc)  # never refuses a restart itself
        start = self.src[self.src.index('void __cdecl fb_start(void){'):]
        self.assertLess(start.index('session_window();'), start.index('coordinator entered before desktop'))
        child = section(self.src, 'static DWORD child(const char*command){', 'static int legacy_absent(')
        self.assertIn('running=command;', child)
        self.assertIn('running=0;return code;}', child)


class Runner(unittest.TestCase):
    src = ADD.read_text(encoding='latin-1')

    def test_guard_refuses_only_while_a_package_runs(self):
        proc = section(self.src, 'static LRESULT CALLBACK guard_proc(', 'static void guard_open(')
        self.assertIn('if (msg == WM_QUERYENDSESSION) {', proc)
        self.assertIn('if (!g_guard_pkg) return TRUE;', proc)
        self.assertIn('log2("    installer restart refused: ", g_guard_pkg->id);', proc)
        self.assertIn('return FALSE;', proc)
        opened = section(self.src, 'static void guard_open(', 'static void guard_off(')
        self.assertIn('WS_POPUP, 0, 0, 0, 0, 0, 0, inst, 0)', opened)  # hidden top-level
        self.assertNotIn('WS_VISIBLE', opened)
        chain = section(self.src, 'static void run_chain(void) {', 'static void finish(void) {')
        self.assertIn('if (g_setup_mode) g_guard_pkg = p;', chain)
        self.assertLess(chain.index('if (g_setup_mode) g_guard_pkg = p;'), chain.index('ok = run_one(p, cmd);'))
        self.assertLess(chain.index('ok = run_one(p, cmd);'), chain.index('g_guard_pkg = 0;'))
        self.assertIn('g_restart_asked = 1;', chain[chain.index('if (g_restart_refused) {'):])
        start = self.src[self.src.index('void __cdecl ua_start(void) {'):]
        block = start[start.index('    if (g_setup_mode) {\n        path_join(path, g_root, "CHAIN.END");'):]
        self.assertLess(block.index('DeleteFileA(path);'), block.index('guard_open();'))
        self.assertLess(block.index('guard_open();'), block.index('run_chain();'))

    def test_own_restart_paths_take_the_guard_down_first(self):
        restart = section(self.src, 'static void restart(void) {', '/* ---- the chain')
        self.assertLess(restart.index('guard_off();'), restart.index('ExitProcess(1001);'))
        self.assertLess(restart.index('guard_off();'), restart.index('ExitWindowsEx('))
        fin = section(self.src, 'static void finish(void) {', '/* ---- entry')
        setup = fin[fin.index('    if (g_setup_mode) {'):]
        self.assertLess(setup.index('guard_off();'), setup.index('ExitProcess('))
        self.assertLess(setup.index('"CHAIN.END"'), setup.index('ExitProcess('))

    def test_retry_after_restart_deferred_to_the_end_in_setup(self):
        chain = section(self.src, 'static void run_chain(void) {', 'static void finish(void) {')
        retry = chain[chain.index('if (after == UA_AFTER_RETRY) {'):]
        self.assertLess(retry.index('if (g_setup_mode) {'), retry.index('restart();'))
        self.assertIn('g_deferred[x] = 1;', retry)
        self.assertIn('ua_deferred_provides(&g_p, g_deferred, unmet)', chain)
        self.assertLess(chain.index('ua_deferred_provides('), chain.index('set_why(x, UA_ST_SKIPPED, g_pl ? "wymaga " : "needs ", unmet);'))
        end = chain[chain.rindex('for (pos = 0; pos < g_p.count && !g_deferred[pos]; pos++) ;'):]
        self.assertIn('restart();', end)

    def test_resume_of_a_running_package_is_logged(self):
        chain = section(self.src, 'static void run_chain(void) {', 'static void finish(void) {')
        body = chain[chain.index('if (st == UA_ST_RUNNING) {'):chain.index('} else if (check == 1) {')]
        self.assertIn('ua_resume_decision(g_state.tries[x], check >= 0, check == 1)', body)
        self.assertIn('left running', body)


class SkippedMissing(unittest.TestCase):
    """Product decision 2026-10-28: a package whose files are not on the
    media (X470 98 FE PL: 13 hf98x-* hotfixes absent from the Kingston
    DATA\\Addons\\Win98) never blocks the first desktop."""
    src = ADD.read_text(encoding='latin-1')
    fb = FB.read_text(encoding='latin-1')

    def test_missing_files_are_skipped_missing_not_skipped(self):
        chain = section(self.src, 'static void run_chain(void) {', 'static void finish(void) {')
        self.assertIn('if (!files_present(p)) { set_why(x, UA_ST_MISSING,', chain)
        self.assertNotIn('if (!files_present(p)) { set_why(x, UA_ST_SKIPPED,', chain)
        # a state already decided is never re-run on resume
        self.assertIn('st == UA_ST_SKIPPED || st == UA_ST_MISSING) continue;', chain)

    def test_dependents_of_a_missing_package_follow_it(self):
        chain = section(self.src, 'static void run_chain(void) {', 'static void finish(void) {')
        needs = chain[chain.index('if (!ua_needs_met(&g_m, &g_p, &g_state, &g_sys, x, unmet, sizeof unmet)) {'):]
        dep = needs.index('if (ua_missing_provides(&g_p, &g_state, unmet)) {')
        self.assertLess(needs.index('ua_deferred_provides('), dep)
        self.assertLess(dep, needs.index('set_why(x, UA_ST_SKIPPED, g_pl ? "wymaga " : "needs ", unmet);'))
        self.assertIn('set_why(x, UA_ST_MISSING,', needs[dep:dep + 300])
        group = chain[chain.index('if (p->tier == UA_TIER_GROUP) {'):]
        self.assertIn('ua_missing_provides(&g_p, &g_state, unmet) ? UA_ST_MISSING : UA_ST_SKIPPED', group[:400])

    def test_setup_exit_code_ignores_skipped_missing(self):
        fin = section(self.src, 'static void finish(void) {', '/* ---- entry')
        self.assertIn('else { skipped++; if (st == UA_ST_MISSING) missing++; }', fin)
        self.assertIn('ExitProcess(failed || skipped > missing ? 2 : g_state.pending_reboot ? 3010 : 0);', fin)
        self.assertNotIn('ExitProcess(failed || skipped ? 2', fin)
        # still listed in the log with its reason
        self.assertIn('st != UA_ST_FAILED && st != UA_ST_SKIPPED && st != UA_ST_MISSING) continue;', fin)

    def test_final_check_ignores_skipped_missing(self):
        start = self.src[self.src.index('void __cdecl ua_start(void) {'):]
        chk = start[start.index('if(g_setup_mode && exact_switch(cmdline,"check")){'):]
        chk = chk[:chk.index('ExitProcess(failed?2:0);')]
        self.assertLess(chk.index('if(g_state.st[x]==UA_ST_MISSING)'), chk.index('check=run_check(p);'))
        self.assertIn('continue;}', chk[chk.index('if(g_state.st[x]==UA_ST_MISSING)'):chk.index('check=run_check(p);')])

    def test_coordinator_takes_exit_0_or_3010_to_the_final_restart(self):
        body = self.fb[self.fb.index('code=child("C:\\\\USOS\\\\ADDONS\\\\USOSADD.EXE /setup");'):]
        self.assertLess(body.index('if(code!=0&&code!=3010)fail('), body.index('reboot("reboot\\r\\n"'))
        self.assertIn('child("C:\\\\USOS\\\\ADDONS\\\\USOSADD.EXE /setup /check")!=0', self.fb)

    def test_state_name_round_trips(self):
        state = (ROOT / 'src/platform/win32_legacy/usosadd/state.c').read_text(encoding='latin-1')
        self.assertIn('"skipped", "skipped-missing" };', state)
        self.assertIn('k <= UA_ST_MISSING; k++', state)


class Manifest(unittest.TestCase):
    def test_wmp71_inner_setup_gets_no_reboot(self):
        text = PACK.read_text(encoding='utf-8')
        body = section(text, '[pkg:wmp71-pl]', '\n[pkg:')
        run = re.search(r'^run1=(.*)$', body, re.M).group(1).strip()
        # ADMQCMD/USRQCMD are "setup_wm.exe /Quiet"; setup_wm's own /R:N
        # (case-sensitive) presses Cancel instead of its rebooting Finish
        self.assertEqual(run, r'%PKG%\MP71.EXE /Q:A /R:N /C:"setup_wm.exe /Quiet /R:N"')
        self.assertNotIn('DisallowSystemRestore', run)
        self.assertIn('\nreboot=end', body)


if __name__ == '__main__':
    unittest.main()
