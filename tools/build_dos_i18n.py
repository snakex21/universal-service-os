"""DOS-side texts of the MS-DOS / Windows 1.x-3.x flow in the USOS languages.

Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later

Source of truth: the `dos.*` keys of installer/internal/i18n/locales/*.json
(the 27 USOS catalogs). The DOS start files in src/platform/bios/msdos are
written in English; every English value of a `dos.*` key is a whole text of
one of their lines:

    echo <text>                 (batch messages)
    menuitem=<NAME>,<text>      (CONFIG.SYS start menus; also submenu=)
    ...CHOICE.COM /C:.. [/T:..] <text>   (the CHOICE prompt)

build() writes zig-out/dos-native/i18n/DOSTEXT.TXT: one section per
language and DOS code page, `[<language>-<code page>]`, then pairs of
lines: the key (ASCII), the text in that code page (raw bytes, LF only).
micro-Linux (tools/dos_win3_menu.sh dos_i18n_apply) picks the section of
the profile / USOS menu language at prep time and replaces the English
texts in the start files (render() below is the same rule in Python).

Code pages (the text-mode font of the screen the line is shown on):
  437   every language: the CONFIG.SYS menu (shown before DISPLAY.SYS),
        INSTALL.BAT, WINMENU.BAT, NETSTART.BAT. Letters 437 lacks lose their
        accents (Polish "domyslny"); a language whose script 437 cannot show
        (Cyrillic, Greek) has no 437 section and stays English.
  native  the code page of the language's MS-DOS 6.22 country (852 Central
        European, 850 Western, 866 Russian, 855 Bulgarian, 869 Greek, 857
        Turkish): only for the start-menu batch files (W3AUTO / W1AUTO, WINRUN),
        whose lines run after MODE CON CODEPAGE SELECT, and only when the
        profile's DOS.INI switches to that code page.
Batch-special characters (< > | %) are refused in translations.
"""
from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ROOT / 'installer/internal/i18n/locales'
PREFIX = 'dos.'

# The MS-DOS 6.22 country code page of each catalog language (dos.zig
# countries; Estonian, Latvian, Lithuanian and Ukrainian have none).
NATIVE = {
    'bg': 855, 'cs': 852, 'da': 850, 'de': 850, 'el': 869, 'es': 850, 'fi': 850,
    'fr': 850, 'hr': 852, 'hu': 852, 'it': 850, 'nb': 850, 'nl': 850, 'pl': 852,
    'pt-BR': 850, 'ro': 852, 'ru': 866, 'sk': 852, 'sl': 852, 'sr-Latn': 852,
    'sv': 850, 'tr': 857,
}
# Letters NFKD does not reduce to ASCII.
FOLD = {'ł': 'l', 'Ł': 'L', 'đ': 'd', 'Đ': 'D', 'ß': 'ss', 'ø': 'o', 'Ø': 'O', 'æ': 'ae', 'Æ': 'AE',
        'ı': 'i', 'İ': 'I', '’': "'", '·': ';', '«': '"', '»': '"', '–': '-', '—': '-'}

# Texts the shell script reshapes (dos_menu_names): their fixed parts.
SHAPE = {
    'dos.start.standard': ('Windows 3.x - ', ''), 'dos.start.enhanced': ('Windows 3.x - ', ''),
    'dos.menu.standard': ('Windows - ', ''), 'dos.menu.enhanced': ('Windows - ', ''),
    'dos.menu.mouse_setup': ('', ' - Windows Setup'), 'dos.menu.early_default': ('Windows (', ''),
    'dos.menu.early_standard': ('Windows 3.0 - ', ''),
    'dos.winmenu.restart_now': ('R - ', ''), 'dos.winmenu.stay_dos': ('A - ', ''),
}
MENU_KEYS = ('dos.menu.',)
# 'Windows for Workgroups 3.11 - ' + text must fit the 70 columns of an
# MS-DOS menu item.
WFW_KEYS = ('dos.menu.wfw_enhanced', 'dos.menu.wfw_smartdrv')
# Windows 3.1 / 3.11 with the Winsock profile (dos_winsock_apply): the
# standard-mode item becomes the alternative; 'Windows 3.11 - ' + text.
WINSOCK_KEYS = ('dos.menu.winsock_standard',)
# Keys only the shell script writes (no line of the English sources).
SCRIPT_KEYS = WFW_KEYS + WINSOCK_KEYS
PATH = re.compile(r'[A-Z]:\\[A-Z0-9_\\.*%]*')


def catalogs(locales: Path = LOCALES) -> dict[str, dict[str, str]]:
    out = {}
    for path in sorted(locales.glob('*.json')):
        data = json.loads(path.read_text(encoding='utf-8'))
        out[path.stem] = {k: v for k, v in data.items() if k.startswith(PREFIX)}
    return out


def check(cat: dict[str, dict[str, str]]) -> None:
    english = cat['en']
    if not english:
        raise ValueError('no dos.* keys in en.json')
    for lang, table in cat.items():
        if set(table) != set(english):
            raise ValueError(f'{lang}: dos.* keys differ from English')
        for key, text in table.items():
            where = f'{lang} {key}: {text!r}'
            if any(c in text for c in '<>|%') and text != english[key]:
                raise ValueError(where + ': batch-special character')
            if '\n' in text or '\r' in text or not text.strip():
                raise ValueError(where + ': one non-empty line')
            head, tail = SHAPE.get(key, ('', ''))
            if not (text.startswith(head) and text.endswith(tail)):
                raise ValueError(where + f': must start with {head!r} and end with {tail!r}')
            if key == 'dos.install.choice' and 'R' not in text:
                raise ValueError(where + ': must name the R key')
            if sorted(x.rstrip('.') for x in PATH.findall(text)) != sorted(x.rstrip('.') for x in PATH.findall(english[key])):
                raise ValueError(where + ': paths differ from English')
            if key.startswith(MENU_KEYS) and len(text) > 60:
                raise ValueError(where + ': menu text longer than 60')
            if key in WFW_KEYS and len('Windows for Workgroups 3.11 - ' + text) > 70:
                raise ValueError(where + ': WfW menu text too long')
            if key in WINSOCK_KEYS and len('Windows 3.11 - ' + text) > 70:
                raise ValueError(where + ': Windows 3.11 menu text too long')


def encode(text: str, codepage: int) -> bytes | None:
    """The text in the code page; letters it lacks lose their accents; None
    when a letter has no Latin fallback (another script)."""
    out = bytearray()
    for ch in text:
        try:
            out += ch.encode('cp%d' % codepage)
            continue
        except UnicodeEncodeError:
            pass
        alt = FOLD.get(ch) or ''.join(c for c in unicodedata.normalize('NFKD', ch) if not unicodedata.combining(c))
        if not alt:
            return None
        try:
            out += alt.encode('cp%d' % codepage)
        except UnicodeEncodeError:
            return None
    return bytes(out)


def sections(cat: dict[str, dict[str, str]]) -> dict[str, dict[str, bytes]]:
    keys = sorted(cat['en'])
    out: dict[str, dict[str, bytes]] = {}
    for lang in sorted(cat):
        for cp in [437] + ([NATIVE[lang]] if lang in NATIVE else []):
            table = {}
            for key in keys:
                data = encode(cat[lang][key], cp)
                if data is None:
                    table = None
                    break
                table[key] = data
            if table is not None:
                out[f'{lang.lower()}-{cp}'] = table
    return out


def dostext(cat: dict[str, dict[str, str]]) -> bytes:
    out = bytearray(b'; USOS DOS texts (tools/build_dos_i18n.py from installer/internal/i18n/locales dos.*)\n')
    for name, table in sections(cat).items():
        out += b'[' + name.encode('ascii') + b']\n'
        for key in sorted(table):
            out += key.encode('ascii') + b'\n' + table[key] + b'\n'
    return bytes(out)


LINE = re.compile(rb'^(echo |menuitem=[A-Za-z0-9_]+,|submenu=[A-Za-z0-9_]+,|.*CHOICE\.COM(?: /[^ ]+)* )(.*)$')


def render(data: bytes, english: dict[str, bytes], table: dict[str, bytes]) -> bytes:
    """A start file with the English texts replaced (CRLF kept); the rule of
    dos_i18n_apply in tools/dos_win3_menu.sh."""
    by_text = {v: k for k, v in english.items()}
    out = []
    for line in data.split(b'\n'):
        cr = line.endswith(b'\r')
        body = line[:-1] if cr else line
        m = LINE.match(body)
        if m and m.group(2) in by_text and by_text[m.group(2)] in table:
            body = m.group(1) + table[by_text[m.group(2)]]
        out.append(body + (b'\r' if cr else b''))
    return b'\n'.join(out)


def build(root: Path = ROOT) -> Path:
    cat = catalogs(root / 'installer/internal/i18n/locales')
    check(cat)
    out = root / 'zig-out/dos-native/i18n'
    out.mkdir(parents=True, exist_ok=True)
    target = out / 'DOSTEXT.TXT'
    target.write_bytes(dostext(cat))
    return target


if __name__ == '__main__':
    path = build()
    print(path, path.stat().st_size)
