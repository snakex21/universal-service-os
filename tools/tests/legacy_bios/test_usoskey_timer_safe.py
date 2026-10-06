"""USOSKEY.DRV / USOSMOUS.DRV timer callbacks stay interrupt-safe.

The SYSTEM.DRV timer callback (poll) interrupts whatever runs in the system
VM, Win32 threads included. On the X470 98 SE (2026-10-06) Win32 processes
died in KERNEL32's exit path (0167:BFF8976B) while USOSKEY.DRV v3 called
GetAsyncKeyState from it. This source-level check walks the call graph from
each driver's poll_body over the functions defined in the driver and its
headers and fails on any other function call (a Windows API), any INT
instruction and any far call other than USER's interrupt-time entries
(keybd_event / the mouse event procedure) and VKD's PM API. The poll entry
itself must save all 32-bit registers and FS/GS."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
WIN3 = ROOT / 'src/platform/win3'

C_WORDS = {'if', 'for', 'while', 'switch', 'return', 'sizeof', 'case'}
# Windows header macros (no code of their own).
MACROS = {'LOBYTE', 'HIBYTE', 'LOWORD', 'HIWORD', 'MAKELP'}
ALLOWED_FAR_CALLS = {'keybd_event_proc', 'vkd_entry', 'event_proc'}

FUNC_RE = re.compile(r'^[A-Za-z_][^;\n]*?\b([A-Za-z_]\w*)\s*\(([^;{()]*)\)\s*\n?\{', re.M)


def functions(text: str) -> dict:
    """name -> body of every function defined at file level."""
    found = {}
    for m in FUNC_RE.finditer(text):
        start = m.end() - 1
        depth = 0
        for i in range(start, len(text)):
            if text[i] == '{':
                depth += 1
            elif text[i] == '}':
                depth -= 1
                if depth == 0:
                    found[m.group(1)] = text[start:i + 1]
                    break
    return found


def strip_comments(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


class TimerSafe(unittest.TestCase):
    def check(self, source: str, headers: list[str]):
        text = strip_comments(''.join((WIN3 / h).read_text(encoding='utf-8') for h in headers + [source]))
        # Function-like macros that forward to a function (xlat_event ->
        # keyboard_event): follow the function.
        for macro, target in re.findall(r'#define\s+(\w+)\([^)]*\)\s+(\w+)\s*\(', text):
            text = re.sub(r'\b%s\s*\(' % macro, target + '(', text)
        funcs = functions(text)
        self.assertIn('poll_body', funcs)
        seen, todo, bad = set(), ['poll_body'], []
        while todo:
            name = todo.pop()
            if name in seen:
                continue
            seen.add(name)
            body = funcs[name]
            asm = ' '.join(re.findall(r'_asm\s*\{(.*?)\}', body, flags=re.S))
            code = re.sub(r'_asm\s*\{.*?\}', ' ', body, flags=re.S)
            for call in re.findall(r'\b([A-Za-z_]\w*)\s*\(', code):
                if call in C_WORDS or call in MACROS or call in seen:
                    continue
                if call in funcs:
                    todo.append(call)
                else:
                    bad.append(f'{name} calls {call}()')
            if re.search(r'\bint\s+[0-9]', asm, flags=re.I):
                bad.append(f'{name} executes an INT instruction')
            for target in re.findall(r'\bcall\s+(?:dword\s+ptr\s+)?(\w+)', asm, flags=re.I):
                if target not in ALLOWED_FAR_CALLS and target not in funcs:
                    bad.append(f'{name} calls {target} from inline assembly')
        self.assertEqual(bad, [], f'{source}: not interrupt-safe at timer time')
        return funcs, seen

    def check_entry(self, funcs: dict):
        entry = funcs['poll'].lower()
        for insn in ('pushad', 'push fs', 'push gs', 'call poll_body', 'pop gs', 'pop fs', 'popad', 'retf'):
            self.assertIn(insn, entry)

    def test_usoskey(self):
        funcs, seen = self.check('usoskey.c', ['usoskey_xlat.h'])
        self.assertTrue({'translate', 'keyboard_event', 'force_key', 'sync_bios_flags'} <= seen)
        self.check_entry(funcs)
        src = (WIN3 / 'usoskey.c').read_text(encoding='utf-8')
        # The DOS-box test lives in the CBT hook, not on the timer path.
        self.assertIn('GetClassName', funcs['cbt_proc'])
        self.assertNotIn('GetAsyncKeyState', strip_comments(src))

    def test_usosmous(self):
        funcs, seen = self.check('usosmous.c', ['usosmous_scale.h'])
        self.assertTrue({'call_event', 'scale_move'} <= seen)
        self.check_entry(funcs)


if __name__ == '__main__':
    unittest.main()
