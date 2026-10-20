"""USOSKEY.DRV wheel scrolling of Win16 windows (src/platform/win3/
usoskey_wheel.h compiled for the host with zig cc; the Windows side in
usoskey.c and the diagnostics in USOSDBG.EXE / USOSLOG.EXE checked at the
source level). Windows 98 / 98 SE / Me USER sends WM_MOUSEWHEEL to the focus
window, and Win16 windows (Me's Device Manager: 16-bit COMMCTRL
"SysTreeView") ignore it; USOSKEY.DRV's WH_GETMESSAGE hook sends WM_VSCROLL
to a Win16 / no-wheel window under the pointer instead and leaves Win32
windows on the stock path."""
from pathlib import Path
import os
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[3]
WIN3 = ROOT / 'src/platform/win3'
HEADER = WIN3 / 'usoskey_wheel.h'

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usoskey_wheel.h"
/* d enabled has_target kind class  -> action
 * k flags_hex [sig]                -> module kind ("x": no "NE")
 * n now seen                       -> notches
 * p notches lines_hex              -> "code count"
 * s active translated_at msg_time  -> 0/1
 * e enabled has_target rollmsg      -> Windows 95 action
 * i ax_after bx                    -> 1: Windows 95 (INT 2Fh 160Ah)
 * r notches                        -> MSWHEEL_ROLLMSG delta */
int main(int argc, char **argv)
{
    char c = argv[1][0];
    if (c == 'd') {
        printf("%u\n", wheel_decide(atoi(argv[2]), atoi(argv[3]), (unsigned char)atoi(argv[4]),
                                    strcmp(argv[5], "-") ? argv[5] : 0));
    } else if (c == 'k') {
        unsigned char mdb[16] = { 'N', 'E' };
        unsigned long f = strtoul(argv[2], 0, 16);
        if (argc > 3) mdb[0] = 'M';
        mdb[0x0C] = (unsigned char)f;
        mdb[0x0D] = (unsigned char)(f >> 8);
        printf("%u\n", wheel_module_kind(mdb));
    } else if (c == 'n') {
        printf("%d\n", wheel_notches((unsigned short)strtoul(argv[2], 0, 0), (unsigned short)strtoul(argv[3], 0, 0)));
    } else if (c == 'p') {
        unsigned short code = 99;
        int n = wheel_plan(atoi(argv[2]), strtoul(argv[3], 0, 16), &code);
        printf("%u %d\n", code, n);
    } else if (c == 'e') {
        printf("%u\n", wheel_decide95(atoi(argv[2]), atoi(argv[3]), atoi(argv[4])));
    } else if (c == 'i') {
        printf("%d\n", wheel_is_95((unsigned short)strtoul(argv[2], 0, 0), (unsigned short)strtoul(argv[3], 0, 0)));
    } else if (c == 'r') {
        printf("%d\n", wheel_roll_delta(atoi(argv[2])));
    } else if (c == 's') {
        printf("%d\n", wheel_swallow(atoi(argv[2]), strtoul(argv[3], 0, 0), strtoul(argv[4], 0, 0)));
    }
    return 0;
}
'''

WA_STOCK_NONE, WA_STOCK_32, WA_TRANSLATE, WA_OFF, WA_ROLLMSG = 1, 2, 3, 4, 5
UNKNOWN, WIN16, WIN32 = 0, 1, 2
SB_LINEUP, SB_LINEDOWN, SB_PAGEUP, SB_PAGEDOWN = 0, 1, 2, 3


def body(text: str, name: str) -> str:
    m = re.search(r'\b%s\s*\([^;{]*\)\s*\{' % name, text)
    assert m, name
    depth, i = 0, m.end() - 1
    for j in range(i, len(text)):
        depth += {'{': 1, '}': -1}.get(text[j], 0)
        if depth == 0:
            return text[i:j + 1]
    raise AssertionError(name)


class UsosKeyWheel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/usoskey-wheel-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS)
        cls.exe = work / 'wheel.exe'
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-O1', '-Wall', '-Werror', '-Wno-unused-function',
                        '-I', str(HEADER.parent), str(work / 'harness.c'), '-o', str(cls.exe)],
                       check=True, env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})
        cls.key = (WIN3 / 'usoskey.c').read_text(encoding='utf-8')
        cls.mouse = (WIN3 / 'usosmous.c').read_text(encoding='utf-8')

    def run_h(self, *args):
        return subprocess.run([str(self.exe)] + [str(a) for a in args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def decide(self, enabled, target, kind, cls):
        return int(self.run_h('d', int(enabled), int(target), kind, cls))

    # --- classifier -------------------------------------------------------
    def test_win16_window_under_the_pointer_is_translated(self):
        self.assertEqual(self.decide(1, 1, WIN16, 'ListBox'), WA_TRANSLATE)
        self.assertEqual(self.decide(1, 1, WIN16, 'Edit'), WA_TRANSLATE)

    def test_me_device_manager_tree_is_translated_whoever_owns_it(self):
        # 16-bit COMMCTRL.DLL: "SysTreeView" / "SysListView" without "32".
        for kind in (UNKNOWN, WIN16, WIN32):
            self.assertEqual(self.decide(1, 1, kind, 'SysTreeView'), WA_TRANSLATE)
            self.assertEqual(self.decide(1, 1, kind, 'systreeview'), WA_TRANSLATE)
            self.assertEqual(self.decide(1, 1, kind, 'SysListView'), WA_TRANSLATE)

    def test_win32_wheel_aware_windows_keep_the_stock_path(self):
        # Explorer's SysListView32, IE, Win32 list boxes: no double scrolling.
        for cls in ('SysListView32', 'SysTreeView32', 'ListBox', 'Internet Explorer_Server', 'SysTreeView3'):
            self.assertEqual(self.decide(1, 1, WIN32, cls), WA_STOCK_32, cls)
            self.assertEqual(self.decide(1, 1, UNKNOWN, cls), WA_STOCK_32, cls)   # unknown module: Win32

    def test_nothing_scrollable_and_switched_off(self):
        self.assertEqual(self.decide(1, 0, WIN16, '-'), WA_STOCK_NONE)
        self.assertEqual(self.decide(0, 1, WIN16, 'SysTreeView'), WA_OFF)

    def test_module_kind_from_the_module_database(self):
        self.assertEqual(int(self.run_h('k', '8301')), WIN16)       # a DLL (NE)
        self.assertEqual(int(self.run_h('k', '0302')), WIN16)       # a program
        self.assertEqual(int(self.run_h('k', '8010')), WIN32)       # Win9x: NE_FFLAGS_WIN32
        self.assertEqual(int(self.run_h('k', '0010')), WIN32)
        self.assertEqual(int(self.run_h('k', '8301', 'x')), UNKNOWN)  # no "NE"

    # --- delta and plan ---------------------------------------------------
    def test_notches_from_the_wrapping_counter(self):
        self.assertEqual(int(self.run_h('n', 5, 3)), 2)
        self.assertEqual(int(self.run_h('n', 3, 5)), -2)
        self.assertEqual(int(self.run_h('n', 1, 0xFFFF)), 2)        # wrapped
        self.assertEqual(int(self.run_h('n', 0xFFFE, 1)), -3)

    def test_plan_lines_and_pages(self):
        self.assertEqual(self.run_h('p', 1, '3'), f'{SB_LINEUP} 3')
        self.assertEqual(self.run_h('p', -2, '3'), f'{SB_LINEDOWN} 6')
        self.assertEqual(self.run_h('p', -1, '1'), f'{SB_LINEDOWN} 1')
        self.assertEqual(self.run_h('p', 1, 'FFFFFFFF'), f'{SB_PAGEUP} 1')    # WHEEL_PAGESCROLL (32-bit)
        self.assertEqual(self.run_h('p', -3, 'FFFF'), f'{SB_PAGEDOWN} 3')     # 16-bit UINT
        self.assertEqual(self.run_h('p', 2, '0'), f'{SB_LINEUP} 0')           # lines 0: nothing
        self.assertEqual(self.run_h('p', 0, '3').split()[1], '0')
        self.assertEqual(self.run_h('p', 1, '1F4'), f'{SB_LINEUP} 3')         # nonsense: 3
        self.assertEqual(self.run_h('p', 200, '3'), f'{SB_LINEUP} 60')        # capped
        self.assertEqual(self.run_h('p', -30000, '64'), f'{SB_LINEDOWN} 60')  # no 16-bit overflow

    def test_swallow_window(self):
        self.assertEqual(self.run_h('s', 1, 10000, 9990), '1')
        self.assertEqual(self.run_h('s', 1, 10000, 10000), '1')
        self.assertEqual(self.run_h('s', 1, 10000, 10001), '0')      # a later notch decides anew
        self.assertEqual(self.run_h('s', 1, 10000, 7000), '0')       # too old
        self.assertEqual(self.run_h('s', 0, 10000, 9990), '0')       # stock decision: never
        self.assertEqual(self.run_h('s', 1, 5, 0xFFFFFFFE), '1')     # tick wrap

    # --- Windows side (source level) ----------------------------------------
    def test_hook_is_task_time_and_separate_from_the_dos_box_guard(self):
        start = body(self.key, 'wheel_start')
        self.assertIn('SetWindowsHookEx(WH_GETMESSAGE, (HOOKPROC)getmsg_proc, GetModuleHandle("USOSKEY"), 0)', start)
        self.assertIn('GetPrivateProfileInt("usosmous", "WheelScroll", 1, "SYSTEM.INI")', start)
        self.assertIn('mouse_export("USOSWHEELINFO")', start)
        self.assertIn('w->version < 2', start)
        self.assertIn('wheel_start();', body(self.key, 'start'))
        self.assertIn('wheel_stop();', body(self.key, 'stop'))
        self.assertNotIn('wheel', body(self.key, 'cbt_proc'))
        self.assertNotIn('wheel', body(self.key, 'poll_body'))

    def test_hook_decides_from_the_real_delta_and_swallows_translated_notches(self):
        hook = body(self.key, 'getmsg_proc')
        self.assertIn('if (mwi->notches != notch_seen) wheel_new();', hook)
        self.assertIn('m->message == WM_MOUSEWHEEL && wheel_swallow(swallow_on, translated_at, m->time)', hook)
        self.assertIn('m->message = WM_NULL;', hook)
        self.assertIn('CallNextHookEx(msg_hook, code, wp, lp)', hook)
        self.assertIn('!wheel_busy', hook)
        new = body(self.key, 'wheel_new')
        self.assertIn('wheel_notches(mwi->notches, notch_seen)', new)
        self.assertIn('wheel_decide(1, t != 0, kind, wcls)', new)
        self.assertIn('PostMessage(t, WM_NULL, 0, 0L)', new)        # wake the target's task
        target = body(self.key, 'wheel_target')
        self.assertIn('WindowFromPoint(wpt)', target)
        self.assertIn('style & WS_VSCROLL', target)
        self.assertIn('GetParent(w)', target)

    def test_scroll_messages_only_in_the_targets_own_task(self):
        send = body(self.key, 'wheel_send')
        self.assertIn('if (GetWindowTask(w) != GetCurrentTask()) return;', send)
        self.assertLess(send.index('GetCurrentTask()'), send.index('SendMessage('))
        self.assertIn('SendMessage(w, WM_VSCROLL, wcode, 0L)', send)
        self.assertIn('SendMessage(w, WM_VSCROLL, WHEEL_SB_ENDSCROLL, 0L)', send)
        self.assertIn('SPI_GETWHEELSCROLLLINES', send)
        self.assertIn('GetTickCount() - pend_tick > 1000', send)       # never a stale batch

    def test_mouse_counter_moves_before_user_gets_the_event(self):
        wheel = body(self.mouse, 'call_wheel')
        self.assertLess(wheel.index('winfo.notches -= (WORD)sum;'), wheel.index('call dword ptr event_proc'))
        self.assertIn('static WHEELINFO winfo = { 2, 0, 0, 0xFF };', self.mouse)
        # The layouts USOSKEY.DRV and USOSDBG.EXE read agree with the driver's.
        tail = 'int last_sum;'
        for text in (self.key, (ROOT / 'src/platform/bios/win9x/usosdbg.c').read_text(encoding='utf-8')):
            seg = text[text.index(tail):text.index(tail) + 80]
            self.assertIn('WORD notches;', seg)

    def test_decision_log_for_usosdbg_and_usoslog(self):
        self.assertIn('DWORD FAR PASCAL __export __loadds UsosWheelLog(void)', self.key)
        dbg = (ROOT / 'src/platform/bios/win9x/usosdbg.c').read_text(encoding='utf-8')
        show = body(dbg, 'show_wheelscroll')
        self.assertIn('GetProcAddress(key, "USOSWHEELLOG")', show)
        self.assertIn('translated to WM_VSCROLL', show)
        self.assertIn('show_wheel();\n    show_wheelscroll();', dbg)
        log = (ROOT / 'src/platform/bios/win9x/usoslog.c').read_text(encoding='utf-8')
        journal = body(log, 'journal')
        # Journal records carry no wheel delta (Me: paramH is the pointer y):
        # no direction is derived from them any more.
        self.assertNotIn('paramH > 0', journal)
        self.assertNotIn('g_wheel_pos', log)
        self.assertIn('no delta in journal records: see WHEEL USOSKEY', log)


    # --- Windows 95 (no WM_MOUSEWHEEL in USER) -------------------------------
    def test_95_always_translates_a_scroll_bar_window(self):
        # Win16 and Win32 alike: no 95 window ever gets WM_MOUSEWHEEL.
        self.assertEqual(int(self.run_h('e', 1, 1, 1)), WA_TRANSLATE)
        self.assertEqual(int(self.run_h('e', 1, 1, 0)), WA_TRANSLATE)
        self.assertEqual(int(self.run_h('e', 1, 0, 1)), WA_ROLLMSG)     # MSWheel apps (IE 3, COMCTL32)
        self.assertEqual(int(self.run_h('e', 1, 0, 0)), WA_STOCK_NONE)  # MSWheel=0
        self.assertEqual(int(self.run_h('e', 0, 1, 1)), WA_OFF)

    def test_95_is_told_from_98_by_int2f_160a(self):
        self.assertEqual(self.run_h('i', 0, 0x0400), '1')     # 95 / 95 OSR2
        self.assertEqual(self.run_h('i', 0, 0x040A), '0')     # 98 / 98 SE
        self.assertEqual(self.run_h('i', 0, 0x045A), '0')     # Me
        self.assertEqual(self.run_h('i', 0x160A, 0x0400), '0')  # call not supported
        self.assertEqual(self.run_h('i', 0, 0x030A), '0')     # Windows 3.1

    def test_rollmsg_delta(self):
        self.assertEqual(self.run_h('r', 1), '120')
        self.assertEqual(self.run_h('r', -2), '-240')
        self.assertEqual(self.run_h('r', 1000), str(273 * 120))   # stays a 16-bit int
        self.assertEqual(self.run_h('r', -1000), str(-273 * 120))

    def test_95_hook_side(self):
        start = body(self.key, 'wheel_start')
        self.assertIn('w95 = (BYTE)windows_95();', start)
        self.assertIn('RegisterWindowMessage("MSWHEEL_ROLLMSG")', start)
        self.assertIn('GetPrivateProfileInt("usosmous", "MSWheel", 1, "SYSTEM.INI")', start)
        self.assertIn('int 2Fh', body(self.key, 'windows_95'))
        self.assertIn('wheel_is_95(ax_after, wver)', body(self.key, 'windows_95'))
        new = body(self.key, 'wheel_new')
        self.assertIn('w95 ? wheel_decide95(1, t != 0, rollmsg != 0) : wheel_decide(1, t != 0, kind, wcls)', new)
        self.assertIn('PostMessage(t, rollmsg, (WPARAM)wheel_roll_delta(n), MAKELONG(wpt.x, wpt.y))', new)
        self.assertNotIn('SendMessage', new)                     # the hook never waits for another task

    def test_95_mouse_driver_counts_notches_without_user_wheel_event(self):
        wheel = body(self.mouse, 'call_wheel')
        self.assertLess(wheel.index('winfo.notches -= (WORD)sum;'), wheel.index('if (!user_wheel) return;'))
        self.assertLess(wheel.index('if (!user_wheel) return;'), wheel.index('mov ax, SF_WHEEL'))
        wanted = body(self.mouse, 'wheel_wanted')
        self.assertIn('user_wheel = (BYTE)!windows_95();', wanted)
        self.assertIn('wheel_pref = 2;', wanted)                  # the counter runs on 95 OSR2 (DOS 7.10)
        self.assertIn('int 2Fh', body(self.mouse, 'windows_95'))
        self.assertIn('&& user_wheel) exists = MS_EXISTS_WHEEL;', body(self.mouse, 'Inquire'))
        # windows_95 (INT 2Fh) is task time only: never from the timer path.
        self.assertNotIn('windows_95', body(self.mouse, 'poll_body'))


if __name__ == '__main__':
    unittest.main()
