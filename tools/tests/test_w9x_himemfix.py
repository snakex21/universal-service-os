"""One HIMEM.SYS line in CONFIG.SYS after 95 / 98 Setup (host-only).

X470 98 FE PL native, 2026-10-27: INSTALL.BAT (src/platform/bios/
dos_startup.cmd) writes DEVICE=C:\\WINDOWS\\HIMEM.SYS and, for a restart
before Setup copied that file, DEVICE=C:\\USOS9X\\HIMEM.SYS; Setup turned the
second into another C:\\WINDOWS\\HIMEM.SYS line (BOOTLOG.TXT: LoadSuccess,
then LoadFailed for the same file). tools/w9x_csmwrap_target.sh stages
HIMEMFIX.BAT + CFGHEAD.SYS; AUTOEXEC.BAT calls it at every start until
HIMEMFIX.OK. Here the batch runs in a small interpreter with MS-DOS 7
COMMAND.COM / FIND semantics (IF EXIST, FIND /V /I from stdin with
ERRORLEVEL, COPY /B a + b, ECHO > / >>, GOTO). Real DOS is X470 evidence."""
from pathlib import Path
import re
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'
INSTALL = ROOT / 'src/platform/bios/dos_startup.cmd'

# C:\CONFIG.SYS of the X470 98 FE PL native run after Setup (2026-10-27)
EVIDENCE = (b'DEVICE=C:\\USOS9X\\CREGFIX.SYS\r\nDEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n'
            b'DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n'
            b'device=C:\\WINDOWS\\COMMAND\\display.sys con=(ega,,1)\r\n'
            b'Country=048,852,C:\\WINDOWS\\COMMAND\\country.sys\r\n')
WANT = (b'DEVICE=C:\\USOS9X\\CREGFIX.SYS\r\nDEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n'
        b'device=C:\\WINDOWS\\COMMAND\\display.sys con=(ega,,1)\r\n'
        b'Country=048,852,C:\\WINDOWS\\COMMAND\\country.sys\r\n')


def staged():
    text = TARGET.read_text(encoding='utf-8')
    start = text.index('''sed 's/$/\\r/' > "$work/c/USOS9X/HIMEMFIX.BAT" <<'EOF' ''')
    body = text[text.index('\n', start) + 1:]
    body = body[:body.index('\nEOF\n')]
    head = re.search(r"printf '([^']*)' > \"\$work/c/USOS9X/CFGHEAD.SYS\"", text).group(1)
    head = head.replace('\\\\', '\x00').replace('\\r\\n', '\r\n').replace('\x00', '\\')
    return body.split('\n'), head.encode('ascii'), text


class Dos:
    """Just enough COMMAND.COM for HIMEMFIX.BAT; C:\\ is a folder."""

    def __init__(self, root):
        self.root = root
        self.errorlevel = 0

    def path(self, dos):
        assert dos.upper().startswith('C:\\'), dos
        return self.root.joinpath(*dos[3:].split('\\'))

    def exists(self, dos):
        return self.path(dos).exists()

    def run(self, lines):
        labels = {l[1:].strip().upper(): i for i, l in enumerate(lines) if l.startswith(':')}
        i = 0
        steps = 0
        while i < len(lines):
            steps += 1
            assert steps < 200
            line = lines[i].strip()
            i += 1
            if not line or line.startswith(':') or line.upper() == '@ECHO OFF':
                continue
            m = re.match(r'IF (NOT )?EXIST (\S+) (.*)$', line)
            if m:
                if bool(self.exists(m.group(2))) != bool(m.group(1)):
                    line = m.group(3)
                else:
                    continue
            m = re.match(r'IF ERRORLEVEL (\d+) (.*)$', line)
            if m:
                if self.errorlevel >= int(m.group(1)):
                    line = m.group(2)
                else:
                    continue
            m = re.match(r'GOTO (\S+)$', line)
            if m:
                i = labels[m.group(1).upper()] + 1
                continue
            m = re.match(r'C:\\WINDOWS\\COMMAND\\FIND\.EXE ((?:/[VI] )*)"([^"]*)" < (\S+) > (\S+)$', line)
            if m:
                inv = '/V' in m.group(1)
                needle = m.group(2).lower()
                rows = self.path(m.group(3)).read_bytes().decode('latin-1').splitlines()
                hits = [r for r in rows if (needle in r.lower()) != inv]
                self.errorlevel = 0 if hits else 1
                if m.group(4).upper() != 'NUL':
                    self.path(m.group(4)).write_bytes(''.join(r + '\r\n' for r in hits).encode('latin-1'))
                continue
            m = re.match(r'COPY /B (\S+) \+ (\S+) (\S+) > NUL$', line)
            if m:
                self.path(m.group(3)).write_bytes(self.path(m.group(1)).read_bytes() + self.path(m.group(2)).read_bytes())
                continue
            m = re.match(r'COPY /Y (\S+) (\S+) > NUL$', line)
            if m:
                shutil.copyfile(self.path(m.group(1)), self.path(m.group(2)))
                continue
            m = re.match(r'DEL (\S+)$', line)
            if m:
                self.path(m.group(1)).unlink()
                continue
            m = re.match(r'ECHO (.*?)(>>?) ?(\S+)$', line)
            if m:
                with open(self.path(m.group(3)), 'ab' if m.group(2) == '>>' else 'wb') as f:
                    f.write(m.group(1).encode('latin-1') + b'\r\n')
                continue
            raise AssertionError('not understood: ' + line)


class HimemFix(unittest.TestCase):
    def setUp(self):
        self.c = Path(tempfile.mkdtemp(prefix='usos-himemfix-'))
        self.addCleanup(shutil.rmtree, self.c, ignore_errors=True)
        (self.c / 'USOS9X').mkdir()
        (self.c / 'WINDOWS/COMMAND').mkdir(parents=True)
        self.lines, head, _ = staged()
        (self.c / 'USOS9X/CFGHEAD.SYS').write_bytes(head)
        (self.c / 'WINDOWS/COMMAND/FIND.EXE').write_bytes(b'x')

    def boot(self):
        Dos(self.c).run(self.lines)

    def test_evidence_config_gets_one_himem_line(self):
        (self.c / 'WINDOWS/WIN.COM').write_bytes(b'x')
        (self.c / 'WINDOWS/HIMEM.SYS').write_bytes(b'x')
        (self.c / 'CONFIG.SYS').write_bytes(EVIDENCE)
        self.boot()
        self.assertEqual((self.c / 'CONFIG.SYS').read_bytes(), WANT)
        self.assertEqual((self.c / 'USOS9X/CONFIG.HM0').read_bytes(), EVIDENCE)
        self.assertTrue((self.c / 'USOS9X/HIMEMFIX.OK').exists())
        # later starts: nothing touched again
        (self.c / 'CONFIG.SYS').write_bytes(EVIDENCE)
        self.boot()
        self.assertEqual((self.c / 'CONFIG.SYS').read_bytes(), EVIDENCE)

    def test_fallback_line_before_setup_rewrote_it(self):
        # Setup has its HIMEM.SYS and WIN.COM, the fallback line still names C:\USOS9X
        (self.c / 'WINDOWS/WIN.COM').write_bytes(b'x')
        (self.c / 'WINDOWS/HIMEM.SYS').write_bytes(b'x')
        before = (b'DEVICE=C:\\USOS9X\\CREGFIX.SYS\r\nDEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n'
                  b'DEVICE=C:\\USOS9X\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n'
                  b'device=C:\\WINDOWS\\COMMAND\\display.sys con=(ega,,1)\r\n'
                  b'Country=048,852,C:\\WINDOWS\\COMMAND\\country.sys\r\n')
        (self.c / 'CONFIG.SYS').write_bytes(before)
        self.boot()
        self.assertEqual((self.c / 'CONFIG.SYS').read_bytes(), WANT)

    def test_waits_for_setup_and_leaves_foreign_configs(self):
        (self.c / 'CONFIG.SYS').write_bytes(EVIDENCE)
        self.boot()                                       # no WIN.COM yet: Setup still needs the fallback
        self.assertEqual((self.c / 'CONFIG.SYS').read_bytes(), EVIDENCE)
        self.assertFalse((self.c / 'USOS9X/HIMEMFIX.OK').exists())
        (self.c / 'WINDOWS/WIN.COM').write_bytes(b'x')
        self.boot()                                       # no C:\WINDOWS\HIMEM.SYS yet
        self.assertEqual((self.c / 'CONFIG.SYS').read_bytes(), EVIDENCE)
        (self.c / 'WINDOWS/HIMEM.SYS').write_bytes(b'x')
        other = b'DEVICE=C:\\WINDOWS\\HIMEM.SYS\r\nDOS=HIGH\r\n'
        (self.c / 'CONFIG.SYS').write_bytes(other)       # not our layout (no CREGFIX line): untouched
        self.boot()
        self.assertEqual((self.c / 'CONFIG.SYS').read_bytes(), other)
        self.assertFalse((self.c / 'USOS9X/HIMEMFIX.OK').exists())

    def test_staging_and_autoexec_hook(self):
        lines, head, text = staged()
        self.assertEqual(head, b'DEVICE=C:\\USOS9X\\CREGFIX.SYS\r\nDEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n')
        block = text[text.index('if [ -f "$work/c/USOS9X/CREGFIX.SYS" ] && [ "$SYSTEM_TAG" != ME ]; then'):]
        self.assertLess(block.index('CFGHEAD.SYS'), block.index('HIMEMFIX.BAT'))
        self.assertLessEqual(max(map(len, lines)), 127)
        for i, l in enumerate(lines):                    # 950 COPY sets no reliable ERRORLEVEL
            if l.startswith('COPY '):
                self.assertFalse(lines[i + 1].startswith('IF ERRORLEVEL'), l)
            if l.startswith('C:\\WINDOWS\\COMMAND\\FIND.EXE'):
                self.assertIn(' < ', l)                  # stdin: no "----------" header
        install = INSTALL.read_text(encoding='latin-1').splitlines()
        hook = 'ECHO @IF EXIST C:\\USOS9X\\HIMEMFIX.BAT CALL C:\\USOS9X\\HIMEMFIX.BAT>>C:\\AUTOEXEC.BAT'
        self.assertIn(hook, install)
        self.assertLess(install.index(':CSMAUTO'), install.index(hook))
        self.assertLess(install.index(':CSMFIXOK'), install.index(hook))
        # the generator itself is unchanged: the fallback line stays for a restart before Setup's copy
        self.assertIn('ECHO DEVICE=C:\\USOS9X\\HIMEM.SYS /TESTMEM:OFF /M:2>>C:\\CONFIG.SYS', install)


if __name__ == '__main__':
    unittest.main()
