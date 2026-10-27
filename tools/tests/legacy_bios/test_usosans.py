"""USOSANS.EXE (src/platform/bios/win9x/usosans.c): the first-start dialogs
of a USOS-installed Windows 95 / 98 / 98 SE / Me in automatic mode with an
empty password: OK on the first Windows Logon dialog (password fields left
empty; Windows writes the user's password list itself) and Next / Finish in
the new hardware wizard for the Plug and Play Monitor only.

Always: the decisions of usosans_logic.h compiled for the host with zig cc
(titles, device name, driver file, the logon and wizard tick state
machines, the RunServices value's lifetime), source checks (nothing typed,
no password text logged, no password list written), the target script's
staging and RunServices wiring (98 / Me: INSTALL.BAT's [USOS.CsmReg]; 95:
REG95.REG) and the payload lists. With the user's media (read-only,
extracted to a temporary folder with 7-Zip; one test per medium): the
MPRSERV.DLL / SYSDM.CPL dialog templates carry exactly the titles and
control IDs the helper looks for. With the pinned OpenWatcom: the EXE
builds without the C runtime and imports the Windows 95 subset of
KERNEL32 / USER32 / ADVAPI32 only. Nothing here runs Windows 9x."""
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
import depguard  # noqa: E402

SRC = ROOT / 'src/platform/bios/win9x'
LOGIC = SRC / 'usosans_logic.h'
EXE_SRC = SRC / 'usosans.c'
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'
REG95 = (ROOT / 'tools/w9x_reg95.sh').as_posix()
INSTALL = ROOT / 'src/platform/bios/dos_startup.cmd'
SEVEN = Path(r'C:\Program Files\7-Zip\7z.exe')
MEDIA = Path(os.environ.get('USOS_W9X_MEDIA', Path.home() / 'Desktop/Universal_Service_OS/OS/Windows'))
ISOS = {
    '95-rtm-pl': ('Windows 95/Windows 95 RTM PL OEM x86/Microsoft Windows 95 [Polish] (OEM) (ISO)/disk01.iso', 'WIN95'),
    '95-osr21-pl': ('Windows 95/Windows 95 OSR2.1 PL.iso', 'WIN95'),
    '95-osr1-en': ('Windows 95/Windows 95 OSR1 EN OEM x86/win95_a_oem.iso', 'WIN95'),
    '98-pl': ('Windows 98/Windows 98 PL.iso', 'WIN98'),
    '98se-pl': ('Windows 98 SE/Windows 98 SE PL OEM.iso', 'WIN98'),
    'me-pl': ('Windows ME/Windows ME PL OEM.iso', 'WIN9X'),
}

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usosans_logic.h"
/* Text arguments are hex (code page 1250 bytes survive the command line).
 * t HEX: "logon_kind hw_frame"; m HEX: an_is_monitor; i HEX:
 * an_names_monitor_inf; f HEX: "boots desk" of a state file; r B D P:
 * an_remove_now; l TICK...: an_logon_step, TICK = wnd,kind,shape,ok,user,
 * pass,confirm (decimal), prints "action/event" per tick (ANLOGSTATE kept
 * across the ticks); h TICK...: hw_step, TICK = frame,page,name,me_auto,
 * me_auto_on,me_manual_on,search,search_on,list,list_on,places,ready,fin,
 * monitor,monitor_inf,next_ready,finish_ready, prints "action/event/kind". */
static int unhex(const char *h, char *out, int cap)
{
    int n = 0;
    while (h[0] && h[1] && n + 1 < cap) {
        unsigned v;
        sscanf(h, "%2x", &v);
        out[n++] = (char)v;
        h += 2;
    }
    out[n] = 0;
    return n;
}
int main(int argc, char **argv)
{
    char buf[512];
    int i;
    if (argv[1][0] == 't') { unhex(argv[2], buf, sizeof buf); printf("%d %d\n", an_logon_kind(buf), an_is_hw_frame(buf)); }
    else if (argv[1][0] == 'm') { unhex(argv[2], buf, sizeof buf); printf("%d\n", an_is_monitor(buf)); }
    else if (argv[1][0] == 'i') { unhex(argv[2], buf, sizeof buf); printf("%d\n", an_names_monitor_inf(buf)); }
    else if (argv[1][0] == 'f') { int n = unhex(argv[2], buf, sizeof buf); printf("%u %u\n", an_field(buf, n, "boots"), an_field(buf, n, "desk")); }
    else if (argv[1][0] == 'r') printf("%d\n", an_remove_now((unsigned)atoi(argv[2]), (unsigned)atoi(argv[3]), atoi(argv[4])));
    else if (argv[1][0] == 'l') {
        ANLOGSTATE s;
        memset(&s, 0, sizeof s);
        for (i = 2; i < argc; i++) {
            ANLOGON v;
            unsigned long w; int k, sh, ok, u, p, c, a;
            sscanf(argv[i], "%lu,%d,%d,%d,%d,%d,%d", &w, &k, &sh, &ok, &u, &p, &c);
            v.kind = (unsigned char)k; v.shape = (unsigned char)sh; v.ok_ready = (unsigned char)ok;
            v.user_len = u; v.pass_len = p; v.confirm_len = c;
            a = an_logon_step(&s, w, &v);
            printf("%d/%d ", a, s.event);
        }
        printf("\n");
    } else if (argv[1][0] == 'h') {
        HWSTATE s;
        memset(&s, 0, sizeof s);
        for (i = 2; i < argc; i++) {
            HWPAGE p;
            unsigned long f, pg; int x[15], a, j;
            sscanf(argv[i], "%lu,%lu,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d", &f, &pg, &x[0], &x[1], &x[2],
                   &x[3], &x[4], &x[5], &x[6], &x[7], &x[8], &x[9], &x[10], &x[11], &x[12], &x[13], &x[14]);
            for (j = 0; j < 15; j++) ((unsigned char *)&p)[j] = (unsigned char)x[j];
            a = hw_step(&s, f, pg, &p);
            printf("%d/%d/%d ", a, s.event, pg ? hw_classify(&p) : HP_NONE);
        }
        printf("\n");
    }
    return 0;
}
'''

AK_NONE, AK_ENTER, AK_WELCOME, AK_SET = 0, 1, 2, 3
NONE, OK, NEXT, FINISH, LEAVE = 0, 1, 2, 3, 4
(E_NONE, E_SHAPE, E_TYPED, E_NO_USER, E_NO_BUTTON, E_OTHER, E_CHANGED, E_UNCONFIRMED, E_NO_INF, E_STUCK,
 E_LIMIT) = range(11)
HP_NONE, HP_OTHER, HP_INTRO, HP_CHOICE, HP_PLACES, HP_READY, HP_FINISH = range(7)

PL_TITLES = {
    'Wprowad\u017a has\u0142o systemu Windows': AK_ENTER, 'Wprowad\u017a has\u0142o Windows': AK_ENTER,
    'Enter Windows Password': AK_ENTER,
    'System Windows - Zapraszamy': AK_WELCOME, 'Zapraszamy do systemu Windows': AK_WELCOME,
    'Welcome to Windows': AK_WELCOME,
    'Ustaw has\u0142o systemu Windows': AK_SET, 'Ustaw has\u0142o Windows': AK_SET, 'Set Windows Password': AK_SET,
}


def hx(text):
    return text.encode('cp1250').hex()


def logon(wnd=1, kind=AK_ENTER, shape=1, ok=1, user=4, pw=0, confirm=0):
    return f'{wnd},{kind},{shape},{ok},{user},{pw},{confirm}'


def page(frame=7, pg=0, name=0, me_auto=0, me_auto_on=0, me_manual_on=0, search=0, search_on=0, lst=0, lst_on=0,
         places=0, ready=0, fin=0, monitor=0, inf=0, nxt=1, finish=0):
    return ','.join(str(v) for v in (frame, pg, name, me_auto, me_auto_on, me_manual_on, search, search_on, lst,
                                     lst_on, places, ready, fin, monitor, inf, nxt, finish))


INTRO = dict(pg=11, name=1, monitor=1)
CHOICE = dict(pg=12, search=1, search_on=1, lst=1)
PLACES = dict(pg=13, places=1)
READY = dict(pg=14, ready=1, monitor=1, inf=1)
FIN = dict(pg=15, fin=1, monitor=1, nxt=0, finish=1)


class Logic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        zig = depguard.require_zig()
        work = ROOT / 'zig-out/usosans-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS)
        cls.exe = work / 'usosans.exe'
        subprocess.run([str(zig), 'cc', '-O1', '-Wall', '-Werror', '-I', str(SRC), str(work / 'harness.c'),
                        '-o', str(cls.exe)], check=True,
                       env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})

    def run_exe(self, *args):
        return subprocess.run([str(self.exe), *args], capture_output=True, text=True, check=True).stdout.strip()

    def logon(self, *ticks):
        return [tuple(int(x) for x in t.split('/')) for t in self.run_exe('l', *ticks).split()]

    def hw(self, *ticks):
        return [tuple(int(x) for x in t.split('/')) for t in self.run_exe('h', *ticks).split()]

    def test_titles(self):
        for title, kind in PL_TITLES.items():
            with self.subTest(title=title):
                self.assertEqual(self.run_exe('t', hx(title)), f'{kind} 0')
        for title in ('Kreator dodawania nowego sprz\u0119tu', 'Add New Hardware Wizard'):
            self.assertEqual(self.run_exe('t', hx(title)), '0 1')
        for title in ('Wprowad\u017a has\u0142o sieciowe', 'Enter Network Password', 'Kreator aktualizacji sterownika urz\u0105dzenia',
                      'Update Device Driver Wizard', 'Enter Windows Password ', 'enter windows password',
                      'Znaleziono nowy sprz\u0119t', ''):
            with self.subTest(title=title):
                self.assertEqual(self.run_exe('t', hx(title)), '0 0')

    def test_monitor_name_and_driver_file(self):
        for text, want in (('Monitor Plug and Play', 1), ('Plug and Play Monitor', 1), ('  Monitor Plug and Play \r\n', 1),
                           ('Monitor Plug and Play (VESA DDC)', 0), ('Monitor domy\u015blny', 0), ('Nieznane urz\u0105dzenie', 0),
                           ('Standard VGA Graphics Adapter', 0), ('monitor plug and play', 0), ('', 0)):
            with self.subTest(text=text):
                self.assertEqual(self.run_exe('m', hx(text)), str(want))
        for text, want in (('C:\\WINDOWS\\INF\\MONITOR.INF', 1), ('c:\\windows\\inf\\monitor.inf', 1),
                           ('C:\\WINDOWS\\INF\\MONITOR.INF (4.10)', 1), ('C:\\WINDOWS\\INF\\MONITOR2.INF', 0),
                           ('A:\\OEMMON.INF', 0), ('MONITOR.INF', 0), ('C:\\WINDOWS\\INF\\MONITOR.INFX', 0), ('', 0)):
            with self.subTest(text=text):
                self.assertEqual(self.run_exe('i', hx(text)), str(want))

    def test_first_logon_ok_after_one_second_once(self):
        got = self.logon(*[logon()] * 6)
        self.assertEqual([a for a, _ in got], [NONE, NONE, NONE, OK, NONE, NONE])
        # the welcome and set-password dialogs the same way (set: both fields empty, no user name)
        self.assertEqual([a for a, _ in self.logon(*[logon(kind=AK_WELCOME)] * 4)], [NONE] * 3 + [OK])
        self.assertEqual([a for a, _ in self.logon(*[logon(kind=AK_SET, user=0)] * 4)], [NONE] * 3 + [OK])

    def test_typed_password_is_the_users(self):
        got = self.logon(logon(), logon(), logon(pw=1), logon(pw=0), logon(pw=0), logon(pw=0), logon(pw=0))
        self.assertEqual(got[2], (LEAVE, E_TYPED))
        self.assertTrue(all(a != OK for a, _ in got))
        self.assertEqual(self.logon(logon(pw=-1))[0], (LEAVE, E_TYPED))      # unreadable counts as typed
        got = self.logon(*[logon(kind=AK_SET, user=0, confirm=1)] * 5)
        self.assertEqual(got[0], (LEAVE, E_TYPED))
        self.assertTrue(all(a != OK for a, _ in got))

    def test_waits_for_user_name_and_ok_then_gives_up(self):
        got = self.logon(logon(user=0), logon(user=0), logon(), logon(), logon(), logon())
        self.assertEqual([a for a, _ in got], [NONE, NONE, NONE, NONE, NONE, OK])
        got = self.logon(*[logon(user=0)] * 41)
        self.assertIn((LEAVE, E_NO_USER), got)
        self.assertTrue(all(a != OK for a, _ in got))
        got = self.logon(*[logon(ok=0)] * 41)
        self.assertIn((LEAVE, E_NO_BUTTON), got)

    def test_wrong_shape_left_alone(self):
        self.assertEqual(self.logon(logon(shape=0))[0], (LEAVE, E_SHAPE))
        self.assertEqual(self.logon(logon(kind=AK_NONE))[0], (LEAVE, E_SHAPE))

    def test_each_new_dialog_gets_its_turn_with_a_limit(self):
        ticks = []
        for w in range(1, 6):
            ticks += [logon(wnd=w)] * 4
        acts = [a for a, _ in self.logon(*ticks)]
        self.assertEqual(acts.count(OK), 3)              # AN_LOGON_MAX per start
        self.assertEqual(acts.count(LEAVE), 2)

    def test_monitor_wizard_full_run(self):
        ticks = [page(**INTRO)] * 4 + [page(**CHOICE)] * 4 + [page(**PLACES)] * 4 + [page()] * 3 + \
                [page(**READY)] * 4 + [page(pg=0)] * 2 + [page(**FIN)] * 6
        acts = [a for a, _, _ in self.hw(*ticks)]
        self.assertEqual([a for a in acts if a != NONE], [NEXT, NEXT, NEXT, NEXT, FINISH])
        self.assertEqual(acts[3], NEXT)                  # after 1 s on the page

    def test_me_intro_with_automatic_search(self):
        me_intro = dict(INTRO, me_auto=1, me_auto_on=1)
        acts = [a for a, _, _ in self.hw(*[page(**me_intro)] * 4)]
        self.assertEqual(acts[-1], NEXT)
        got = self.hw(*[page(**dict(me_intro, me_auto_on=0, me_manual_on=1))] * 6)
        self.assertEqual(got[3][:2], (LEAVE, E_CHANGED))
        self.assertTrue(all(a != NEXT for a, _, _ in got))

    def test_other_device_never_touched(self):
        got = self.hw(*[page(**dict(INTRO, monitor=0))] * 6, *[page(**CHOICE)] * 6, *[page(**dict(FIN, monitor=1))] * 6)
        self.assertEqual(got[3][:2], (LEAVE, E_OTHER))
        self.assertTrue(all(a == NONE for a, _, _ in got[4:]))
        # a choice page without a confirmed intro (helper started late): left
        got = self.hw(*[page(**CHOICE)] * 5)
        self.assertEqual(got[3][:2], (LEAVE, E_UNCONFIRMED))
        # a finish page of another device
        got = self.hw(*[page(**dict(FIN, monitor=0))] * 5)
        self.assertEqual(got[3][:2], (LEAVE, E_OTHER))

    def test_changed_choice_other_driver_unknown_pages(self):
        ticks = [page(**INTRO)] * 4 + [page(**dict(CHOICE, search_on=0, lst_on=1))] * 6
        got = self.hw(*ticks)
        self.assertEqual(got[7][:2], (LEAVE, E_CHANGED))
        self.assertEqual([a for a, _, _ in got].count(NEXT), 1)
        ticks = [page(**INTRO)] * 4 + [page(**CHOICE)] * 4 + [page(**PLACES)] * 4 + [page(**dict(READY, inf=0))] * 6
        got = self.hw(*ticks)
        self.assertEqual(got[15][:2], (LEAVE, E_NO_INF))
        self.assertEqual([a for a, _, _ in got].count(NEXT), 3)
        # an unknown page (not found, searching) is only watched, never pressed
        got = self.hw(*[page(**INTRO)] * 4, *[page(pg=20)] * 50)
        self.assertEqual(got[-1], (NONE, E_NONE, HP_OTHER))
        self.assertEqual([a for a, _, _ in got].count(NEXT), 1)

    def test_ready_page_alone_needs_the_device_name(self):
        acts = [a for a, _, _ in self.hw(*[page(**READY)] * 4)]
        self.assertEqual(acts[-1], NEXT)
        got = self.hw(*[page(**dict(READY, monitor=0))] * 4)
        self.assertEqual(got[3][:2], (LEAVE, E_UNCONFIRMED))

    def test_button_not_enabled_then_stuck(self):
        got = self.hw(*[page(**dict(INTRO, nxt=0))] * 44)
        self.assertIn((LEAVE, E_NO_BUTTON, HP_INTRO), got)
        self.assertTrue(all(a != NEXT for a, _, _ in got))
        got = self.hw(*[page(**INTRO)] * 90)
        acts = [a for a, _, _ in got]
        self.assertEqual(acts.count(NEXT), 1)
        self.assertIn((LEAVE, E_STUCK, HP_INTRO), got)

    def test_places_stays_40_s_then_ready(self):
        # X470 98 FE PL 2026-10-27: the search runs behind the places page; 120 s before it counts as stayed
        ticks = [page(**INTRO)] * 4 + [page(**CHOICE)] * 4 + [page(**PLACES)] * (4 + 160) + \
                [page(**READY)] * 4 + [page(**FIN)] * 6
        got = self.hw(*ticks)
        self.assertEqual([a for a, _, _ in got if a != NONE], [NEXT, NEXT, NEXT, NEXT, FINISH])
        self.assertNotIn(LEAVE, [a for a, _, _ in got])

    def test_stayed_page_is_reported_once_and_the_wizard_goes_on(self):
        # places beyond 120 s: reported once, then the ready / finish pages still get their press
        ticks = [page(**INTRO)] * 4 + [page(**CHOICE)] * 4 + [page(**PLACES)] * (4 + 500) + \
                [page(**READY)] * 4 + [page(**FIN)] * 6
        got = self.hw(*ticks)
        self.assertEqual([(a, e) for a, e, _ in got if a == LEAVE], [(LEAVE, E_STUCK)])
        self.assertEqual([a for a, _, _ in got if a in (NEXT, FINISH)], [NEXT, NEXT, NEXT, NEXT, FINISH])
        # another page: 20 s as before, then the next page gets its turn
        got = self.hw(*[page(**INTRO)] * 90, *[page(**CHOICE)] * 4)
        self.assertEqual([(a, e) for a, e, _ in got if a == LEAVE], [(LEAVE, E_STUCK)])
        self.assertEqual(got[-1][0], NEXT)

    def test_new_frame_starts_over(self):
        got = self.hw(*[page(**dict(INTRO, monitor=0))] * 4, *[page(frame=8, **INTRO)] * 4)
        self.assertEqual(got[3][:2], (LEAVE, E_OTHER))
        self.assertEqual(got[7][0], NEXT)

    def test_state_file_and_lifetime(self):
        for text, want in (('boots=2 desk=1\r\n', '2 1'), ('desk=3 boots=4', '4 3'), ('', '0 0'), ('boots=x', '0 0'),
                           ('xboots=5 desk=1', '0 1'), ('boots=1\ndesk=2\n', '1 2')):
            with self.subTest(text=text):
                self.assertEqual(self.run_exe('f', text.encode().hex()), want)
        for boots, desk, pending, want in ((1, 0, 1, 0), (1, 0, 0, 0), (2, 1, 0, 0), (3, 2, 1, 0), (3, 2, 0, 1),
                                           (4, 0, 1, 0), (5, 0, 1, 1), (5, 4, 0, 1)):
            with self.subTest(boots=boots, desk=desk, pending=pending):
                self.assertEqual(self.run_exe('r', str(boots), str(desk), str(pending)), str(want))


class Sources(unittest.TestCase):
    def test_never_types_or_writes_passwords(self):
        c = EXE_SRC.read_text(encoding='utf-8')
        for banned in ('WM_SETTEXT', 'SetWindowText', 'SetDlgItemText', 'keybd_event', 'SendInput', 'WM_CHAR',
                       'WM_KEYDOWN', 'RegSetValue', '.PWL', 'WritePrivateProfile', 'BM_CLICK', 'CreateProcess', 'WinExec'):
            self.assertNotIn(banned, c)
        # the only presses: OK of a logon dialog, Next / Finish of the wizard frame
        self.assertEqual(c.count('PostMessageA('), 1)
        self.assertIn('press(w, AN_OK_ID);', c)
        self.assertIn('press(frame, HW_NEXT_ID);', c)
        self.assertIn('press(frame, HW_FINISH_ID);', c)
        self.assertEqual(c.count('press('), 4)          # the definition + three calls
        # password fields are only measured, never read as text
        self.assertIn('v.pass_len = length_of(GetDlgItem(w, AN_PASS_ID));', c)
        self.assertNotIn('text_of(GetDlgItem(w, AN_PASS_ID)', c)
        self.assertIn('RegDeleteValueA(k, VALUE_NAME)', c)
        self.assertIn('#define RUNSVC_KEY "Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\RunServices"', c)
        self.assertIn('#define VALUE_NAME "USOSAns"', c)
        self.assertIn('lstrcatA(g_log, "USOSANS.TXT");', c)
        self.assertIn('Sleep(15000);', c)                # after the shell's RunServices enumeration

    def test_payload_lists(self):
        import build_win9x_support as b
        self.assertIn('USOSANS.EXE', b.STAGED)
        self.assertNotIn('USOSANS.EXE', b.FILES)          # not on the Legacy Core RAM disk
        self.assertEqual(set(b.USOSANS_IMPORTS), {'kernel32.dll', 'user32.dll', 'advapi32.dll'})
        for dll, names in b.USOSANS_IMPORTS.items():
            self.assertLessEqual(names, b.USOSLOG_IMPORTS[dll] | {'RegDeleteValueA', 'EnumChildWindows', 'FindWindowA',
                                                                 'GetDlgItem', 'GetParent', 'IsWindowEnabled',
                                                                 'PostMessageA', 'SendMessageTimeoutA'}, dll)
        self.assertIn('    build_usoslog(out, work)\n    build_usosans(out, work)\n', (ROOT / 'tools/build_win9x_support.py').read_text())
        self.assertIn("'EFI/USOS/dos-native/win9x/USOSANS.EXE'",
                      (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8-sig'))
        self.assertIn('{`zig-out/dos-native/win9x/USOSANS.EXE`, `EFI/USOS/dos-native/win9x/USOSANS.EXE`}',
                      (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))
        self.assertIn('payload_zip\tEFI/USOS/dos-native/win9x/USOSANS.EXE\n',
                      (ROOT / 'tools/tests/golden/staged_payloads.tsv').read_text(encoding='utf-8'))

    def test_install_bat_runservices_line(self):
        lines = INSTALL.read_text(encoding='latin-1').splitlines()
        i = lines.index('IF NOT "%U9ANH%"=="1" GOTO ANSRS')
        self.assertEqual(lines[i + 1:i + 4], ['IF NOT EXIST C:\\USOS9X\\USOSANS.EXE GOTO ANSRS',
                                              'ECHO HKLM,%%USOSRS%%,USOSAns,,"C:\\USOS9X\\USOSANS.EXE">>C:\\%U9SRC%\\MSBATCH.INF',
                                              ':ANSRS'])
        self.assertLess(lines.index(':CSMREGS'), i)
        self.assertLess(i, lines.index('ECHO [Strings]>>C:\\%U9SRC%\\MSBATCH.INF'))
        self.assertIn('ECHO USOSRS="Software\\Microsoft\\Windows\\CurrentVersion\\RunServices">>C:\\%U9SRC%\\MSBATCH.INF', lines)
        for line in lines[i - 2:i + 4] + [ln for ln in lines if 'USOSRS=' in ln]:   # COMMAND.COM: under 128 expanded
            self.assertLess(len(line.replace('%U9SRC%', 'WIN98').replace('%%', '%')), 128, line)


AUTO = r'''[Setup]
Express=1
[Install]
AddReg=USOS.Lan
[USOS.Lan]
HKLM,"Software\Microsoft\Windows\CurrentVersion\Winlogon",AutoAdminLogon,,"1"
HKLM,"Software\Microsoft\Windows\CurrentVersion\Winlogon",DefaultUserName,,"Jan Kowalski"
HKLM,"Software\Microsoft\Windows\CurrentVersion\Winlogon",DefaultPassword,,""
'''.replace('\n', '\r\n')


class Target(unittest.TestCase):
    """w9x_csmwrap_target.sh keeps USOSANS.EXE and sets U9ANH=1 only for a
    USOS answer in automatic mode with auto logon, a user name and an empty
    password; 95 gets the RunServices value from REG95.REG."""

    def block(self):
        text = TARGET.read_text(encoding='utf-8')
        a = text.index('# The first-start dialogs (X470 95 / 98 FE PL')
        return text[a:text.index('# The boot disk is the only BIOS hard disk', a)]

    def run_block(self, d, **env):
        from test_w9x_phase1_qemu import sh
        script = 'set -eu\nlog() { printf "%s\\n" "$*"; }\n' + ''.join(f'{k}={v}\n' for k, v in env.items()) + \
            f'work="{d.as_posix()}"\n' + self.block()
        # from a file: a command line through MSYS sh would fold the awk "\\"
        (d / 'block.sh').write_text(script, encoding='ascii', newline='\n')
        rc, out, err = sh(f'. "{(d / "block.sh").as_posix()}"')
        self.assertEqual(rc, 0, err)
        return out

    def test_staged_only_for_automatic_empty_password(self):
        cases = (('USOS', AUTO, True), ('PROFILE', AUTO, True), ('USER', AUTO, False),
                 ('USOS', ';USOS-SETUP=manual\r\n' + AUTO, False),
                 ('USOS', AUTO.replace('DefaultPassword,,""', 'DefaultPassword,,"tajne"'), False),
                 ('USOS', AUTO.replace('\r\nHKLM,"Software\\Microsoft\\Windows\\CurrentVersion\\Winlogon",DefaultPassword,,""', ''), False),
                 ('USOS', AUTO.replace('AutoAdminLogon,,"1"', 'AutoAdminLogon,,"0"'), False),
                 ('USOS', AUTO.replace('DefaultUserName,,"Jan Kowalski"', 'DefaultUserName,,""'), False),
                 ('USOS', (ROOT / 'src/platform/bios/win9x/msbatch.inf').read_text(encoding='ascii'), True))
        for kind, answer, kept in cases:
            with self.subTest(kind=kind, answer=answer[:40]):
                d = Path(tempfile.mkdtemp(prefix='usos-usosans-target-'))
                self.addCleanup(shutil.rmtree, d, ignore_errors=True)
                (d / 'c/USOS9X').mkdir(parents=True)
                (d / 'c/USOS9X/USOSANS.EXE').write_bytes(b'MZ')
                (d / 'c/USOS9X/U9ENV.BAT').write_bytes(b'SET U9SYS=98\r\n')
                (d / 'c/USOS9X/MSBATCH.INF').write_bytes(answer.encode('ascii'))
                out = self.run_block(d, ANSWER_KIND=kind)
                self.assertEqual((d / 'c/USOS9X/USOSANS.EXE').exists(), kept)
                env = (d / 'c/USOS9X/U9ENV.BAT').read_bytes()
                self.assertEqual(env, b'SET U9SYS=98\r\n' + (b'SET U9ANH=1\r\n' if kept else b''))
                self.assertEqual('first-start dialogs: USOSANS.EXE from RunServices' in out, kept)
                self.assertNotIn('tajne', out)
        # not in this payload: nothing
        d = Path(tempfile.mkdtemp(prefix='usos-usosans-target-'))
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        (d / 'c/USOS9X').mkdir(parents=True)
        (d / 'c/USOS9X/U9ENV.BAT').write_bytes(b'')
        (d / 'c/USOS9X/MSBATCH.INF').write_bytes(AUTO.encode('ascii'))
        self.run_block(d, ANSWER_KIND='USOS')
        self.assertEqual((d / 'c/USOS9X/U9ENV.BAT').read_bytes(), b'')

    def test_95_reg95_wiring(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn("[ \"${ans_ok:-0}\" != 1 ] || reg95_ans='C:\\USOS9X\\USOSANS.EXE'", text)
        self.assertIn('"$reg95_ie" "$work/c/$SETUP_FOLDER" "$reg95_ans"; then', text)
        self.assertLess(text.index('# The first-start dialogs (X470 95 / 98 FE PL'), text.index('reg95_ans='))

    def test_reg95_runservices_value(self):
        from test_w9x_phase1_qemu import sh
        from test_w9x_reg95 import ANSWER_95
        for ans, want in (('C:\\USOS9X\\USOSANS.EXE', True), ('', False)):
            with self.subTest(ans=ans):
                d = Path(tempfile.mkdtemp(prefix='usos-usosans-reg95-'))
                self.addCleanup(shutil.rmtree, d, ignore_errors=True)
                (d / 'out').mkdir()
                (d / 'MSBATCH.INF').write_bytes(ANSWER_95.encode('ascii'))
                rc, _, err = sh(f'. "{REG95}"\nw9x_reg95_write "{(d / "out").as_posix()}" "{(d / "MSBATCH.INF").as_posix()}" '
                                f"'' '' '' '' '' '' '{ans}'", {})
                self.assertEqual(rc, 0, err)
                reg = (d / 'out/REG95.REG').read_bytes().decode('ascii')
                block = '[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunServices]\r\n' \
                        '"USOSAns"="C:\\\\USOS9X\\\\USOSANS.EXE"\r\n'
                self.assertEqual(block in reg, want)
                self.assertEqual(reg.count('USOSAns'), 1 if want else 0)


# ---- the user's media: titles and control IDs in the templates ----

def _resources(data):
    """{(type, id): bytes} of a PE image's resource directory (first language)."""
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None
    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    opt = pe + 24
    secs =[(struct.unpack_from('<I', data, s + 12)[0], struct.unpack_from('<I', data, s + 8)[0],
             struct.unpack_from('<I', data, s + 20)[0])
            for s in (opt + struct.unpack_from('<H', data, pe + 20)[0] + 40 * i for i in range(nsec))]

    def off(rva):
        for va, vs, raw in secs:
            if va <= rva < va + max(vs, 1):
                return raw + rva - va
        raise ValueError(hex(rva))
    rsrc = struct.unpack_from('<I', data, opt + 112)[0]
    base = off(rsrc)

    def entries(o):
        n = sum(struct.unpack_from('<HH', data, o + 12))
        return [struct.unpack_from('<II', data, o + 16 + 8 * i) for i in range(n)]
    out = {}
    for tid, t in entries(base):
        if not t & 0x80000000:
            continue
        for rid, r in entries(base + (t & 0x7FFFFFFF)):
            if not r & 0x80000000:
                continue
            lang = entries(base + (r & 0x7FFFFFFF))[0][1]
            rva, size = struct.unpack_from('<II', data, base + lang)
            out[(tid, rid)] = data[off(rva):off(rva) + size]
    return out


def _wz(d, o):
    e = o
    while d[e:e + 2] != b'\0\0':
        e += 2
    return d[o:e].decode('utf-16le'), e + 2


def _sz_or_ord(d, o):
    w = struct.unpack_from('<H', d, o)[0]
    if w == 0:
        return '', o + 2
    if w == 0xFFFF:
        return struct.unpack_from('<H', d, o + 2)[0], o + 4
    return _wz(d, o)


def pe_dialog(d):
    """(title, {id: (class, text)}) of a DLGTEMPLATE or DLGTEMPLATEEX."""
    ex = d[:4] == b'\x01\x00\xff\xff'
    if ex:
        style, n = struct.unpack_from('<I', d, 12)[0], struct.unpack_from('<H', d, 16)[0]
        o = 26
    else:
        style, _, n = struct.unpack_from('<IIH', d, 0)
        o = 18
    _, o = _sz_or_ord(d, o)
    _, o = _sz_or_ord(d, o)
    title, o = _wz(d, o)
    if style & 0x40:
        o += 6 if ex else 2
        _, o = _wz(d, o)
    items = {}
    for _ in range(n):
        o = (o + 3) & ~3
        if ex:
            cid = struct.unpack_from('<I', d, o + 20)[0] & 0xFFFF
            o += 24
        else:
            cid = struct.unpack_from('<H', d, o + 16)[0]
            o += 18
        w = struct.unpack_from('<H', d, o)[0]
        if w == 0xFFFF:
            cls = {0x80: 'Button', 0x81: 'Edit', 0x82: 'Static'}.get(struct.unpack_from('<H', d, o + 2)[0], '?')
            o += 4
        else:
            cls, o = _wz(d, o)
        text, o = _sz_or_ord(d, o)
        o += 2 + struct.unpack_from('<H', d, o)[0]
        items[cid] = (cls, text)
    return title, items


def _az(d, o):
    e = d.index(b'\0', o)
    return d[o:e].decode('cp1250'), e + 1


def ne_resources(d):
    """{(type, id): bytes} of an NE module."""
    ne = struct.unpack_from('<I', d, 0x3C)[0]
    if d[ne:ne + 2] != b'NE':
        return None
    rt = ne + struct.unpack_from('<H', d, ne + 0x24)[0]
    shift = struct.unpack_from('<H', d, rt)[0]
    o = rt + 2
    out = {}
    while True:
        tid, cnt = struct.unpack_from('<HH', d, o)
        o += 8
        if tid == 0:
            return out
        for _ in range(cnt):
            off, ln, _, rid = struct.unpack_from('<HHHH', d, o)
            o += 12
            if rid & 0x8000:
                out[(tid & 0x7FFF, rid & 0x7FFF)] = d[off << shift:(off << shift) + (ln << shift)]


def ne_dialog(d):
    style, n = struct.unpack_from('<IB', d, 0)
    o = 13
    o = o + 3 if d[o] == 0xFF else _az(d, o)[1]
    _, o = _az(d, o)
    title, o = _az(d, o)
    if style & 0x40:
        o += 2
        _, o = _az(d, o)
    items = {}
    for _ in range(n):
        cid = struct.unpack_from('<H', d, o + 8)[0]
        o += 14
        if d[o] & 0x80:
            cls = {0x80: 'Button', 0x81: 'Edit', 0x82: 'Static'}.get(d[o], '?')
            o += 1
        else:
            cls, o = _az(d, o)
        if d[o] == 0xFF:
            text = struct.unpack_from('<H', d, o + 1)[0]
            o += 3
        else:
            text, o = _az(d, o)
        o += 1 + d[o]
        items[cid] = (cls, text)
    return title, items


def ne_string(res, sid):
    block = res.get((6, sid // 16 + 1))
    if block is None:
        return None
    o = 0
    for i in range(16):
        n = block[o]
        o += 1
        if i == sid % 16:
            return block[o:o + n].decode('cp1250')
        o += n
    return None


def pe_string(res, sid):
    block = res.get((6, sid // 16 + 1))
    if block is None:
        return None
    o = 0
    for i in range(16):
        n = struct.unpack_from('<H', block, o)[0]
        o += 2
        if i == sid % 16:
            return block[o:o + 2 * n].decode('utf-16le')
        o += 2 * n
    return None


def _logic_strings():
    """The titles / names of usosans_logic.h, as text (cp1250 decoded)."""
    import re
    text = LOGIC.read_text(encoding='ascii')
    out = {}
    for name in ('an_enter_titles', 'an_welcome_titles', 'an_set_titles', 'an_hw_titles', 'an_monitor_names'):
        body = text[text.index(f'{name}[] = {{'):]
        body = body[:body.index('0 };')]
        out[name] = [bytes(re.sub(r'\\x([0-9a-f]{2})', lambda m: chr(int(m.group(1), 16)), s), 'latin1').decode('cp1250')
                     for s in re.findall(r'"((?:[^"\\]|\\.)*)"', body)]
    return out


class Media(unittest.TestCase):
    """One test per medium (each extracts its Setup CABs and the two files)."""

    def extract(self, key):
        iso, folder = ISOS[key]
        if not SEVEN.exists() or not (MEDIA / iso).exists():
            self.skipTest(f'no {key} medium')
        d = Path(tempfile.mkdtemp(prefix='usos-usosans-media-'))
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        listing = subprocess.run([str(SEVEN), 'l', '-ba', '-slt', '-spd', str(MEDIA / iso)], capture_output=True,
                                 text=True, timeout=60).stdout
        cabs = [ln[7:] for ln in listing.splitlines() if ln.startswith('Path = ') and
                ln[7:].upper().startswith(folder + '\\') and ln.upper().endswith('.CAB') and ln[7:].count('\\') == 1]
        self.assertTrue(cabs)
        subprocess.run([str(SEVEN), 'e', '-y', '-spd', f'-o{d / "cab"}', str(MEDIA / iso), *cabs], capture_output=True,
                       timeout=90, check=True)
        found = {}
        for cab in sorted((d / 'cab').iterdir()):
            subprocess.run([str(SEVEN), 'e', '-y', f'-o{d / "dll"}', str(cab), 'mprserv.dll', 'sysdm.cpl'],
                           capture_output=True, timeout=30)
            found = {p.name.lower(): p for p in (d / 'dll').glob('*')} if (d / 'dll').exists() else {}
            if 'mprserv.dll' in found and 'sysdm.cpl' in found:
                break
        self.assertIn('mprserv.dll', found)
        return found

    def check(self, key, lang, ver):
        files = self.extract(key)
        want = _logic_strings()
        res = _resources(files['mprserv.dll'].read_bytes())
        dialogs = {rid: pe_dialog(res[(5, rid)]) for rid in (2, 3, 13)}
        idx = 2 if lang == 'en' else 1 if ver == '95' else 0
        self.assertEqual(dialogs[13][0], want['an_enter_titles'][idx])
        self.assertEqual(dialogs[2][0], want['an_welcome_titles'][idx])
        self.assertEqual(dialogs[3][0], want['an_set_titles'][idx])
        for rid in (2, 13):
            items = dialogs[rid][1]
            self.assertEqual(items[30][0], 'Edit')
            self.assertEqual(items[31][0], 'Edit')
            self.assertEqual(items[1][0], 'Button')
        self.assertEqual((dialogs[3][1][40][0], dialogs[3][1][41][0], dialogs[3][1][1][0]), ('Edit', 'Edit', 'Button'))
        # the other logon titles of the file are none of ours ("Enter Network Password")
        titles = {pe_dialog(v)[0] for (t, _), v in res.items() if t == 5}
        ours = set(want['an_enter_titles'] + want['an_welcome_titles'] + want['an_set_titles'])
        self.assertEqual(titles & ours, {dialogs[2][0], dialogs[3][0], dialogs[13][0]})
        if ver == '95':
            return
        sysdm = files['sysdm.cpl'].read_bytes()
        nres = ne_resources(sysdm)
        self.assertIsNotNone(nres, 'SYSDM.CPL is an NE module on 98 / 98 SE / Me')
        self.assertEqual(ne_string(nres, 1777), want['an_hw_titles'][0 if lang == 'pl' else 1])
        pages = {rid: ne_dialog(v) for (t, rid), v in nres.items() if t == 5}

        def having(*ids):
            return [rid for rid, (_, items) in pages.items() if all(i in items for i in ids)]
        intro = having(4004)
        self.assertTrue(intro)
        for rid in having(3315, 3316):
            self.assertEqual(pages[rid][1][3315][0], 'Button')
        self.assertTrue(having(3315, 3316))
        self.assertTrue(having(4101, 4104))
        self.assertEqual(having(4121, 4122), [4120])
        if ver == 'me':
            self.assertEqual(intro, [3300])
            self.assertIn(3317, pages[3300][1])
            self.assertIn(3318, pages[3300][1])
        else:
            self.assertEqual(intro, [4000])
            self.assertEqual(having(3315, 3316), [3301])
            self.assertEqual(having(3494, 3497), [3490])
            self.assertEqual(having(4101, 4104), [3300])
        # no page is two kinds at once
        for rid, (_, items) in pages.items():
            kinds = [k for k, ids in (('fin', (4121, 4122)), ('ready', (4101, 4104)), ('intro', (4004,)))
                     if all(i in items for i in ids)]
            self.assertLessEqual(len(kinds), 1, rid)

    def test_98_pl(self):
        self.check('98-pl', 'pl', '98')

    def test_98se_pl(self):
        self.check('98se-pl', 'pl', '98')

    def test_me_pl(self):
        self.check('me-pl', 'pl', 'me')

    def test_95_rtm_pl(self):
        self.check('95-rtm-pl', 'pl', '95')

    def test_95_osr21_pl(self):
        self.check('95-osr21-pl', 'pl', '95')

    def test_95_osr1_en(self):
        self.check('95-osr1-en', 'en', '95')


class Binary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import build_win9x_support as b
        if depguard.watcom() is None:
            raise unittest.SkipTest('no OpenWatcom snapshot in tools/cache')
        cls.tmp = Path(tempfile.mkdtemp(prefix='usos-usosans-build-'))
        (cls.tmp / 'out').mkdir()
        (cls.tmp / 'work').mkdir()
        cls.exe = b.build_usosans(cls.tmp / 'out', cls.tmp / 'work').read_bytes()
        cls.b = b

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_pe_400_gui_imports(self):
        d = self.exe
        pe = struct.unpack_from('<I', d, 0x3C)[0]
        self.assertEqual(d[pe:pe + 4], b'PE\0\0')
        opt = pe + 24
        self.assertEqual(struct.unpack_from('<H', d, opt + 68)[0], 2)               # Windows GUI
        self.assertEqual(struct.unpack_from('<HH', d, opt + 40), (4, 0))            # OS version 4.00
        self.assertEqual(struct.unpack_from('<HH', d, opt + 48), (4, 0))            # subsystem 4.00
        self.assertEqual(struct.unpack_from('<I', d, pe + 8)[0], 0)                 # no link time
        imports = self.b.pe_imports(d)
        self.assertEqual(set(imports), {'kernel32.dll', 'user32.dll', 'advapi32.dll'})
        for dll, names in imports.items():
            self.assertLessEqual(names, self.b.USOSANS_IMPORTS[dll], dll)
        self.assertIn(b'Wprowad\x9f has\xb3o systemu Windows', d)
        self.assertIn(b'Monitor Plug and Play', d)
        self.assertLess(len(d), 32768)


if __name__ == '__main__':
    unittest.main()
