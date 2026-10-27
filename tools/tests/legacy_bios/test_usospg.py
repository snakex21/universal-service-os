"""USOSPG.DRV (src/platform/bios/win9x/usospg.c): Windows 98 / 98 SE Setup's
pages that MSBATCH.INF already filled (user information, licence, product
key, the last "Finish" page), moved on by a Win16 installable driver in
Setup's own mini-Windows (native phase 1, automatic mode only).

Always: the decisions of usospg_logic.h compiled for the host with zig cc
(mode file, page kinds, the tick state machine), source checks (what the
driver reads and logs, never the key's text) and the target script's
staging. With the user's 98 PL / 98 SE PL OEM media (read-only, extracted
to a temporary folder with 7-Zip): the SETUPX.DLL / KOMMCTRL.DLL / SUWIN.EXE
dialog templates carry exactly the control IDs the driver looks for, and
only the expected pages match a kind. With the pinned OpenWatcom: the driver
builds without the C runtime, imports KERNEL / USER only, every import
resolves in the 98 / 98 SE mini-Windows, and MINI.CAB takes it."""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import depguard  # noqa: E402

SRC = ROOT / 'src/platform/bios/win9x'
LOGIC = SRC / 'usospg_logic.h'
DRIVER = SRC / 'usospg.c'
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'
MEDIA98 = {'98-pl': 'Windows 98/Windows 98 PL.iso', '98se-pl': 'Windows 98 SE/Windows 98 SE PL OEM.iso'}

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usospg_logic.h"
/* c TEXT: pg_cfg_auto ("\n" in TEXT = LF, "\r" = CR); k FLAGS: pg_classify,
 * FLAGS = title name org eula_text eula_yes eula_no key_edits clickable
 * next_shown finish_shown (one digit each); s TICK...: pg_step, TICK =
 * expired active page kind filled accepted declined next_ready (digits;
 * page 0 = none), prints "action/event" per tick; a TICK of D = DRV_DISABLE
 * (a pause: nothing changes, prints "p"), E = DRV_ENABLE (prints "e" and
 * pg_may_start), F = DRV_FREE (pg_end, prints "f"); a W ARMED... :
 * pg_arm_slot for window W, ARMED = window/alive pairs ("3/1"), prints
 * "slot already"; r N: pg_rec_allow N + 2 times, prints the results;
 * h VK EDIT: pg_key_hidden; d V: pg_u32_dec; m EV...: PGMOVES, EV =
 * "x,y,ms" (a move) or "?ms" / "!ms" (pg_move_due / forced; when due
 * prints "n/still/dist/span" and resets, else "-"); o PAGE/STATE...:
 * pg_radio_note per pair. */
int main(int argc, char **argv)
{
    int i;
    if (argv[1][0] == 'c') {
        unsigned char buf[128];
        int n = 0;
        const char *s = argv[2];
        while (*s && n < 128) {
            if (s[0] == '\\' && s[1] == 'n') { buf[n++] = '\n'; s += 2; }
            else if (s[0] == '\\' && s[1] == 'r') { buf[n++] = '\r'; s += 2; }
            else buf[n++] = (unsigned char)*s++;
        }
        printf("%d\n", pg_cfg_auto(buf, n));
    } else if (argv[1][0] == 'k') {
        PGSHAPE p;
        const char *f = argv[2];
        p.title = f[0] - '0'; p.name = f[1] - '0'; p.org = f[2] - '0'; p.eula_text = f[3] - '0';
        p.eula_yes = f[4] - '0'; p.eula_no = f[5] - '0'; p.key_edits = f[6] - '0'; p.clickable = f[7] - '0';
        p.next_shown = f[8] - '0'; p.finish_shown = f[9] - '0';
        printf("%d\n", pg_classify(&p));
    } else if (argv[1][0] == 'r') {
        unsigned lines = 0;
        int n = atoi(argv[2]);
        for (i = 0; i < n + 2; i++) printf("%d", pg_rec_allow(&lines));
        printf("\n");
    } else if (argv[1][0] == 'h') {
        printf("%d\n", pg_key_hidden((unsigned)strtoul(argv[2], 0, 0), atoi(argv[3])));
    } else if (argv[1][0] == 'd') {
        char out[16];
        int n = pg_u32_dec(out, strtoul(argv[2], 0, 10));
        out[n] = 0;
        printf("%s\n", out);
    } else if (argv[1][0] == 'm') {
        PGMOVES m;
        memset(&m, 0, sizeof(m));
        for (i = 2; i < argc; i++) {
            const char *f = argv[i];
            if (f[0] == '?' || f[0] == '!') {
                unsigned long now = strtoul(f + 1, 0, 10);
                if (pg_move_due(&m, now, f[0] == '!')) {
                    printf("%u/%u/%lu/%lu ", m.n, m.still, m.dist, (unsigned long)(unsigned)(now - m.since));
                    pg_move_reset(&m);
                } else printf("- ");
            } else {
                int x, y;
                unsigned long ms;
                sscanf(f, "%d,%d,%lu", &x, &y, &ms);
                pg_move_add(&m, x, y, ms);
            }
        }
        printf("\n");
    } else if (argv[1][0] == 'o') {
        PGRADIO r;
        memset(&r, 0, sizeof(r));
        for (i = 2; i < argc; i++)
            printf("%d", pg_radio_note(&r, (unsigned short)atoi(argv[i]), (unsigned char)atoi(strchr(argv[i], '/') + 1)));
        printf("\n");
    } else if (argv[1][0] == 'a') {
        unsigned short armed[16];
        unsigned char alive[16];
        int n = 0, already, slot;
        for (i = 3; i < argc && n < 16; i++, n++) {
            armed[n] = (unsigned short)atoi(argv[i]);
            alive[n] = (unsigned char)(strchr(argv[i], '/')[1] - '0');
        }
        slot = pg_arm_slot(armed, alive, n, (unsigned short)atoi(argv[2]), &already);
        printf("%d %d\n", slot, already);
    } else {
        PGSTATE s;
        memset(&s, 0, sizeof(s));
        for (i = 2; i < argc; i++) {
            PGVIEW v;
            const char *f = argv[i];
            unsigned char a;
            if (f[0] == 'D') { printf("%sp", i > 2 ? " " : ""); continue; }
            if (f[0] == 'E') { printf("%se%d", i > 2 ? " " : "", pg_may_start(&s)); continue; }
            if (f[0] == 'F') { pg_end(&s); printf("%sf", i > 2 ? " " : ""); continue; }
            v.expired = f[0] - '0'; v.active = f[1] - '0'; v.page = (unsigned short)(f[2] - '0');
            v.kind = f[3] - '0'; v.filled = f[4] - '0'; v.accepted = f[5] - '0'; v.declined = f[6] - '0';
            v.next_ready = f[7] - '0';
            a = pg_step(&s, &v);
            printf("%s%d/%d", i > 2 ? " " : "", a, s.event);
        }
        printf("\n");
    }
    return 0;
}
'''

OTHER, USER, EULA, KEY, FINISH = 0, 1, 2, 3, 4
NONE, NEXT, FIN, ACCEPT, STOP = 0, 1, 2, 3, 4
E_NONE, E_LEFT, E_NO_NEXT, E_STUCK, E_TIMEOUT = 0, 1, 2, 3, 4


def tick(page=0, kind=OTHER, filled=0, accepted=0, declined=0, next_ready=0, active=1, expired=0):
    return f'{expired}{active}{page}{kind}{filled}{accepted}{declined}{next_ready}'


class Logic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig()
        work = ROOT / 'zig-out/usospg-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS)
        cls.exe = work / 'usospg.exe'
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-O1', '-Wall', '-Werror', '-I', str(SRC),
                        str(work / 'harness.c'), '-o', str(cls.exe)], check=True,
                       env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})

    def run_exe(self, *args):
        return subprocess.run([str(self.exe), *args], capture_output=True, text=True, check=True).stdout.strip()

    def steps(self, *ticks):
        return [tuple(int(x) for x in t.split('/')) for t in self.run_exe('s', *ticks).split()]

    def test_mode_file(self):
        for text, want in (('mode=auto\\r\\n', 1), ('MODE=Auto', 1), ('; USOS\\r\\nmode=auto\\n', 1), ('mode=auto \\r\\n', 1),
                           ('mode=manual\\r\\n', 0), ('mode=autox', 0), (' mode=auto', 0), ('', 0), ('xmode=auto', 0)):
            with self.subTest(text=text):
                self.assertEqual(self.run_exe('c', text), str(want))

    def test_page_kinds(self):
        # title name org eula_text eula_yes eula_no key_edits clickable next finish
        for flags, want in (('1110000210', USER),       # dialog 112
                            ('1001110310', EULA),       # dialog 600
                            ('1000005910', KEY),        # dialog 607 / 608 (+ the keyboard helper buttons)
                            ('1000003310', OTHER),      # COA 604 / 387: three Edits only
                            ('1000000001', FINISH),     # dialog 4205 with Finish
                            ('1000000010', OTHER),      # 4203 / 4204 / 1201 / SUWIN 386: Next
                            ('1000000011', OTHER),      # both shown: not the last page
                            ('1000000101', OTHER),      # something to click on the page
                            ('0000000001', OTHER),      # no title
                            ('1100000110', OTHER),      # name without company
                            ('1001100210', OTHER)):     # licence without "do not accept"
            with self.subTest(flags=flags):
                self.assertEqual(self.run_exe('k', flags), str(want))

    def test_filled_user_page_goes_to_next_after_it_settled(self):
        page = tick(1, USER, filled=1, next_ready=1)
        got = self.steps(*[page] * 6)
        self.assertEqual([a for a, _ in got], [NONE] * 4 + [NEXT, NONE])
        # Setup's own batch mode moved on first: nothing pressed
        self.assertEqual([a for a, _ in self.steps(page, page, tick(2, KEY, filled=1, next_ready=1))], [NONE] * 3)

    def test_empty_page_is_left_to_the_user_for_good(self):
        empty = tick(1, USER, filled=0, next_ready=1)
        typed = tick(1, USER, filled=1, next_ready=1)
        got = self.steps(*[empty] * 5, *[typed] * 10)
        self.assertEqual(got[4], (NONE, E_LEFT))
        self.assertTrue(all(a == NONE for a, _ in got))
        # an incomplete key the same
        got = self.steps(*[tick(3, KEY, filled=0, next_ready=1)] * 8)
        self.assertEqual(got[4], (NONE, E_LEFT))
        self.assertTrue(all(a == NONE for a, _ in got))

    def test_licence_accept_then_next(self):
        before = tick(4, EULA, filled=1, next_ready=0)
        after = tick(4, EULA, filled=1, accepted=1, next_ready=1)
        self.assertEqual([a for a, _ in self.steps(*[before] * 5, after, after)], [NONE] * 4 + [ACCEPT, NEXT, NONE])
        # already accepted: straight to Next
        self.assertEqual([a for a, _ in self.steps(*[after] * 5)], [NONE] * 4 + [NEXT])
        # declined by the user: never touched
        declined = tick(4, EULA, filled=1, declined=1, next_ready=1)
        got = self.steps(*[declined] * 8)
        self.assertEqual(got[4], (NONE, E_LEFT))
        self.assertTrue(all(a == NONE for a, _ in got))
        # the accept does not take: given up, never pressed
        got = self.steps(*[before] * 20)
        self.assertEqual([a for a, _ in got].count(ACCEPT), 1)
        self.assertIn((NONE, E_NO_NEXT), got)
        self.assertNotIn(NEXT, [a for a, _ in got])

    def test_finish(self):
        self.assertEqual([a for a, _ in self.steps(*[tick(5, FINISH, filled=1)] * 7)], [NONE] * 4 + [FIN, NONE, NONE])
        # Finish disabled: left alone
        got = self.steps(*[tick(5, FINISH, filled=0)] * 6)
        self.assertEqual(got[4], (NONE, E_LEFT))

    def test_next_disabled_waits_then_gives_up(self):
        off = tick(1, USER, filled=1, next_ready=0)
        got = self.steps(*[off] * 20)
        self.assertNotIn(NEXT, [a for a, _ in got])
        self.assertIn((NONE, E_NO_NEXT), got)
        on = tick(1, USER, filled=1, next_ready=1)
        self.assertEqual([a for a, _ in self.steps(*[off] * 7, on)][-1], NEXT)

    def test_page_that_stays_after_next_is_not_pressed_again(self):
        page = tick(3, KEY, filled=1, next_ready=1)
        got = self.steps(*[page] * 40)
        self.assertEqual([a for a, _ in got].count(NEXT), 1)
        self.assertIn((NONE, E_STUCK), got)
        # and after another page it stays left alone
        got = self.steps(*[page] * 30, tick(1, USER, filled=1, next_ready=1), *[page] * 10)
        self.assertEqual([a for a, _ in got].count(NEXT), 1)

    def test_next_page_gets_its_own_turn(self):
        user = tick(1, USER, filled=1, next_ready=1)
        eula = tick(2, EULA, filled=1, next_ready=0)
        eula_ok = tick(2, EULA, filled=1, accepted=1, next_ready=1)
        key = tick(3, KEY, filled=1, next_ready=1)
        fin = tick(4, FINISH, filled=1)
        got = [a for a, _ in self.steps(*[user] * 5, *[eula] * 5, eula_ok, *[key] * 5, *[fin] * 5)]
        self.assertEqual([a for a in got if a != NONE], [NEXT, ACCEPT, NEXT, NEXT, FIN])

    def test_inactive_or_no_page_changes_nothing_and_times_out(self):
        page = tick(1, USER, filled=1, next_ready=1)
        behind = tick(1, USER, filled=1, next_ready=1, active=0)
        self.assertEqual([a for a, _ in self.steps(*[behind] * 10)], [NONE] * 10)
        self.assertEqual(self.steps(tick(), tick(), tick(expired=1), page),
                         [(NONE, 0), (NONE, 0), (STOP, E_TIMEOUT), (STOP, 0)])


    def test_disable_enable_is_a_pause(self):
        # X470 98 FE PL 2026-10-27: DRV_DISABLE after the first two pages ended
        # the driver; now a pause, every page after it still gets its turn
        user = tick(1, USER, filled=1, next_ready=1)
        eula = tick(2, EULA, filled=1, next_ready=0)
        eula_ok = tick(2, EULA, filled=1, accepted=1, next_ready=1)
        key = tick(3, KEY, filled=1, next_ready=1)
        fin = tick(4, FINISH, filled=1)
        out = self.run_exe('s', *[user] * 5, 'D', 'E', *[eula] * 5, eula_ok, 'D', 'E', 'D', 'E',
                           *[key] * 5, 'D', 'E', *[fin] * 5).split()
        self.assertEqual([t for t in out if t[0] in 'pe'], ['p', 'e1'] * 4)
        acts = [int(t.split('/')[0]) for t in out if '/' in t]
        self.assertEqual([a for a in acts if a != NONE], [NEXT, ACCEPT, NEXT, NEXT, FIN])
        # a page pressed before the pause is not pressed again after it
        out = self.run_exe('s', *[key] * 5, 'D', 'E', *[key] * 10).split()
        self.assertEqual([int(t.split('/')[0]) for t in out if '/' in t].count(NEXT), 1)
        # pages left to the user stay left after the pause
        empty = tick(1, USER, filled=0, next_ready=1)
        out = self.run_exe('s', *[empty] * 5, 'D', 'E', *[user] * 8).split()
        self.assertNotIn(NEXT, [int(t.split('/')[0]) for t in out if '/' in t])

    def test_free_and_timeout_end_for_good(self):
        user = tick(1, USER, filled=1, next_ready=1)
        self.assertEqual(self.run_exe('s', 'F', 'E', user).split(), ['f', 'e0', f'{STOP}/0'])
        self.assertEqual(self.run_exe('s', tick(expired=1), 'D', 'E', user).split(),
                         [f'{STOP}/{E_TIMEOUT}', 'p', 'e0', f'{STOP}/0'])

    def test_arm_slots(self):
        def arm(w, *armed):
            slot, already = self.run_exe('a', str(w), *armed).split()
            return int(slot), int(already)
        self.assertEqual(arm(7, '0/0', '0/0'), (0, 0))
        self.assertEqual(arm(7, '3/1', '7/1', '0/0'), (1, 1))
        self.assertEqual(arm(9, '3/1', '7/1', '0/0'), (2, 0))
        # windows that are gone give their slot back (a dead 9 is not "already")
        self.assertEqual(arm(9, '3/1', '9/0', '5/1'), (1, 0))
        self.assertEqual(arm(9, '3/1', '4/1', '5/1'), (-1, 0))


    # ---- the input recorder (usospg_logic.h)
    def test_line_limit(self):
        self.assertEqual(self.run_exe('r', '2000'), '1' * 2000 + '20')

    def test_typing_keys_in_an_edit_are_hidden(self):
        for vk in (0x20, 0x30, 0x39, 0x41, 0x5A, 0x60, 0x6F, 0xBA, 0xC0, 0xDB, 0xDF, 0xE2):
            with self.subTest(vk=hex(vk)):
                self.assertEqual(self.run_exe('h', hex(vk), '1'), '1')
                self.assertEqual(self.run_exe('h', hex(vk), '0'), '0')
        # Tab, Enter, Esc, Backspace, Shift, Ctrl, Alt, arrows, F1, Delete keep their code
        for vk in (0x09, 0x0D, 0x1B, 0x08, 0x10, 0x11, 0x12, 0x25, 0x28, 0x70, 0x2E):
            with self.subTest(vk=hex(vk)):
                self.assertEqual(self.run_exe('h', hex(vk), '1'), '0')

    def test_decimal(self):
        for v in ('0', '7', '10', '65535', '65536', '1800000', '4294967295'):
            self.assertEqual(self.run_exe('d', v), v)

    def test_moves_summary(self):
        # nothing moved: never due, not even forced
        self.assertEqual(self.run_exe('m', '?100', '!200'), '- -')
        # 3 moves (one still), due 5 s after the first one
        self.assertEqual(self.run_exe('m', '10,10,1000', '13,6,2000', '13,6,3000', '?5999', '?6000', '?9000'),
                         '- 3/1/7/5000 -')
        # the next window starts at its first move; the last position is kept
        self.assertEqual(self.run_exe('m', '0,0,0', '?5000', '0,0,7000', '!7500'), '1/0/0/5000 1/1/0/500')
        # GetTickCount wraps
        self.assertEqual(self.run_exe('m', '1,1,4294967000', '?4703', '?4704'), '- 1/0/0/5000')

    def test_licence_radio_changes(self):
        self.assertEqual(self.run_exe('o', '5/0', '5/0', '5/1', '5/1', '6/1', '6/2'), '101011')


class Source(unittest.TestCase):
    def test_driver_reads_and_logs(self):
        c = DRIVER.read_text(encoding='utf-8')
        self.assertTrue(c.isascii())
        self.assertIn('#define CFG_FILE  "C:\\\\USOS9X\\\\USOSPG.CFG"', c)
        self.assertIn('#define LOG_FILE  "C:\\\\USOS9X\\\\USOSPG.TXT"', c)
        self.assertIn('if (!read_cfg()) return 0L;', c)
        # the key fields: only their lengths, never their text
        self.assertNotIn('GetWindowText(GetDlgItem(c, PG_KEY1_ID', c)
        self.assertEqual(c.count('GetWindowText('), 2)
        self.assertIn('GetWindowText(GetDlgItem(page, PG_TITLE_ID), title, sizeof(title))', c)
        # the recorder reads text only through rec_text: Buttons, Statics, dialogs, top-level windows
        rec = c[c.index('static int rec_text(HWND w)'):c.index('static int rec_begin(const char *what)')]
        self.assertIn('if (is_child(w) && !class_is(w, "Button") && !class_is(w, "Static") && !class_is(w, "#32770")) return 0;', rec)
        self.assertIn('n = GetWindowText(w, rtext, sizeof(rtext));', rec)
        key = c[c.index('static void rec_key(UINT vk, LPARAM flags)'):c.index('LRESULT FAR PASCAL __export __loadds mouse_proc(')]
        self.assertIn('int in_edit = f && (class_is(f, "Edit") || class_is(f, "ComboBox"));', key)
        self.assertIn('if (pg_key_hidden(vk, in_edit)) rput("char");', key)
        # the hooks pass everything on and go with the CBT hook (pause and stop)
        for hook in ('mouse_proc', 'key_proc'):
            fn = c[c.index(f'LRESULT FAR PASCAL __export __loadds {hook}('):]
            fn = fn[:fn.index('return r;')]
            self.assertIn('LRESULT r = CallNextHookEx(', fn)
            self.assertIn('code == HC_ACTION', fn)
            self.assertNotIn('PostMessage', fn)
        pause = c[c.index('static void pause_all(void)'):c.index('static void stop_all(void)')]
        self.assertIn('rec_unhook();', pause)
        self.assertIn('if (mouse_hook) { UnhookWindowsHookEx(mouse_hook); mouse_hook = 0; }', c)
        self.assertIn('if (key_hook) { UnhookWindowsHookEx(key_hook); key_hook = 0; }', c)
        self.assertEqual(c.count('PostMessage('), 3)
        self.assertEqual(c.count('CheckRadioButton('), 1)
        self.assertIn('GetWindowTextLength(GetDlgItem(c, PG_KEY1_ID + i)) == PG_KEY_PART_LEN', c)
        # the buttons go to the frame as their BN_CLICKED; the licence radio to its page
        tick_fn = c[c.index('void FAR PASCAL __export __loadds tick('):c.index('static int is_frame(HWND w)')]
        # X470 98 FE run 3: DRV_DISABLE only at the mini-Windows' end: logged, timers and hooks kept;
        # only DRV_FREE (logged) / the timeout / WEP stop
        proc = c[c.index('LRESULT FAR PASCAL __export __loadds DriverProc('):c.index('int FAR PASCAL __export __loadds WEP(')]
        disable = proc[proc.index('case DRV_DISABLE:'):proc.index('case DRV_FREE:')]
        self.assertNotIn('pause_all', disable)
        self.assertNotIn('stop_all', disable)
        self.assertNotIn('KillTimer', disable)
        self.assertIn('say("disable (kept running until DRV_FREE)");', disable)
        self.assertIn('say("enable");', proc)
        free = proc[proc.index('case DRV_FREE:'):proc.index('case DRV_OPEN:')]
        self.assertIn('say("free, stopped");', free)
        self.assertIn('stop_all();', free)
        start_fn = c[c.index('static int start(void)'):c.index('LRESULT FAR PASCAL __export __loadds DriverProc(')]
        self.assertNotIn('st.done', start_fn)
        self.assertIn('rec_hook();', start_fn)
        self.assertIn('if (cbt_hook || !pg_may_start(&st)) return 1;', start_fn)
        self.assertIn('arm(GetActiveWindow());', start_fn)
        # only wizard frames are armed, a full table is logged
        arm_fn = c[c.index('static void arm(HWND w)'):c.index('LRESULT FAR PASCAL __export __loadds cbt_proc(')]
        self.assertIn('if (!w || !is_frame(w)) return;', arm_fn)
        self.assertIn('say("no slot, frame not armed");', arm_fn)
        self.assertIn('put("USOSPG arm ");', arm_fn)
        self.assertIn('PostMessage(w, WM_COMMAND, PG_NEXT_ID, MAKELPARAM(next, BN_CLICKED));', tick_fn)
        self.assertIn('PostMessage(w, WM_COMMAND, PG_FINISH_ID, MAKELPARAM(finish, BN_CLICKED));', tick_fn)
        self.assertIn('CheckRadioButton(page, PG_EULA_YES_ID, PG_EULA_NO_ID, PG_EULA_YES_ID);', tick_fn)
        self.assertIn('PostMessage(page, WM_COMMAND, PG_EULA_YES_ID, MAKELPARAM(radio, BN_CLICKED));', tick_fn)
        # nothing at WEP but stopping; nothing on the stack handed out by address (SS != DS)
        wep = c[c.index('int FAR PASCAL __export __loadds WEP('):]
        self.assertNotIn('OpenFile', wep)
        self.assertNotIn('say(', wep)
        for banned in ('OutputDebugString', 'wsprintf', 'MessageBox', 'WinExec', 'keybd_event', 'SetWindowText'):
            self.assertNotIn(banned, c)

    def test_staged_with_the_win9x_support(self):
        import build_win9x_support as b
        self.assertIn('USOSPG.DRV', b.STAGED)
        self.assertNotIn('USOSPG.DRV', b.FILES)          # not in the Legacy Core RAM disk list
        self.assertEqual(b.USOSPG_IMPORTS, {'KERNEL', 'USER'})
        self.assertIn("'EFI/USOS/dos-native/win9x/USOSPG.DRV'",
                      (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8'))
        self.assertIn('{`zig-out/dos-native/win9x/USOSPG.DRV`, `EFI/USOS/dos-native/win9x/USOSPG.DRV`}',
                      (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))
        self.assertIn('payload_zip\tEFI/USOS/dos-native/win9x/USOSPG.DRV\n',
                      (ROOT / 'tools/tests/golden/staged_payloads.tsv').read_text(encoding='utf-8'))


def _sh():
    import test_w9x_phase1_qemu as q
    return q


AUTO = (b'[Setup]\r\nExpress=1\r\nInstallDir="C:\\WINDOWS"\r\nShowEula=0\r\nProductKey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\r\n'
        b'[NameAndOrg]\r\nName="ja"\r\n')
MANUAL = b'; Manual Setup\r\n;USOS-SETUP=manual\r\n[Setup]\r\nInstallDir="C:\\WINDOWS"\r\n'


class Target(unittest.TestCase):
    """The target script keeps USOSPG.DRV (and writes USOSPG.CFG) for a 98 /
    98 SE native phase 1 with a USOS answer in automatic mode only, and only
    when the mini-Windows step put it into MINI.CAB."""

    def block(self, start, end):
        text = TARGET.read_text(encoding='utf-8')
        a = text.index(start)
        return text[a:text.index(end, a)]

    def run_block(self, block, d, **env):
        q = _sh()
        script = 'set -eu\nlog() { printf "%s\\n" "$*"; }\n' + ''.join(f'{k}={v}\n' for k, v in env.items()) + \
                 f'work="{d.as_posix()}"\n' + block
        rc, out, err = q.sh(script)
        self.assertEqual(rc, 0, err)
        return out

    def test_kept_for_98_native_automatic_only(self):
        block = self.block('# Windows 98 / 98 SE with a native phase 1 (X470', '# Display: the answer')
        cases = (('98', '0', 'USOS', AUTO, True), ('98SE', '0', 'USOS', AUTO, True),
                 ('98', '1', 'USOS', AUTO, False), ('98', '0', 'USER', AUTO, False),
                 ('98SE', '0', 'USOS', MANUAL, False), ('98', '0', 'USOS', AUTO.replace(b'ShowEula=0', b'ShowEula=1'), False),
                 ('98', '0', 'USOS', AUTO.replace(b'Express=1', b'Express=0'), False),
                 ('ME', '0', 'USOS', AUTO, False), ('95', '0', 'USOS', AUTO, False))
        for tag, vm, kind, answer, kept in cases:
            with self.subTest(tag=tag, vm=vm, kind=kind, answer=answer[:30]):
                d = Path(tempfile.mkdtemp(prefix='usos-usospg-target-'))
                self.addCleanup(shutil.rmtree, d, ignore_errors=True)
                (d / 'c/USOS9X').mkdir(parents=True)
                (d / 'c/USOS9X/USOSPG.DRV').write_bytes(b'MZ')
                (d / 'c/USOS9X/MSBATCH.INF').write_bytes(answer)
                out = self.run_block(block, d, SYSTEM_TAG=tag, VM_PHASE1=vm, ANSWER_KIND=kind)
                self.assertEqual((d / 'c/USOS9X/USOSPG.DRV').exists(), kept)
                self.assertEqual((d / 'c/USOS9X/USOSPG.CFG').exists(), kept)
                if kept:
                    self.assertEqual((d / 'c/USOS9X/USOSPG.CFG').read_bytes(), b'mode=auto\r\n')
                self.assertEqual('setup pages: USOSPG.DRV for the mini-Windows' in out, kept)
                self.assertNotIn('AAAAA', out)
        # no driver on the stick: no mode file either
        d = Path(tempfile.mkdtemp(prefix='usos-usospg-target-'))
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        (d / 'c/USOS9X').mkdir(parents=True)
        (d / 'c/USOS9X/MSBATCH.INF').write_bytes(AUTO)
        self.run_block(block, d, SYSTEM_TAG='98', VM_PHASE1='0', ANSWER_KIND='USOS')
        self.assertFalse((d / 'c/USOS9X/USOSPG.CFG').exists())

    def test_removed_without_the_mini_windows_helper(self):
        block = self.block('# USOSPG.DRV (above) only inside this MINI.CAB', '\n# NVMe target')
        for bridge, mini, kept in (('1', 'pg=on\r\np1=off\r\npid=off\r\nbridge=on\r\n', True),
                                   ('1', 'pg=off\r\np1=off\r\npid=off\r\nbridge=on\r\n', False),
                                   ('0', 'pg=on\r\np1=off\r\npid=off\r\nbridge=on\r\n', False), ('1', None, False)):
            with self.subTest(bridge=bridge, mini=mini):
                d = Path(tempfile.mkdtemp(prefix='usos-usospg-mini-'))
                self.addCleanup(shutil.rmtree, d, ignore_errors=True)
                (d / 'c/USOS9X').mkdir(parents=True)
                (d / 'c/USOS9X/USOSPG.DRV').write_bytes(b'MZ')
                (d / 'c/USOS9X/USOSPG.CFG').write_bytes(b'mode=auto\r\n')
                if mini is not None:
                    (d / 'c/USOS9X/USOSMINI.TXT').write_bytes(mini.encode())
                self.run_block(block, d, mini_bridge=bridge)
                self.assertEqual((d / 'c/USOS9X/USOSPG.DRV').exists(), kept)
                self.assertEqual((d / 'c/USOS9X/USOSPG.CFG').exists(), kept)

    def test_order(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertLess(text.index('for file in "$HELPERS"/*; do'), text.index('# Windows 98 / 98 SE with a native phase 1 (X470'))
        self.assertLess(text.index('# Windows 98 / 98 SE with a native phase 1 (X470'), text.index('usos-fb-ui --w9x-setup-mini'))
        self.assertLess(text.index('usos-fb-ui --w9x-setup-mini'), text.index("grep -qx 'pg=on'"))


# ---------------------------------------------------------------- the 98 dialogs

CLASSES = {0x80: 'Button', 0x81: 'Edit', 0x82: 'Static', 0x83: 'ListBox', 0x84: 'ScrollBar', 0x85: 'ComboBox'}


def ne_dialogs(raw: bytes) -> dict:
    """{dialog id: [(control id, class, style)]} from an NE file's RT_DIALOG resources."""
    ne = struct.unpack_from('<I', raw, 0x3c)[0]
    rt = ne + struct.unpack_from('<H', raw, ne + 0x24)[0]
    shift = struct.unpack_from('<H', raw, rt)[0]
    p, out = rt + 2, {}
    while True:
        tid = struct.unpack_from('<H', raw, p)[0]
        if tid == 0:
            break
        cnt = struct.unpack_from('<H', raw, p + 2)[0]
        p += 8
        for _ in range(cnt):
            off, ln, _, rid = struct.unpack_from('<HHHH', raw, p)
            p += 12
            if tid != 0x8005 or not rid & 0x8000:
                continue
            b = raw[off << shift:(off << shift) + (ln << shift)]
            style, n = struct.unpack_from('<IB', b, 0)
            i = 13
            for _k in range(2):                                     # menu, class
                i = i + 3 if b[i] == 0xff else b.index(b'\0', i) + 1
            i = b.index(b'\0', i) + 1                               # caption
            if style & 0x40:
                i = b.index(b'\0', i + 2) + 1                       # font
            ctrls = []
            for _k in range(n):
                cid, cstyle = struct.unpack_from('<HI', b, i + 8)
                i += 14
                if b[i] & 0x80:
                    cls = CLASSES.get(b[i], hex(b[i]))
                    i += 1
                else:
                    e = b.index(b'\0', i)
                    cls, i = b[i:e].decode('latin1'), e + 1
                i = i + 3 if b[i] == 0xff else b.index(b'\0', i) + 1
                i += 1 + b[i]
                ctrls.append((cid, cls, cstyle))
            out.setdefault(rid & 0x7fff, ctrls)        # the first of a duplicated ID
    return out


def defines(*names):
    logic = LOGIC.read_text()
    return {n: int(logic.split(f'#define {n}')[1].split()[0], 0) for n in names}


def static_shape(ctrls, ids):
    """The template's side of PGSHAPE (title name org eula_text eula_yes
    eula_no key_edits clickable), as usospg.c reads it from the window."""
    c = {cid: cls for cid, cls, _ in ctrls}
    keys = sum(c.get(ids['PG_KEY1_ID'] + k) == 'Edit' for k in range(ids['PG_KEY_FIELDS']))
    clickable = sum(1 for _, cls, st in ctrls if st & 0x10000000 and cls in ('Edit', 'Button', 'ListBox', 'ComboBox'))
    return (int(c.get(ids['PG_TITLE_ID']) == 'Static'), int(c.get(ids['PG_NAME_ID']) == 'Edit'),
            int(c.get(ids['PG_ORG_ID']) == 'Edit'), int(c.get(ids['PG_EULA_TEXT_ID']) == 'Edit'),
            int(c.get(ids['PG_EULA_YES_ID']) == 'Button'), int(c.get(ids['PG_EULA_NO_ID']) == 'Button'),
            keys, min(clickable, 9))


def kind_of(shape, next_shown, finish_shown):
    """pg_classify in Python (the harness checks the C one with the same rows)."""
    title, name, org, text, yes, no, keys, clickable = shape
    if text and yes and no:
        return EULA
    if keys == 5:
        return KEY
    if name and org and not text and not keys:
        return USER
    if title and not clickable and finish_shown and not next_shown:
        return FINISH
    return OTHER


def _media_files(tmp: Path, key: str):
    import test_w9x_setup_mini as m
    iso = MEDIA98[key]
    if not m.SEVEN.exists() or not (m.MEDIA / iso).exists():
        return None
    d = tmp / key
    d.mkdir(parents=True)
    # the files span PRECOPY1.CAB and PRECOPY2.CAB: both next to each other
    subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(m.MEDIA / iso), 'WIN98/PRECOPY1.CAB', 'WIN98/PRECOPY2.CAB'],
                   capture_output=True, timeout=60)
    for cab in ('PRECOPY1.CAB', 'PRECOPY2.CAB'):
        subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(d / cab), 'setupx.dll', 'kommctrl.dll', 'suwin.exe'],
                       capture_output=True, timeout=60)
    found = {n: next(d.glob(''.join(f'[{ch.upper()}{ch.lower()}]' if ch.isalpha() else ch for ch in n)), None)
             for n in ('setupx.dll', 'kommctrl.dll', 'suwin.exe')}
    return found


class SetupDialogs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix='usos-usospg-dlg-'))
        cls.files = {k: _media_files(cls.tmp, k) for k in MEDIA98}
        if not any(cls.files.values()):
            raise unittest.SkipTest('7-Zip or the Windows 98 / 98 SE PL media missing')

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_wizard_frame_buttons(self):
        ids = defines('PG_BACK_ID', 'PG_NEXT_ID', 'PG_FINISH_ID')
        for k, f in self.files.items():
            if not f:
                continue
            with self.subTest(media=k):
                frame = {cid: cls for cid, cls, _ in ne_dialogs(f['kommctrl.dll'].read_bytes())[1020]}
                self.assertEqual([frame.get(ids[n]) for n in ('PG_BACK_ID', 'PG_NEXT_ID', 'PG_FINISH_ID')], ['Button'] * 3)

    def test_only_the_expected_pages_match(self):
        ids = defines('PG_TITLE_ID', 'PG_NAME_ID', 'PG_ORG_ID', 'PG_EULA_TEXT_ID', 'PG_EULA_YES_ID', 'PG_EULA_NO_ID',
                      'PG_KEY1_ID', 'PG_KEY_FIELDS')
        for k, f in self.files.items():
            if not f:
                continue
            with self.subTest(media=k):
                setupx = ne_dialogs(f['setupx.dll'].read_bytes())
                suwin = ne_dialogs(f['suwin.exe'].read_bytes())
                with_next = {}
                for src, dialogs in (('setupx', setupx), ('suwin', suwin)):
                    for rid, ctrls in dialogs.items():
                        with_next[(src, rid)] = kind_of(static_shape(ctrls, ids), 1, 0)
                matched = {key: kind for key, kind in with_next.items() if kind != OTHER}
                self.assertEqual(matched, {('setupx', 112): USER, ('setupx', 600): EULA,
                                           ('setupx', 607): KEY, ('setupx', 608): KEY})
                # the pages hold what the driver reads
                user = {cid: cls for cid, cls, _ in setupx[112]}
                self.assertEqual((user[ids['PG_NAME_ID']], user[ids['PG_ORG_ID']]), ('Edit', 'Edit'))
                eula = {cid: (cls, st) for cid, cls, st in setupx[600]}
                self.assertEqual(eula[ids['PG_EULA_TEXT_ID']][0], 'Edit')
                for rid in (ids['PG_EULA_YES_ID'], ids['PG_EULA_NO_ID']):
                    self.assertEqual(eula[rid][0], 'Button')
                    self.assertEqual(eula[rid][1] & 0xF, 4)             # BS_RADIOBUTTON: the page checks it
                # the COA pages (three fields) are not key pages
                for rid in (604, 387):
                    self.assertEqual(kind_of(static_shape(setupx[rid], ids), 1, 0), OTHER)
                # the last page: Finish only there; with Finish 4205 is the finish page
                self.assertEqual(kind_of(static_shape(setupx[4205], ids), 0, 1), FINISH)
                self.assertEqual(kind_of(static_shape(setupx[4205], ids), 1, 0), OTHER)


def _openwatcom():
    import build_win3_usb_keyboard as k
    home = k.OW_CACHE / ('ow-' + k.OW_SNAPSHOT['sha256'][:12])
    return (home / 'binnt64/wcc.exe').is_file()


@unittest.skipUnless(_openwatcom(), 'pinned OpenWatcom not unpacked in tools/cache/openwatcom')
class Build(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import build_win9x_support as b
        cls.tmp = Path(tempfile.mkdtemp(prefix='usos-usospg-build-'))
        (cls.tmp / 'out').mkdir()
        (cls.tmp / 'work').mkdir()
        cls.drv = b.build_usospg(cls.tmp / 'out', cls.tmp / 'work').read_bytes()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_ne_driver(self):
        import test_w9x_setup_mini as m
        from build_win3_usb_keyboard import ne_imported_modules
        self.assertEqual(self.drv[:2], b'MZ')
        self.assertEqual(set(ne_imported_modules(self.drv)), {'KERNEL', 'USER'})
        exports = m.ne_exports(self.drv)
        for name in ('DRIVERPROC', 'WEP', 'TICK', 'CBT_PROC', 'MOUSE_PROC', 'KEY_PROC'):
            self.assertIn(name, exports)

    def mini(self, key):
        import test_w9x_setup_mini as m
        iso, member = m.ISOS[key]
        if not m._media(key):
            return None
        d = self.tmp / 'media' / key
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        subprocess.run([str(m.SEVEN), 'e', '-y', f'-o{d}', str(m.MEDIA / iso), member], capture_output=True, timeout=60)
        cab = next(d.glob('[Mm][Ii][Nn][Ii].[Cc][Aa][Bb]'), None)
        self.assertIsNotNone(cab)
        if cab.name != 'MINI.CAB':
            cab = cab.rename(d / 'MINI.CAB')
        return d, cab

    def test_imports_resolve_in_the_98_mini_windows(self):
        import test_w9x_setup_mini as m
        imports = m.ne_imports(self.drv)
        self.assertTrue(imports)
        seen = 0
        for key in ('98-pl', '98se-pl'):
            got = self.mini(key)
            if not got:
                continue
            with self.subTest(media=key):
                _, files, _ = m.read_cab(got[1].read_bytes())
                exports = {'KERNEL': m.ne_exports(files['KRNL386.EXE'][0]), 'USER': m.ne_exports(files['USER.EXE'][0])}
                for mod, what in sorted(imports, key=str):
                    self.assertIn(what, exports[mod], f'{mod}.{what}')
                seen += 1
        if not seen:
            self.skipTest('no Windows 98 / 98 SE media')

    def test_98_mini_cab_gets_the_helper(self):
        import test_w9x_setup_mini as m
        if not m._tool() or not m.VBMOUSE_DRV.exists():
            self.skipTest('zig build win3x-display-tool')
        got = self.mini('98-pl')
        if not got:
            self.skipTest('no Windows 98 PL media')
        d, _ = got
        helpers = self.tmp / 'helpers'
        shutil.rmtree(helpers, ignore_errors=True)
        helpers.mkdir()
        (helpers / 'USOSKEY.DRV').write_bytes(b'MZ USOSKEY test stand-in')
        shutil.copyfile(m.VBMOUSE_DRV, helpers / 'VBMOUSE.DRV')
        (helpers / 'USOSPG.DRV').write_bytes(self.drv)
        r = subprocess.run([str(m._tool()), 'w9x-mini', str(d), str(helpers)], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        log = (helpers / 'USOSMINI.TXT').read_text().splitlines()
        self.assertEqual(log[-4:], ['pg=on', 'p1=off', 'pid=off', 'bridge=on'])
        _, files, _ = m.read_cab((d / 'MINI.CAB').read_bytes())
        self.assertEqual(files['USOSPG.DRV'][0], self.drv)
        self.assertIn('\r\ndrivers=usoskey.drv usospg.drv\r\n', files['SYSTEM.INI'][0].decode('latin1'))


if __name__ == '__main__':
    unittest.main()
