"""MS-DOS batch files of USOS: labels and the Windows 3.x install flow.

COMMAND.COM compares only the first 8 characters of a label (case-insensitive)
and jumps to the FIRST match. `:restart_ready` and `:restart_now` in
INSTALL.BAT were the same label for MS-DOS, so `goto restart_now` looped back
and printed "REBOOT is prepared below" forever (X470, 2026-10-06).

Scans every .cmd/.bat under src/platform/bios and the batch text that the
tools/*.sh scripts write through heredocs. Also pins the restart and Setup
details of the Windows 3.x flow (docs/design/bios-via-csmwrap.md 8.4/8.5).
Run: python tools/tests/test_dos_batch_labels.py
"""
from pathlib import Path
import re
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MSDOS = ROOT / 'src/platform/bios/msdos'
LABEL = re.compile(r'^\s*:([A-Za-z0-9_\-$#@]+)')
GOTO = re.compile(r'\bgoto\s+:?([^\s%]+)\s*$', re.I)
HEREDOC = re.compile(r"<<-?\s*'?\"?([A-Za-z_]+)'?\"?")


def batch_sources():
    """(name, lines) for every batch text USOS ships or writes."""
    for path in sorted((ROOT / 'src/platform/bios').rglob('*')):
        if path.suffix.lower() in ('.cmd', '.bat'):
            yield str(path.relative_to(ROOT)), path.read_text(encoding='latin-1').splitlines()
    for path in sorted((ROOT / 'tools').glob('*.sh')):
        lines = path.read_text(encoding='latin-1').splitlines()
        index = 0
        while index < len(lines):
            match = HEREDOC.search(lines[index])
            if not match:
                index += 1
                continue
            end = match.group(1)
            body = []
            index += 1
            while index < len(lines) and lines[index].strip() != end:
                body.append(lines[index])
                index += 1
            # Batch text only: a label or a GOTO in the heredoc.
            if any(LABEL.match(line) for line in body) or any(GOTO.search(line) for line in body):
                yield '%s heredoc %s' % (path.relative_to(ROOT), end), body
            index += 1


def labels(lines):
    return [m.group(1) for m in map(LABEL.match, lines) if m]


class BatchLabels(unittest.TestCase):
    def test_sources_found(self):
        names = [name for name, _ in batch_sources()]
        self.assertIn('src/platform/bios/msdos/install.cmd', [n.replace('\\', '/') for n in names])
        self.assertTrue(any('w9x_tzfix.sh heredoc' in n for n in names), names)

    def test_first_eight_characters_unique(self):
        for name, lines in batch_sources():
            seen = {}
            for label in labels(lines):
                key = label[:8].lower()
                self.assertNotIn(key, seen, '%s: :%s and :%s are the same label for MS-DOS' % (name, seen.get(key), label))
                seen[key] = label

    def test_every_goto_has_a_label(self):
        for name, lines in batch_sources():
            known = {label[:8].lower() for label in labels(lines)}
            for line in lines:
                # REM lines, and ECHO lines writing another batch file.
                if re.match(r'\s*(rem|@?echo)(\s|$)', line, re.I):
                    continue
                match = GOTO.search(line)
                if match and '$' not in match.group(1):
                    self.assertIn(match.group(1)[:8].lower(), known, '%s: %s' % (name, line.strip()))

    def test_detects_the_x470_collision(self):
        self.assertEqual('restart_ready'[:8], 'restart_now'[:8])


class Windows3Flow(unittest.TestCase):
    def text(self, name):
        return (MSDOS / name).read_text(encoding='ascii')

    def section(self, text, start, stop):
        return text[text.index('\n:' + start + '\n'):text.index('\n:' + stop + '\n')]

    def test_disk_mode_restarts_automatically(self):
        text = self.text('install.cmd')
        for start, stop in (('s1_disk', 's1_text'), ('done_disk', 'reboot_prompt')):
            part = self.section(text, start, stop)
            self.assertIn('restarts from the target disk automatically', part)
            self.assertNotIn('Remove USOS USB', part)
        auto = self.section(text, 'auto_restart', 'failed')
        self.assertIn('C:\\DOS\\CHOICE.COM /C:R /T:R,8 ', auto)
        self.assertNotIn('/P', auto)
        self.assertIn('%USRC%\\REBOOT.COM\n', auto)
        prompt = self.section(text, 'reboot_prompt', 'auto_restart')
        self.assertLess(prompt.index('goto auto_restart'), prompt.index('REBOOT is prepared'))

    def test_final_restart_countdown(self):
        text = self.text('windows_menu.cmd')
        flush = text.index('SMARTDRV.EXE /C', text.index(':ready'))
        choice = text.index('C:\\DOS\\CHOICE.COM /C:RA /T:R,5 ')
        self.assertLess(flush, choice)
        after = text[choice:text.index('\n:stay_dos\n')]
        self.assertIn('if errorlevel 2 goto stay_dos', after)
        self.assertIn('C:\\DOS\\REBOOT.COM\n', after)
        # No CHOICE.COM: the earlier prefilled REBOOT prompt.
        self.assertIn('if not exist C:\\DOS\\CHOICE.COM goto prefill_reboot', text)
        self.assertIn('C:\\DOS\\REBOOT.COM /P', self.section(text, 'prefill_reboot', 'manual_restart'))
        self.assertIn('if not exist %2\\CHOICE.COM goto failed', self.text('prepare_files.cmd'))

    def test_choice_text_has_no_switch_characters(self):
        for name in ('install.cmd', 'windows_menu.cmd'):
            for line in self.text(name).splitlines():
                if 'CHOICE.COM /C:' in line:
                    prompt = line.split(' ', 3)[3]
                    self.assertNotRegex(prompt, r'[/=,;"]', line)

    def test_menu_colour_readable(self):
        menu = self.text('windows_config.sys').split('[common]')[0]
        self.assertIn('menucolor=15,1\n', menu)

    def test_add852_autostart_filter(self):
        bas = self.text('windows_inf.bas')
        self.assertIn('INSTR(LCASE$(l$), "add852.exe /a")', bas)
        install = self.text('install.cmd')
        run = install.index('C:\\DOS\\QBASIC.EXE /RUN %USRC%\\W3INF.BAS')
        self.assertLess(install.index('C:\\DOS\\XCOPY.EXE %USRC%\\WINSETUP'), run)
        self.assertLess(run, install.index('copy C:\\WINSETUP\\SETUP.NEW C:\\WINSETUP\\SETUP.INF'))
        # The Polish SETUP.INF lines (CP852 bytes as latin-1): only Autostart goes.
        lines = ['[group3]', '"Obs\xb3uga strony kodowej 852",  add852.exe',
                 '[group1]', '"Obs\xb3uga strony kodowej 852",  "add852.exe /A"', '"Wska\x9fnik klawiatury", "ruslat.exe"']
        kept = [l for l in lines if 'add852.exe /a' not in l.lower()]
        self.assertEqual(kept, lines[:3] + lines[4:])


class RebootHelper(unittest.TestCase):
    def test_reset_order_in_source(self):
        text = (MSDOS / 'reboot.S').read_text(encoding='ascii')
        restart = text[text.index('.restart:'):text.index('.keys:')]
        order = [restart.index(s) for s in ('mov dx, 0xcf9', 'mov al, 0x02', 'mov al, 0x06', 'out 0x64, al',
                                              'mov al, 0x8f', 'out 0x70, al', 'out 0x71, al', '.byte 0xea')]
        self.assertEqual(order, sorted(order))

    def test_built_binary_clears_cmos_shutdown_status(self):
        zig = ROOT / 'tools/zig/zig.exe'
        if not zig.exists():
            self.skipTest('tools/zig/zig.exe missing')
        import sys
        sys.path.insert(0, str(ROOT / 'tools'))
        from build_dos_reboot import build
        out = Path(tempfile.mkdtemp())
        try:
            binary = build(ROOT, out).read_bytes()
        finally:
            pass
        # mov al,8Fh; out 70h,al; xor al,al; out 71h,al; jmp far FFFF:0000
        tail = bytes.fromhex('b08fe67030c0e671ea0000ffff')
        self.assertIn(tail, binary)
        self.assertLess(binary.index(bytes.fromhex('b0fee664')), binary.index(tail))
        self.assertLess(binary.index(bytes.fromhex('baf90cb002eeb006ee')), binary.index(bytes.fromhex('b0fee664')))
        shutil.rmtree(out, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
