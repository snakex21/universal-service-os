"""USOS legacy compatibility pack manifest: parser, validator and plan
resolver (host side). Copyright (C) 2026 Maksymilian and the USOS Authors,
GPL-3.0-or-later. Design: docs/design/legacy-compat-pack.md.

The resolver mirrors src/platform/win32_legacy/usosadd/plan.c; the tests
(tools/tests/addons) compare both for every system and language.

  python tools/addons/legacy_manifest.py validate [manifest]
  python tools/addons/legacy_manifest.py plan <os> <lang> [--ntsp 6a] [--no-full] [--options a,b]
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / 'src/addons/legacy-pack.ini'

TIERS = ('full', 'option', 'group', 'none')
REBOOTS = ('now', 'end', 'no')
REDIST = ('yes', 'no', 'conditional', 'unknown')
SOURCES = ('bundled', 'release', 'user')
DECISIONS = ('', 'maintainer-2026-09-30', 'maintainer-2026-10-20')
STATUSES = ('', 'missing', 'needs-iss')
LANGS = ('PL', 'EN', '*')
BUILTINS = ('copy', 'force', 'attrib', 'append', 'cd', 'inf', 'msi')
VARIABLES = ('PKG', 'TMP', 'WIN', 'SYS', 'PF', 'ADD')
NAME83 = re.compile(r'^[A-Z0-9_\-]{1,8}(\.[A-Z0-9_\-]{1,3})?$')


def parse_ini(text: str) -> list[tuple[str, str, str]]:
    """Same rules as ini.c: [section], key=value, ';'/'#' comments, trimmed."""
    entries, section = [], ''
    if text.startswith('﻿'):
        text = text[1:]
    for raw in text.split('\n'):
        line = raw.strip(' \t\r')
        if not line or line[0] in ';#':
            continue
        if line[0] == '[':
            section = line[1:].split(']', 1)[0].strip(' \t\r')
            continue
        if '=' not in line:
            continue
        key, value = line.split('=', 1)
        entries.append((section, key.strip(' \t\r'), value.strip(' \t\r')))
    return entries


def list_items(value: str) -> list[str]:
    return [x.strip(' \t') for x in value.split(',') if x.strip(' \t')]


def ver_parts(s: str) -> list[int]:
    """Same as str.c ver_parts: digits runs and letters (a=1) as components."""
    out, v, have, i = [], 0, False, 0
    while True:
        c = s[i] if i < len(s) else '\0'
        i += 1
        if c.isdigit() and c.isascii():
            v, have = v * 10 + int(c), True
            continue
        if have:
            out.append(v)
        v, have = 0, False
        if c.isascii() and c.isalpha():
            out.append(ord(c.lower()) - ord('a') + 1)
            continue
        if c in '.,':
            continue
        if c == ' ' and not out:
            continue
        break
    return out


def vercmp(a: str, b: str) -> int:
    pa, pb = ver_parts(a), ver_parts(b)
    for i in range(max(len(pa), len(pb))):
        x = pa[i] if i < len(pa) else 0
        y = pb[i] if i < len(pb) else 0
        if x != y:
            return -1 if x < y else 1
    return 0


def cap_split(cap: str) -> tuple[str, str]:
    name, _, ver = cap.partition(':')
    return name, ver


def cap_satisfies(provided: str, needed: str) -> bool:
    pn, pv = cap_split(provided)
    nn, nv = cap_split(needed)
    if pn.lower() != nn.lower():
        return False
    return not nv or vercmp(pv, nv) >= 0


@dataclass
class Package:
    id: str
    keys: dict[str, str]
    position: int

    def get(self, key: str) -> str:
        return self.keys.get(key, '')

    @property
    def tier(self) -> str:
        t = self.get('tier').lower()
        return t if t in TIERS else 'none'

    @property
    def order(self) -> int:
        m = re.match(r'\s*(-?\d+)', self.get('order'))
        return int(m.group(1)) if m else 0

    @property
    def needs(self) -> list[str]:
        return list_items(self.get('needs'))

    @property
    def provides(self) -> list[str]:
        return list_items(self.get('provides'))

    def files(self) -> list[dict]:
        out = []
        for i in range(1, 32):
            v = self.keys.get(f'file{i}')
            if v is None:
                break
            parts = v.split('|')
            parts += [''] * (4 - len(parts))
            out.append({'stage': parts[0], 'original': parts[1], 'sha256': parts[2].lower(),
                        'size': int(parts[3]) if parts[3].isdigit() else None})
        return out

    def runs(self) -> list[str]:
        out = []
        for i in range(1, 64):
            v = self.keys.get(f'run{i}')
            if v is None:
                break
            out.append(v)
        return out


@dataclass
class Manifest:
    entries: list[tuple[str, str, str]]
    packages: list[Package] = field(default_factory=list)
    raw_text: str = ''

    @classmethod
    def load(cls, path: Path = MANIFEST) -> 'Manifest':
        text = path.read_text(encoding='utf-8')
        m = cls(parse_ini(text), raw_text=text)
        seen: dict[str, Package] = {}
        for section, key, value in m.entries:
            if section.lower().startswith('pkg:'):
                pid = section[4:]
                if pid.lower() not in seen:
                    seen[pid.lower()] = Package(pid, {}, len(seen))
                    m.packages.append(seen[pid.lower()])
                seen[pid.lower()].keys.setdefault(key.lower(), value)
        return m

    def get(self, section: str, key: str) -> str | None:
        for s, k, v in self.entries:
            if s.lower() == section.lower() and k.lower() == key.lower():
                return v
        return None

    def find(self, pid: str) -> Package | None:
        for p in self.packages:
            if p.id.lower() == pid.lower():
                return p
        return None

    def os_tokens(self) -> list[str]:
        return list_items(self.get('pack', 'os') or '')

    def os_match(self, value: str, os: str) -> bool:
        for item in list_items(value):
            if item.lower() == os.lower():
                return True
            group = self.get('pack', 'group_' + item)
            if group and os.lower() in (x.lower() for x in list_items(group)):
                return True
        return False

    def os_provides(self, os: str, ntsp: str, cap: str) -> bool:
        provided = list_items(self.get('os:' + os, 'provides') or '')
        if any(cap_satisfies(p, cap) for p in provided):
            return True
        return bool(ntsp) and cap_satisfies('ntsp:' + ntsp, cap)


def ntsp_ok(cond: str, detected: str, eff: str) -> bool:
    """'<6a' is judged by the detected level (a service pack to install),
    '6a+' by the effective one (raised by a service pack in the plan)."""
    if not cond:
        return True
    if not detected:
        return False
    if cond.startswith('<'):
        return vercmp(detected, cond[1:]) < 0
    return vercmp(eff or detected, cond.rstrip('+')) >= 0


def applicable(m: Manifest, p: Package, os: str, lang: str, detected: str, eff: str = '') -> bool:
    if not m.os_match(p.get('os'), os):
        return False
    if not (p.get('lang') == '*' or p.get('lang').lower() == lang.lower()):
        return False
    return ntsp_ok(p.get('ntsp'), detected, eff)


@dataclass
class Plan:
    order: list[str]
    why: dict[str, str]
    unmet: dict[str, str]
    eff_ntsp: str


def selection(m: Manifest, select: dict[str, str] | None = None) -> tuple[str, bool, list[str], list[str]]:
    """Same as plan.c ua_selection: (preset, full, options, exclude)."""
    select = select or {}
    preset = select.get('preset') or m.get('presets', 'default') or ''
    full = (m.get('preset:' + preset, 'full') or '0').strip() == '1'
    options: list[str] = []
    for o in list_items(m.get('preset:' + preset, 'options') or '') + list_items(select.get('options', '')):
        if o.lower() not in (x.lower() for x in options):
            options.append(o)
    if select.get('full', '') != '':
        full = select['full'].strip() == '1'
    exclude: list[str] = []
    for o in list_items(select.get('exclude', '')):
        if o.lower() not in (x.lower() for x in exclude):
            exclude.append(o)
    return preset, full, options, exclude


def resolve(m: Manifest, os: str, lang: str, ntsp: str = '', full: bool = True, options: list[str] | None = None,
            exclude: list[str] | None = None) -> Plan:
    options = [o.lower() for o in (options or [])]
    exclude_l = [o.lower() for o in (exclude or [])]
    pk = m.packages

    def select(eff: str):
        inn, why = [False] * len(pk), {}
        for i, p in enumerate(pk):
            if p.id.lower() in exclude_l:
                continue
            wanted = 'full' if full and p.tier in ('full', 'group') else ''
            if not wanted and p.id.lower() in options:
                wanted = 'option'
            if not wanted:
                continue
            if not applicable(m, p, os, lang, ntsp, eff):
                why[p.id] = 'out-system'
                continue
            if p.get('status'):
                why[p.id] = 'out-status'
                continue
            inn[i], why[p.id] = True, wanted
        changed = True
        while changed:
            changed = False
            for i, p in enumerate(pk):
                if not inn[i]:
                    continue
                for need in p.needs:
                    if m.os_provides(os, ntsp, need):
                        continue
                    if any(inn[j] and any(cap_satisfies(c, need) for c in q.provides) for j, q in enumerate(pk)):
                        continue
                    best = None
                    for j, q in enumerate(pk):
                        if inn[j] or q.get('status') or q.id.lower() in exclude_l or not applicable(m, q, os, lang, ntsp, eff):
                            continue
                        if not any(cap_satisfies(c, need) for c in q.provides):
                            continue
                        if best is None or q.order < pk[best].order:
                            best = j
                    if best is not None:
                        inn[best], why[pk[best].id], changed = True, 'needed', True
        return inn, why

    eff = ntsp
    for _ in range(2):
        inn, why = select(eff)
        if not ntsp:
            break
        best = ''
        for i, p in enumerate(pk):
            if not inn[i]:
                continue
            for c in p.provides:
                if c.lower().startswith('ntsp:') and vercmp(c[5:], eff) > 0 and (not best or vercmp(c[5:], best) > 0):
                    best = c[5:]
        if not best:
            break
        eff = best
    chosen = sorted((i for i in range(len(pk)) if inn[i]), key=lambda i: (pk[i].order, i))
    kept, unmet = [], {}
    for i in chosen:
        p, ok = pk[i], True
        for need in p.needs:
            if m.os_provides(os, ntsp, need):
                continue
            if any(pk[j].order < p.order and any(cap_satisfies(c, need) for c in pk[j].provides) for j in kept):
                continue
            ok, unmet[p.id] = False, need
            break
        if ok:
            kept.append(i)
        else:
            why[p.id] = 'out-needs'
    return Plan([pk[i].id for i in kept], why, unmet, eff)


def validate(m: Manifest) -> list[str]:
    """Structural checks; returns a list of problems (empty = valid)."""
    errors: list[str] = []
    if re.search(r'https?://', m.raw_text, re.I) or any(re.search(r'https?://', value, re.I) for _, _, value in m.entries):
        errors.append('public manifest must not contain HTTP(S) download addresses')
    tokens = set(t.lower() for t in m.os_tokens())
    groups = {k[6:].lower() for s, k, _ in m.entries if s.lower() == 'pack' and k.lower().startswith('group_')}
    if m.get('pack', 'format') != '1':
        errors.append('[pack] format must be 1')
    for t in tokens:
        if m.get('os:' + t, 'name') is None:
            errors.append(f'[os:{t}] missing')
    dirs: dict[str, str] = {}
    all_caps = {c for p in m.packages for c in (cap_split(x)[0].lower() for x in p.provides)}
    os_caps = {cap_split(x)[0].lower() for t in tokens for x in list_items(m.get('os:' + t, 'provides') or '')}
    for p in m.packages:
        where = f'[pkg:{p.id}]'
        if not re.fullmatch(r'[a-z0-9][a-z0-9.\-]*', p.id):
            errors.append(f'{where}: id must be lower-case a-z0-9.-')
        for key in ('name_pl', 'name_en', 'os', 'lang', 'tier', 'order'):
            if not p.get(key):
                errors.append(f'{where}: {key}= missing')
        if p.get('tier').lower() not in TIERS:
            errors.append(f'{where}: tier {p.get("tier")!r}')
        if p.get('lang') not in LANGS:
            errors.append(f'{where}: lang {p.get("lang")!r}')
        for item in list_items(p.get('os')):
            if item.lower() not in tokens and item.lower() not in groups:
                errors.append(f'{where}: unknown os {item}')
        if p.get('ntsp') and not re.fullmatch(r'<?\d+a?\+?', p.get('ntsp')):
            errors.append(f'{where}: ntsp {p.get("ntsp")!r}')
        if p.get('status') not in STATUSES:
            errors.append(f'{where}: status {p.get("status")!r}')
        for cap in p.needs + p.provides:
            # a version is numbers (and one trailing letter): "hf98:q123" would
            # compare as a version and match unrelated capabilities
            if not re.fullmatch(r'[a-z0-9][a-z0-9\-]*(:\d+(\.\d+)*[a-z]?)?', cap):
                errors.append(f'{where}: capability {cap!r} is not name[:version]')
        for need in p.needs:
            name = cap_split(need)[0].lower()
            if name != 'ntsp' and name not in all_caps and name not in os_caps:
                errors.append(f'{where}: nobody provides {need}')
        if p.tier == 'group':
            if p.files() or p.runs():
                errors.append(f'{where}: a group has no files or commands')
            continue
        if p.get('reboot') not in REBOOTS:
            errors.append(f'{where}: reboot {p.get("reboot")!r}')
        # USOSADD /setup (Windows 95 build 950 coordinator) overrides only
        if p.get('reboot_setup') and p.get('reboot_setup') not in REBOOTS:
            errors.append(f'{where}: reboot_setup {p.get("reboot_setup")!r}')
        if (p.get('reboot_setup') or p.get('check_setup')) and                 not set(i.lower() for i in list_items(p.get('os'))) <= {'95', '95rtm', '95osr1'}:
            errors.append(f'{where}: reboot_setup/check_setup only for Windows 95 packages')
        if p.get('source') not in SOURCES:
            errors.append(f'{where}: source {p.get("source")!r}')
        if p.get('redist') not in REDIST:
            errors.append(f'{where}: redist {p.get("redist")!r}')
        if not p.get('license'):
            errors.append(f'{where}: license= missing')
        d = p.get('dir')
        if not NAME83.fullmatch(d or '') or '.' in d:
            errors.append(f'{where}: dir {d!r} is not an 8-character name')
        elif d.upper() in dirs:
            errors.append(f'{where}: dir {d} also used by {dirs[d.upper()]}')
        else:
            dirs[d.upper()] = p.id
        files = p.files()
        if not files:
            errors.append(f'{where}: no file1=')
        for f in files:
            if not NAME83.fullmatch(f['stage']):
                errors.append(f'{where}: staged name {f["stage"]!r} is not 8.3 upper case')
            if p.get('status') == 'missing':
                continue
            if not re.fullmatch(r'[0-9a-f]{64}', f['sha256']):
                errors.append(f'{where}: sha256 of {f["stage"]} missing or malformed')
            if not f['size']:
                errors.append(f'{where}: size of {f["stage"]} missing')
        if p.get('unpack') not in ('', 'zip', 'iso'):
            errors.append(f'{where}: unpack {p.get("unpack")!r}')
        runs = p.runs()
        if not runs:
            errors.append(f'{where}: no run1=')
        for r in runs:
            for var in re.findall(r'%([A-Za-z]+)%', r):
                if var.upper() not in VARIABLES:
                    errors.append(f'{where}: unknown variable %{var}% in {r!r}')
            verb = r.split(' ', 1)[0].lower()
            if verb in BUILTINS and verb in ('copy', 'force') and len(re.findall(r'"[^"]*"|\S+', r)) != 3:
                errors.append(f'{where}: {verb} needs <src> <dst>: {r!r}')
        for chk in (p.get('check'), p.get('check_setup')):
          if chk and not re.match(r'^(file:.+|ntsp:\d+a?|reg:HK(LM|CU)\\.+|regver:HK(LM|CU)\\.+,.+>=.+|regdw:HK(LM|CU)\\.+,.+>=\d+)$', chk):
            errors.append(f'{where}: check {chk!r}')
        if p.get('bridge') and p.get('bridge') != 'yes':
            errors.append(f'{where}: bridge must be yes')
        if p.get('bridge') == 'yes' and 'do zastąpienia własną implementacją' not in p.get('note'):
            errors.append(f'{where}: a bridge must say "do zastąpienia własną implementacją" in note=')
        if p.get('source') == 'bundled' and p.get('redist') != 'yes':
            errors.append(f'{where}: bundled but redist={p.get("redist")}')
        if p.get('decision') not in DECISIONS:
            errors.append(f'{where}: decision {p.get("decision")!r}')
        if p.get('source') == 'release' and p.get('redist') != 'yes' and not p.get('decision'):
            errors.append(f'{where}: source=release needs redist=yes or a decision=')
    # needs must be provided by an earlier order (per package, statically)
    answer_keys = [(s_, k, v) for s_, k, v in m.entries if re.fullmatch(r'answer\d+', k.lower())]
    for s_, k, v in answer_keys:
        title, _, action = v.partition('|')
        if not title or not (action.isdigit() or action == 'source'):
            errors.append(f'[{s_}] {k}: want "title|button id" or "title|source", got {v!r}')
    presets = list_items(m.get('presets', 'order') or '')
    if not presets or (m.get('presets', 'default') or '') not in presets:
        errors.append('[presets] order= and a default= from it are required')
    for pr in presets:
        if m.get('preset:' + pr, 'name_pl') is None or m.get('preset:' + pr, 'full') not in ('0', '1'):
            errors.append(f'[preset:{pr}] needs name_pl= and full=0|1')
        for o in list_items(m.get('preset:' + pr, 'options') or ''):
            if not m.find(o):
                errors.append(f'[preset:{pr}] unknown package {o}')
    for p in m.packages:
        for need in p.needs:
            name = cap_split(need)[0].lower()
            providers = [q for q in m.packages if any(cap_satisfies(c, need) for c in q.provides)]
            if providers and all(q.order >= p.order for q in providers) and name not in os_caps:
                errors.append(f'[pkg:{p.id}]: every provider of {need} runs later')
    return errors


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    v = sub.add_parser('validate')
    v.add_argument('manifest', nargs='?', type=Path, default=MANIFEST)
    pl = sub.add_parser('plan')
    pl.add_argument('os')
    pl.add_argument('lang')
    pl.add_argument('--ntsp', default='')
    pl.add_argument('--no-full', action='store_true')
    pl.add_argument('--options', default='')
    pl.add_argument('--exclude', default='')
    pl.add_argument('--preset', default='')
    pl.add_argument('--manifest', type=Path, default=MANIFEST)
    a = ap.parse_args(argv)
    if a.cmd == 'validate':
        errors = validate(Manifest.load(a.manifest))
        for e in errors:
            print('[FAIL]', e)
        if not errors:
            print(f'[PASS] {a.manifest.name}: {len(Manifest.load(a.manifest).packages)} packages')
        return 1 if errors else 0
    m = Manifest.load(a.manifest)
    if a.preset:
        _, full, options, exclude = selection(m, {'preset': a.preset, 'options': a.options, 'exclude': a.exclude})
    else:
        full, options, exclude = not a.no_full, list_items(a.options), list_items(a.exclude)
    plan = resolve(m, a.os, a.lang, a.ntsp, full, options, exclude)
    for pid in plan.order:
        p = m.find(pid)
        print(f'{p.order:>4} {pid:<24} {plan.why.get(pid, ""):<7} {p.get("name_en")}')
    for pid, why in plan.why.items():
        if why.startswith('out'):
            print(f'     {pid:<24} {why} {plan.unmet.get(pid, "")}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
