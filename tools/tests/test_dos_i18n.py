"""Host test: the DOS-side texts of the MS-DOS / Windows 1.x-3.x flow follow
the profile / USOS menu language (tools/build_dos_i18n.py, the dos.* keys of
installer/internal/i18n/locales, tools/dos_win3_menu.sh dos_i18n_apply).

Byte-level: every section is the catalog text in its DOS code page (437 for
the CONFIG.SYS menus and the install / menu-writer batch files, the
language's MS-DOS 6.22 country code page for W3AUTO / W1AUTO), the shell
renders the start files exactly as the Python rule does, and a language
whose script code page 437 cannot show keeps English there.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import build_dos_i18n as i18n  # noqa: E402

MSDOS = ROOT / 'src/platform/bios/msdos'
LIB = ROOT / 'tools/dos_win3_menu.sh'
SH = shutil.which('sh') or shutil.which('bash')
FILES = {'W3CONFIG.SYS': 'windows_config.sys', 'W1CONFIG.SYS': 'windows_early_config.sys',
         'W3AUTO.BAT': 'windows_auto.cmd', 'W1AUTO.BAT': 'windows_early_auto.cmd',
         'INSTALL.BAT': 'install.cmd', 'WINMENU.BAT': 'windows_menu.cmd', 'W3START.BAT': 'windows_start.cmd',
         'W1SETUP.BAT': 'windows_early_setup.cmd', 'NETSTART.BAT': 'network_start.cmd',
         'WINRUN.BAT': 'windows_run.cmd'}
CP437_FILES = ('W3CONFIG.SYS', 'W1CONFIG.SYS', 'INSTALL.BAT', 'WINMENU.BAT', 'W3START.BAT', 'W1SETUP.BAT', 'NETSTART.BAT')


def crlf(name: str) -> bytes:
    return (MSDOS / name).read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')


def parse(dostext: bytes) -> dict[str, dict[str, bytes]]:
    out: dict[str, dict[str, bytes]] = {}
    sec, key = None, None
    for line in dostext.split(b'\n')[:-1]:
        if key is None:
            if line.startswith(b';'):
                continue
            if line.startswith(b'['):
                sec = line[1:-1].decode()
                out[sec] = {}
                continue
            key = line.decode('ascii')
            continue
        out[sec][key] = line
        key = None
    return out


class Catalog(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cat = i18n.catalogs()
        cls.text = i18n.dostext(cls.cat)
        cls.sec = parse(cls.text)

    def test_checks_and_sections(self):
        i18n.check(self.cat)
        self.assertEqual(len(self.cat), 27)
        # Every catalog language has its 437 section, or (another script)
        # its native one only; Ukrainian (no MS-DOS 6.22 country) neither.
        for lang in self.cat:
            l = lang.lower()
            if lang in ('ru', 'bg', 'el', 'uk'):
                self.assertNotIn(l + '-437', self.sec)
            else:
                self.assertIn(l + '-437', self.sec)
            if lang in i18n.NATIVE:
                self.assertIn(f'{l}-{i18n.NATIVE[lang]}', self.sec)
        self.assertNotIn('uk-437', self.sec)
        self.assertEqual({k for k in self.sec if k.startswith('uk')}, set())

    def test_bytes_are_the_catalog_in_the_code_page(self):
        for name, table in self.sec.items():
            lang, cp = name.rsplit('-', 1)
            src = next(v for k, v in self.cat.items() if k.lower() == lang)
            for key, data in table.items():
                self.assertNotIn(b'\r', data)
                self.assertNotIn(b'\n', data)
                text = data.decode('cp' + cp)
                if text != src[key]:
                    # Only accents dropped (437 / a code page without the letter).
                    self.assertEqual(i18n.encode(src[key], int(cp)), data, (name, key))
                    self.assertTrue(cp == '437' or lang not in ('pl', 'cs', 'de', 'fr'), (name, key))
        pl852 = self.sec['pl-852']
        self.assertEqual(pl852['dos.menu.standard'], 'Windows - tryb standardowy (domyślny)'.encode('cp852'))
        self.assertIn(b'\x98', pl852['dos.menu.standard'])          # s with acute in 852
        self.assertEqual(self.sec['pl-437']['dos.menu.standard'], b'Windows - tryb standardowy (domyslny)')
        self.assertEqual(self.sec['pl-437']['dos.menu.diag'], b'Diagnostyka (D1-D6, tylko do test\xa2w)')
        self.assertEqual(self.sec['ru-866']['dos.menu.dos'], 'MS-DOS - командная строка'.encode('cp866'))
        self.assertEqual(self.sec['de-850']['dos.menu.diag'], 'Diagnose (D1-D6, nur für Tests)'.encode('cp850'))
        for data in self.sec['en-437'].values():
            data.decode('ascii')

    def test_every_english_text_is_a_line_of_the_sources(self):
        lines = set()
        for src in set(FILES.values()) | {'network_start_queue.cmd'}:
            for line in (MSDOS / src).read_bytes().split(b'\n'):
                m = i18n.LINE.match(line.rstrip(b'\r'))
                if m:
                    lines.add(m.group(2))
        for key, text in self.cat['en'].items():
            if key in i18n.SCRIPT_KEYS:
                continue            # written by dos_menu_names / dos_winsock_apply
            self.assertIn(text.encode('ascii'), lines, key)
        # No Polish left in the English sources.
        for src in set(FILES.values()):
            data = (MSDOS / src).read_bytes()
            data.decode('ascii')
            for word in (b'tryb ', b'domyslny', b'Brakuje', b'wiersz polecen', b'zrestartuj'):
                self.assertNotIn(word, data, src)


class Shell(unittest.TestCase):
    """dos_i18n_apply under the host's POSIX shell (MSYS awk drops the CR of
    each line, so the comparison is LF; the QEMU flow checks BusyBox)."""

    @classmethod
    def setUpClass(cls):
        cls.text = i18n.dostext(i18n.catalogs())
        cls.sec = parse(cls.text)

    def apply(self, lang: str, cp: int) -> tuple[dict[str, bytes], str]:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            for dst, src in FILES.items():
                (d / dst).write_bytes(crlf(src))
            (d / 'DOSTEXT.TXT').write_bytes(self.text)
            r = subprocess.run([SH, '-c', '. "$1"; dos_i18n_apply . DOSTEXT.TXT "$2" "$3"; echo "STD=$(dos_text dos.menu.wfw_enhanced)"',
                                'sh', LIB.as_posix(), lang, str(cp)], cwd=d, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return {p: (d / p).read_bytes() for p in FILES}, r.stdout.decode('latin-1')

    def expected(self, name: str, section: str | None) -> bytes:
        data = crlf(FILES[name])
        if section is None:
            return data
        return i18n.render(data, self.sec['en-437'], self.sec[section])

    def check(self, lang: str, cp: int, s437: str | None, snative: str | None):
        files, out = self.apply(lang, cp)
        for name, data in files.items():
            want = self.expected(name, s437 if name in CP437_FILES else snative)
            self.assertEqual(data.replace(b'\r\n', b'\n'), want.replace(b'\r\n', b'\n'), (lang, cp, name))
        return files, out

    def test_polish_profile_852(self):
        files, out = self.check('pl-PL', 852, 'pl-437', 'pl-852')
        self.assertIn(b'menuitem=WINSTD,Windows - tryb standardowy (domyslny)', files['W3CONFIG.SYS'])
        self.assertIn('echo Windows 3.x - tryb standardowy, bez cache dysku.'.encode('cp852'), files['W3AUTO.BAT'])
        self.assertIn('echo Jeśli Windows nie startuje, zrestartuj i wybierz tryb standardowy.'.encode('cp852'), files['W3AUTO.BAT'])
        self.assertIn(b'C:\\DOS\\CHOICE.COM /C:RA /T:R,5 Restart teraz', files['WINMENU.BAT'])
        self.assertIn(b'echo R - restart teraz (automatycznie po 5 sekundach)', files['WINMENU.BAT'])
        self.assertIn(b'C:\\DOS\\CHOICE.COM /C:R /T:R,8 Restart za 8 sekund. Nacisnij R', files['INSTALL.BAT'])
        self.assertIn('STD=tryb rozszerzony 386 (domyslny)', out)

    def test_english_default_and_unknown(self):
        for lang in ('en', 'en-US', 'xx-YY'):
            files, _ = self.check(lang, 437, 'en-437', 'en-437')
            for name in FILES:
                self.assertEqual(files[name].replace(b'\r\n', b'\n'), crlf(FILES[name]).replace(b'\r\n', b'\n'))

    def test_scripts_437_cannot_show(self):
        # Russian: English menus (437), Russian start files in 866.
        files, _ = self.check('ru-RU', 866, None, 'ru-866')
        self.assertIn(b'menuitem=WINSTD,Windows - standard mode (default)', files['W3CONFIG.SYS'])
        self.assertIn('echo Программы DOS находятся в C:\\PROGRAMS.'.encode('cp866'), files['W3AUTO.BAT'])
        # Without the code page switch (manual / no cpi): English everywhere.
        self.check('ru', 437, None, None)
        # Ukrainian: no section at all.
        self.check('uk-UA', 437, None, None)

    def test_tag_shortening_and_western(self):
        self.check('sr-Latn-RS', 852, 'sr-latn-437', 'sr-latn-852')
        self.check('pt-BR', 850, 'pt-br-437', 'pt-br-850')
        files, _ = self.check('de-DE', 850, 'de-437', 'de-850')
        self.assertIn(b'menuitem=DOSONLY,MS-DOS - Eingabeaufforderung', files['W3CONFIG.SYS'])
        # A profile code page of another language: the 437 section.
        self.check('de', 852, 'de-437', None)


if __name__ == '__main__':
    unittest.main()
