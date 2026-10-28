"""Windows 9x: no USOS Run / RunOnce command opens an MS-DOS window.

Windows 95 / 98 keep the window of an MS-DOS program or batch file started
inside Windows open after it ends ("Zakonczone" / "Finished" in the title)
unless its PIF says close on exit. Every command USOS queues in the machine
Run / RunOnce keys of a 9x install must therefore be a Windows program
(Win32 or Win16), never COMMAND.COM, a .BAT / .COM / .PIF, or an unknown
program. Inventory (2026-10-25):

  USOSWelcome  RUNDLL.EXE setupx InstallHinfSection (MSBATCH.INF)
  USOSMouse    RUNDLL.EXE setupx, USOSMOUS.INF (Me, INSTALL.BAT [Strings])
  USOSUsb      REGEDIT /s USOSUSB.REG (Me; REGEDIT.EXE is a Windows program)
  USOSVmd      RUNDLL.EXE setupx, USOSVMD.INF (INSTALL.BAT, REG95.REG, VMDRO.REG)
  USOSLog      C:\\USOS9X\\USOSLOG.EXE (Win32)
  USOSLan      C:\\USOS9X\\USOSLAN.EXE (Win32)
  USOSDisplay  C:\\USOS9X\\USOSRES.EXE (Win32)
  USOSAddons   C:\\USOS\\ADDONS\\USOSADD.EXE (Win32)
  TZFIX        RUNDLL32.EXE SHELL32.DLL (replaces RunOnce\\Setup steps)

A new value has to be added to WINDOWS_PROGRAMS on purpose (and checked to
be a Windows program, or given a close-on-exit PIF). Host only (Git sh).
Run: python tools/tests/test_w9x_run_no_dos_box.py
"""
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh
from test_w9x_reg95 import ANSWER_95

ROOT = Path(__file__).resolve().parents[2]
REG95 = (ROOT / 'tools/w9x_reg95.sh').as_posix()

# Lower-case program file names known to be Windows programs.
WINDOWS_PROGRAMS = {'rundll.exe', 'rundll32.exe', 'regedit', 'regedit.exe', 'usoslog.exe',
                    'usoslan.exe', 'usosres.exe', 'usosadd.exe'}
RUN_KEY = re.compile(r'CurrentVersion\\+Run(Once)?(\\+Setup)?\b', re.I)


def program(command):
    cmd = command.strip().strip('"').replace('\\\\', '\\')
    cmd = cmd.replace('%25%\\', '').replace('%10%\\', '')
    first = cmd.split()[0].strip('"')
    return first.replace('/', '\\').split('\\')[-1].lower()


def inf_run_commands(text):
    """HKLM,"...\\Run[Once]",Name,flags,"command" lines of an INF."""
    out = []
    for line in text.splitlines():
        if not line.upper().startswith('HKLM,'):
            continue
        if not (RUN_KEY.search(line.split(',')[1]) or re.search(r'%USOSR[ON]%', line)):
            continue
        parts = line.split(',', 4)
        if len(parts) < 5 or not parts[4].strip():
            continue                                  # a value deletion (DelReg)
        out.append((parts[2], parts[4]))
    return out


def reg_run_commands(text):
    """"Name"="command" values under a Run / RunOnce key of a REGEDIT4 file."""
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith('['):
            inside = bool(re.search(r'CurrentVersion\\Run(Once)?(\\Setup)?\]$', line, re.I))
            continue
        m = re.match(r'^"([^"]+)"="(.*)"$', line)
        if inside and m:
            out.append((m.group(1), m.group(2)))
    return out


class NoDosBox(unittest.TestCase):
    def check(self, commands, where):
        self.assertTrue(commands, where)
        for name, command in commands:
            exe = program(command)
            self.assertNotRegex(exe, r'\.(bat|com|pif)$', '%s %s: %s' % (where, name, command))
            self.assertNotIn('command', exe, '%s %s: %s' % (where, name, command))
            self.assertIn(exe, WINDOWS_PROGRAMS, '%s %s: %s (new program: Windows program or close-on-exit PIF?)'
                          % (where, name, command))

    def test_msbatch_templates(self):
        files = [ROOT / 'src/platform/bios/win9x/msbatch.inf']
        files += sorted((ROOT / 'src/flow/answer/testdata/golden').glob('*.windows-9*.inf'))
        files += sorted((ROOT / 'src/flow/answer/testdata/golden').glob('*.windows-me*.inf'))
        files += sorted((ROOT / 'src/flow/answer/testdata/golden').glob('*windows-9*MSBATCH.INF'))
        for f in files:
            self.check(inf_run_commands(f.read_text(encoding='latin-1')), f.name)

    def test_install_bat_strings(self):
        # INSTALL.BAT appends [USOS.CsmReg] Run / RunOnce lines; the commands
        # come from its [Strings] (USOSMC, USOSUC, USOSVC) or are inline.
        text = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1')
        strings = dict(re.findall(r'^ECHO (USOS[A-Z]C)="([^"]*)">>', text, flags=re.M))
        self.assertEqual(set(strings), {'USOSMC', 'USOSUC', 'USOSVC'})
        lines = [l[5:].split('>>')[0] for l in text.splitlines()
                 if l.startswith('ECHO HKLM,') and ('%%USOSRO%%' in l or '%%USOSRN%%' in l)]
        commands = []
        for name, value in ((l.split(',')[2], l.split(',', 4)[4]) for l in lines):
            m = re.fullmatch(r'"%%(USOS[A-Z]C)%%"', value)
            commands.append((name, strings[m.group(1)] if m else value))
        self.assertEqual(sorted(n for n, _ in commands), ['USOSLog', 'USOSMouse', 'USOSUsb', 'USOSVmd'])
        self.check(commands, 'dos_startup.cmd')

    def test_zig_run_lines(self):
        for rel in ('src/flow/answer/addons_profile.zig', 'src/flow/answer/network_defaults.zig'):
            text = (ROOT / rel).read_text(encoding='utf-8')
            commands = [(m.group(1), m.group(2)) for m in
                        re.finditer(r'CurrentVersion\\\\Run\\",(\w+),,\\"([^"\\]*(?:\\\\[^"\\]*)*)\\"', text)]
            self.check(commands, rel)

    def test_reg95_and_950_late_files(self):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-nodos-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'MSBATCH.INF').write_bytes(ANSWER_95.encode('ascii'))
        for version in ('4 0 0 950', '4 0 0 1111'):
            out = tmp / version.replace(' ', '_')
            (out / 'NET').mkdir(parents=True)
            rc, _, err = sh(f'. "{REG95}"\nw9x_reg95_write "{out.as_posix()}" "{(tmp / "MSBATCH.INF").as_posix()}" '
                            f'"$LOG" "$VMD" "" "$V"',
                            {'LOG': 'C:\\USOS9X\\USOSLOG.EXE', 'VMD': 'C:\\USOS9X\\USOSVMD.INF', 'V': version})
            self.assertEqual(rc, 0, err)
            for name in ('REG95.REG', 'VMDRO.REG'):
                if (out / name).exists():
                    self.check(reg_run_commands((out / name).read_bytes().decode('latin-1')), version + ' ' + name)

    def test_tzfix_replacement_command(self):
        text = (ROOT / 'tools/w9x_tzfix.sh').read_text(encoding='utf-8')
        harmless = re.findall(r"^\s*harmless='([^']*)'", text, flags=re.M)
        self.assertEqual(len(harmless), 1)
        self.check([('TZFIX', harmless[0])], 'w9x_tzfix.sh')

    def test_checker_refuses_dos_programs(self):
        for bad in ('C:\\USOS9X\\VMDLATE.BAT', 'command.com /c C:\\X.BAT', 'C:\\USOS9X\\U9FIX.COM /95',
                    'C:\\USOS9X\\DSPWIN.PIF', 'C:\\USOS9X\\NEWTOOL.EXE'):
            with self.assertRaises(AssertionError, msg=bad):
                self.check([('X', bad)], 'self-test')


if __name__ == '__main__':
    unittest.main()
