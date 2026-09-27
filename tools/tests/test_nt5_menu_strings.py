"""Every English text of the NT5 (XP/2000/2003) micro-Linux menus has a
translation key: usos-fb-ui translates a menu line only when its English
text (or a {0} template of it) is one of the boot.lx.* values of
installer/internal/i18n/locales/en.json. A missing key shows English on a
Polish stick (X470, 2026-09-27: "FORMAT THE ENTIRE DISK?").

Checked: the title=/subtitle=/item= lines the scripts write with printf, and
the title/item arguments of usos_xp_confirm and usos_ui_notice_continue.
"""
from pathlib import Path
import json, re, unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ['tools/xp_disk_reset_ui.sh', 'tools/xp_confirmation_ui.sh', 'tools/legacy_xp_staging.sh', 'tools/xp_disk_menu.sh']


def catalog():
    en = json.loads((ROOT / 'installer/internal/i18n/locales/en.json').read_text(encoding='utf-8'))
    values = [v for k, v in en.items() if k.startswith('boot.')]
    exact = set(values)
    # Only micro-Linux templates with real words: generic UI pairs such as
    # '{0} on {1}' would "match" any English sentence and hide a missing key.
    templates = [re.compile('^' + re.sub(r'\\\{\d\\\}', '.+', re.escape(v)) + '$', re.S)
                 for k, v in en.items() if k.startswith('boot.lx.') and '{' in v and len(re.sub(r'\{\d\}|[^A-Za-z]', '', v)) >= 6]
    return exact, templates


def texts(path: Path):
    """English literals of one script, %s / ${VAR} parts replaced by 'X'."""
    src = path.read_text(encoding='utf-8')
    found = []
    for m in re.finditer(r"printf '(title|subtitle|item)=([^'\\]*)", src):
        for part in m.group(2).split('|'):
            found.append(part)
    for m in re.finditer(r"usos_xp_confirm \"[^\"]*\" ('[^']*'|\"[^\"]*\") ('[^']*'|\"[^\"]*\")", src):
        found += [m.group(1)[1:-1], m.group(2)[1:-1]]
    for m in re.finditer(r"usos_ui_notice_continue ('[^']*'|\"[^\"]*\") ('[^']*'|\"[^\"]*\") ('[^']*'|\"[^\"]*\")", src):
        found += [g[1:-1] for g in m.groups()]
    out = []
    for t in found:
        t = re.sub(r'%s|\$\{[A-Z0-9_]+(:-[^}]*)?\}|\$[A-Z0-9_]+', 'X', t)
        t = t.replace('\\n', '').strip()
        if t and re.search('[A-Za-z]{3}', t):
            out.append(t)
    return out


class Nt5MenuStrings(unittest.TestCase):
    def test_every_menu_text_has_a_key(self):
        exact, templates = catalog()
        missing = []
        for rel in SCRIPTS:
            path = ROOT / rel
            if not path.exists():
                continue
            for t in texts(path):
                if t in exact or any(r.match(t) for r in templates):
                    continue
                missing.append(f'{rel}: {t!r}')
        self.assertEqual(missing, [], 'menu texts without a boot.lx key:\n' + '\n'.join(missing))

    def test_the_format_screen_is_covered(self):
        t = texts(ROOT / 'tools/xp_disk_reset_ui.sh')
        self.assertIn('FORMAT THE ENTIRE DISK?', t)
        self.assertIn('Erase ALL partitions and data on the selected disk', t)


if __name__ == '__main__':
    unittest.main()
