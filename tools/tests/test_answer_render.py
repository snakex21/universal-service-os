"""Golden tests of the answer renderers (src/flow/answer, docs/answer-profiles.md).

    python tools/tests/test_answer_render.py          (USOS_UPDATE_GOLDEN=1 rewrites the goldens)

Builds zig-out/bin/usos-answer (zig build answer-tool) and checks:
  - autounattend.xml per Windows version and architecture: golden bytes,
    well-formed (Python's XML parser), every component of the chosen
    architecture, no DiskConfiguration / InstallTo / WillWipeDisk;
  - NT5: the rendered settings merged by tools/xp_user_settings.sh
    (profile mode) into the automatic WINNT.SIF for XP, 2000 and 2003
    (golden bytes) and the accounts script;
  - usos-xp.ini keeps working: DATA's usos-xp.ini through the old path and
    the same file imported into a profile and rendered give byte-identical
    WINNT.SIF and accounts script;
  - Linux answer files (autoinstall.yaml, preseed.cfg, ks.cfg): golden
    bytes, structure, no disk settings, no plain password, the $6$ hash
    checked against an independent Python sha512-crypt (and passlib if
    installed);
  - the architecture-mismatch check (amd64-only file with x86 media), also
    on the user's Schneegans file when it is present in zig-out/usb.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'src' / 'flow' / 'answer' / 'testdata'
GOLDEN = DATA / 'golden'
OUT = ROOT / 'zig-out' / 'answer-render-tests'
TOOL = ROOT / 'zig-out' / 'bin' / 'usos-answer.exe'
ZIG = ROOT / 'tools' / 'zig' / 'zig.exe'
SH = next((p for p in (r'C:\msys64\usr\bin\sh.exe', r'C:\Program Files\Git\usr\bin\sh.exe', shutil.which('sh') or '') if p and Path(p).exists()), None)
# The shell's own coreutils (head, od, awk) first: PowerShell runs lack them on PATH.
if SH:
    # cmp (tools/answer_plan.sh) may only be in Git's usr/bin: second.
    os.environ['PATH'] = os.pathsep.join([str(Path(SH).parent), r'C:\Program Files\Git\usr\bin', os.environ.get('PATH', '')])
UPDATE = os.environ.get('USOS_UPDATE_GOLDEN') == '1'
NS = '{urn:schemas-microsoft-com:unattend}'
failures: list[str] = []

NT6 = [
    ('windows-vista', 'x86'), ('windows-vista', 'amd64'),
    ('windows-7', 'x86'), ('windows-7', 'amd64'),
    ('windows-8', 'amd64'), ('windows-8-1', 'x86'), ('windows-8-1', 'amd64'),
    ('windows-10', 'x86'), ('windows-10', 'amd64'), ('windows-10', 'arm64'),
    ('windows-11', 'amd64'), ('windows-11', 'arm64'),
    ('windows-server-2008', 'amd64'), ('windows-server-2008-r2', 'amd64'),
    ('windows-server-2012', 'amd64'), ('windows-server-2012-r2', 'amd64'),
    ('windows-server-2016', 'amd64'), ('windows-server-2019', 'amd64'),
    ('windows-server-2022', 'amd64'), ('windows-server-2025', 'amd64'),
]
MINIMAL = [('windows-7', 'x86'), ('windows-10', 'amd64'), ('windows-11', 'amd64')]
NT5 = [('windows-xp', 'tools/xp_selected_partition_uefi_csm.sif', '00000415'),
       ('windows-2000', 'tools/xp_selected_partition.sif', '00000415'),
       ('windows-server-2003', 'tools/xp_selected_partition.sif', '00000409')]


def check(name: str, condition: bool, detail: str = '') -> None:
    print(('PASS ' if condition else 'FAIL ') + name + ('' if condition else ' ' + detail))
    if not condition:
        failures.append(name)


def posix(path: Path) -> str:
    s = str(path.resolve()).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if s[1:2] == ':' else s


def sh(command: str) -> subprocess.CompletedProcess:
    lib = posix(ROOT / 'tools' / 'xp_user_settings.sh')
    return subprocess.run([SH, '-c', f". '{lib}'; {command}"], capture_output=True)


def tool(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(TOOL), *args], capture_output=True, cwd=ROOT)


def golden(name: str, data: bytes) -> None:
    path = GOLDEN / name
    if UPDATE:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print('UPDATED ' + name)
        return
    expected = path.read_bytes() if path.exists() else None
    check('golden ' + name, expected == data, 'missing golden' if expected is None else 'differs (USOS_UPDATE_GOLDEN=1 to accept)')


def check_xml(name: str, data: bytes, arch: str) -> None:
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        check(name + ' well-formed', False, str(error))
        return
    check(name + ' well-formed', root.tag == NS + 'unattend')
    components = root.findall(f'{NS}settings/{NS}component')
    archs = {c.get('processorArchitecture') for c in components}
    check(name + ' one architecture', archs == {arch}, str(archs))
    text = data.decode()
    check(name + ' manual disk', all(k not in text for k in ('DiskConfiguration', 'InstallTo', 'WillWipeDisk')))
    check(name + ' no edition without media', name.startswith('edition.') or 'ImageInstall' not in text)
    check(name + ' zig check-xml', tool('check-xml', str(OUT / name), arch).returncode == 0)
    other = 'x86' if arch != 'x86' else 'amd64'
    check(name + ' zig mismatch warning', tool('check-xml', str(OUT / name), other).returncode == 3)


def nt5_merge(settings: Path, base: str, name: str, profile_mode: bool) -> tuple[bytes, bytes]:
    normalized = OUT / (name + '.normalized')
    layout = '00000415'
    r = sh(f"usos_xp_settings_load '{posix(settings)}' '{posix(normalized)}' {layout}{' profile' if profile_mode else ''}")
    check(name + ' load', r.returncode == 0, r.stderr.decode(errors='replace'))
    sif = sh(f"usos_xp_settings_sif '{posix(ROOT / base)}' '{posix(normalized)}'").stdout
    accounts = OUT / (name + '.accounts.cmd')
    sh(f"usos_xp_settings_accounts '{posix(normalized)}' '{posix(accounts)}'")
    return sif, accounts.read_bytes()


CRYPT64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'


def sha512_crypt(key: bytes, salt: bytes, rounds: int | None = None) -> str:
    """Independent reimplementation of glibc $6$ crypt (Drepper's spec) to
    check the Zig one (no crypt module on Windows / Python 3.13)."""
    import hashlib
    salt = salt[:16]
    n = 5000 if rounds is None else min(max(rounds, 1000), 999999999)

    def rep(block: bytes, length: int) -> bytes:
        return (block * (length // len(block) + 1))[:length]

    b = hashlib.sha512(key + salt + key).digest()
    h = hashlib.sha512(key + salt + rep(b, len(key)))
    bits = len(key)
    while bits:
        h.update(b if bits & 1 else key)
        bits >>= 1
    c = h.digest()
    p = rep(hashlib.sha512(key * len(key)).digest(), len(key))
    s = rep(hashlib.sha512(salt * (16 + c[0])).digest(), len(salt))
    for i in range(n):
        h = hashlib.sha512()
        h.update(p if i & 1 else c)
        if i % 3:
            h.update(s)
        if i % 7:
            h.update(p)
        h.update(c if i & 1 else p)
        c = h.digest()
    out = []
    for i in range(21):
        t = (i * 22) % 63, (i * 22 + 21) % 63, (i * 22 + 42) % 63
        # glibc order: (0,21,42) (22,43,1) (44,2,23) ...
        w = (c[t[0]] << 16) | (c[t[1]] << 8) | c[t[2]]
        out.extend(CRYPT64[(w >> (6 * k)) & 63] for k in range(4))
    w = c[63]
    out.extend(CRYPT64[(w >> (6 * k)) & 63] for k in range(2))
    prefix = '$6$' + (f'rounds={n}$' if rounds is not None else '')
    return prefix + salt.decode() + '$' + ''.join(out)


LINUX_SALT = 'usosgoldensalt00'
LINUX_VECTORS = (('full', 'full.profile.ini', 'Test123!'), ('nopassword', 'linux-nopassword.profile.ini', ''))


def check_linux() -> None:
    """Linux answer files (src/flow/answer/linux.zig): goldens, no disk
    settings, no plain password, the $6$ hash verified independently."""
    reference = '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1'
    check('linux: python sha512-crypt matches the reference vector', sha512_crypt(b'Hello world!', b'saltstring') == reference)
    check('linux: python sha512-crypt rounds vector', sha512_crypt(b'Hello world!', b'saltstringsaltstring', 10000) ==
          '$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.')
    try:
        from passlib.hash import sha512_crypt as passlib_sha512  # optional
    except ImportError:
        passlib_sha512 = None
        print('SKIP linux: passlib not installed (python reimplementation used)')
    for vector, profile_file, password in LINUX_VECTORS:
        for fmt in ('autoinstall', 'preseed', 'kickstart'):
            name = f'linux/{fmt}.{vector}.txt'
            out = OUT / f'linux.{fmt}.{vector}.txt'
            r = tool('render-linux', str(DATA / profile_file), fmt, LINUX_SALT, str(out))
            check('render ' + name, r.returncode == 0, r.stderr.decode(errors='replace'))
            if r.returncode != 0:
                continue
            data = out.read_bytes()
            golden(name, data)
            text = data.decode()
            notes = r.stderr.decode()
            check(name + ' LF only, ASCII', b'\r' not in data and data.isascii())
            if password:
                check(name + ' no plain password', password not in text)
                hashes = [w.strip('"').split('=', 1)[-1] for w in text.split() if '$6$' in w]
                check(name + ' one $6$ hash', len(hashes) == 1, str(hashes))
                if hashes:
                    check(name + ' hash verifies', hashes[0] == sha512_crypt(password.encode(), LINUX_SALT.encode()))
                    if passlib_sha512:
                        check(name + ' hash verifies (passlib)', passlib_sha512.verify(password, hashes[0]))
                check(name + ' identity answered', 'identity: interactive' not in notes and 'password_empty' not in notes)
            else:
                check(name + ' no hash without a password', '$6$' not in text)
                check(name + ' identity interactive, noted', 'identity: interactive' in notes and 'note: password_empty' in notes)
            check(name + ' disk noted', 'note: disk_interactive' in notes)
            lines = [line for line in text.splitlines() if line and not line.startswith('#')]
            if fmt == 'autoinstall':
                # No yaml module in the standard library: structural checks.
                check(name + ' yaml shape', lines[0] == 'autoinstall:' and lines[1] == '  version: 1' and all(
                    line.startswith('  ') and '\t' not in line for line in lines[1:]))
                sections = []
                for line in lines[lines.index('  interactive-sections:') + 1:]:
                    if not line.startswith('    - '):
                        break
                    sections.append(line[6:])
                check(name + ' storage interactive', 'storage' in sections, str(sections))
                check(name + ' identity section rule', ('identity' in sections) == (not password), str(sections))
                check(name + ' no storage config', not any(line.startswith('  storage:') for line in lines))
                check(name + ' quoted scalars', all(line.split(': ', 1)[1][0] == '"' for line in lines
                                                   if ': ' in line and line.split(': ', 1)[1] not in ('1', 'false')))
                check(name + ' no ssh server, no refresh', '  ssh:\n    install-server: false' in text and '  refresh-installer:\n    update: false' in text)
            elif fmt == 'preseed':
                check(name + ' only d-i lines', all(line.startswith('d-i ') for line in lines))
                check(name + ' try-usb', 'd-i cdrom-detect/try-usb boolean true' in lines)
                check(name + ' no partman/grub/bootdev', not any(k in text for k in ('partman', 'grub-installer', 'bootdev')))
                check(name + ' no root login', 'd-i passwd/root-login boolean false' in lines)
            else:
                storage = ('ignoredisk', 'clearpart', 'autopart', 'part', 'partition', 'zerombr', 'bootloader', 'reqpart', 'raid', 'volgroup', 'logvol')
                check(name + ' no storage commands', not any(line.split()[0] in storage for line in lines))
                check(name + ' no %packages', '%packages' not in text)
                check(name + ' root locked', 'rootpw --lock' in lines)
                check(name + ' user line only with a password', any(line.startswith('user ') for line in lines) == bool(password))
    full = (GOLDEN / 'linux' / 'autoinstall.full.txt').read_text()
    check('linux: pl-PL locale, pl keyboard, Warsaw', 'locale: "pl_PL.UTF-8"' in full and 'layout: "pl"' in full and 'timezone: "Europe/Warsaw"' in full)
    ks = (GOLDEN / 'linux' / 'kickstart.nopassword.txt').read_text()
    check('linux: xkb variant in kickstart', "keyboard --xlayouts='us (intl)'" in ks)


# Where each tweak may appear (docs/answer-profiles.md "Tweaks"; an
# independent copy of src/flow/answer/schema.zig tweak_support). Every other
# system must render byte for byte what it renders without the tweak.
NT6_ALL = {s for s, _ in NT6}
NT5_BASE = {system: base for system, base, _ in NT5}
TWEAKS = {
    'skip_games=yes': {'windows-xp', 'windows-vista', 'windows-7'},
    'skip_msn=yes': {'windows-xp', 'windows-server-2003'},
    'hide_outlook_express=yes': {'windows-xp', 'windows-server-2003'},
    'classic_start=yes': {'windows-xp'},
    'theme=classic': {'windows-xp', 'windows-7'},
    'theme=basic': {'windows-7'},
    'no_balloon_tips=yes': {'windows-xp', 'windows-server-2003'},
    'display=1280x1024': {'windows-xp', 'windows-server-2003'},
    'disable_uac=yes': {'windows-vista', 'windows-7', 'windows-server-2008', 'windows-server-2008-r2'},
    'no_sidebar=yes': {'windows-vista', 'windows-7'},
    'no_welcome_center=yes': {'windows-vista'},
    'no_hibernation=yes': {'windows-vista', 'windows-7'},
    'show_extensions=yes': {'windows-xp', 'windows-server-2003'} | NT6_ALL,
    'show_hidden=yes': {'windows-xp', 'windows-server-2003'} | NT6_ALL,
    'no_autorun=yes': {'windows-xp', 'windows-server-2003'} | NT6_ALL,
}
# Text each tweak must bring where it applies (one marker per tweak).
MARKERS = {
    'skip_games=yes': ('minesweeper=Off', 'InboxGames'),
    'skip_msn=yes': ('msmsgs=Off',),
    'hide_outlook_express=yes': ('OEAccess=Off',),
    'classic_start=yes': ('DefaultStartPanelOff=Yes',),
    'theme=classic': ('DefaultThemesOff=Yes', 'classic.theme'),
    'theme=basic': ('basic.theme',),
    'no_balloon_tips=yes': ('EnableBalloonTips',),
    'display=1280x1024': ('Xresolution=1280',),
    'disable_uac=yes': ('<EnableLUA>false</EnableLUA>', '/v EnableLUA /t REG_DWORD /d 0'),
    'no_sidebar=yes': ('TurnOffSidebar',),
    'no_welcome_center=yes': ('WindowsWelcomeCenter',),
    'no_hibernation=yes': ('powercfg.exe -h off',),
    'show_extensions=yes': ('HideFileExt',),
    'show_hidden=yes': ('/v Hidden ',),
    'no_autorun=yes': ('NoDriveTypeAutoRun',),
}


def render_any(profile: Path, system: str, arch: str, name: str) -> bytes | None:
    """autounattend.xml, or for NT5 the merged WINNT.SIF + accounts script."""
    out = OUT / name
    r = tool('render', str(profile), system, arch, str(out))
    check('render ' + name, r.returncode == 0, r.stderr.decode(errors='replace'))
    if r.returncode != 0:
        return None
    if system in NT5_BASE:
        sif, accounts = nt5_merge(out, NT5_BASE[system], name, True)
        return sif + b'\n----- usos-users.cmd -----\n' + accounts
    data = out.read_bytes()
    check_xml(name, data, arch)
    return data


def check_tweaks() -> None:
    import difflib
    base_text = (DATA / 'minimal.profile.ini').read_text()
    first: dict[str, str] = {}
    for s, a in NT6:
        first.setdefault(s, a)
    systems = list(first.items()) + [('windows-xp', 'x86'), ('windows-2000', 'x86'), ('windows-server-2003', 'x86')]
    baseline = {s: render_any(DATA / 'minimal.profile.ini', s, a, f'tw-base.{s}') for s, a in systems}
    matrix = []
    for tweak, where in TWEAKS.items():
        profile = OUT / ('tw-' + tweak.replace('=', '-') + '.profile.ini')
        profile.write_text(base_text + tweak + '\n')
        for system, arch in systems:
            data = render_any(profile, system, arch, f'tw-{tweak.replace("=", "-")}.{system}')
            if data is None or baseline[system] is None:
                continue
            added = [line for line in difflib.unified_diff(baseline[system].decode().splitlines(), data.decode().splitlines(), lineterm='', n=0)
                     if line[:1] in '+-' and not line.startswith(('+++', '---'))]
            if system in where:
                check(f'tweak {tweak} renders on {system}', bool(added) and any(m in data.decode() for m in MARKERS[tweak]), '\n'.join(added))
            else:
                check(f'tweak {tweak} leaves {system} unchanged', data == baseline[system], '\n'.join(added))
            for line in added:
                matrix.append(f'{tweak}\t{system}\t{line}')
    golden('tweaks.matrix.txt', ('\n'.join(matrix) + '\n').encode())
    # Every tweak on: one golden per system; nothing a version lacks.
    for system, arch in systems:
        data = render_any(DATA / 'tweaks.profile.ini', system, arch, f'tweaks.{system}.{arch}')
        if data is None:
            continue
        golden(f'tweaks.{system}.{arch}.{"sif-cmd.txt" if system in NT5_BASE else "xml"}', data)
        text = data.decode()
        for tweak, where in TWEAKS.items():
            if tweak == 'theme=basic' or tweak.startswith('display='):
                continue
            present = any(m in text for m in MARKERS[tweak])
            check(f'all tweaks: {tweak} {"on" if system in where else "absent"} on {system}', present == (system in where))
    # Windows 7 basic theme; the Vista XML carries the Vista commands.
    basic = OUT / 'tw-basic.profile.ini'
    basic.write_text(base_text + 'theme=basic\n')
    data = render_any(basic, 'windows-7', 'x86', 'tweaks-basic.windows-7.x86.xml')
    if data is not None:
        golden('tweaks-basic.windows-7.x86.xml', data)
    vista = (OUT / 'tweaks.windows-vista.x86').read_text()
    check('Vista games through pkgmgr, 7 through DISM', 'pkgmgr.exe /uu:InboxGames' in vista and 'dism.exe' not in vista
          and 'dism.exe /Online /NoRestart /Disable-Feature /FeatureName:InboxGames' in (OUT / 'tweaks.windows-7.x86').read_text())
    check('specialize commands are at most 259 characters', all(len(p.text or '') <= 259 for f in OUT.glob('tweaks.windows-*') if f.suffix == '' and f.read_bytes().startswith(b'<?xml')
                                                               for p in ET.fromstring(f.read_bytes()).iter(NS + 'Path')))
    xp = (OUT / 'tweaks.windows-xp.x86').read_text()
    check('XP tweaks in the normalized settings only when set', 'tweaks=games,msn_explorer,messenger,outlook_express,classic_start,classic_theme,balloons,tour,extensions,hidden,autorun' in xp and 'display=1024x768' in xp)
    bad = OUT / 'bad-tweak.ini'
    bad.write_bytes(b'user=Bob\ntweaks=games\n')
    check('usos-xp.ini refuses the tweak keys', sh(f"usos_xp_settings_load '{posix(bad)}' '{posix(OUT / 'bad.out')}' 00000415").returncode == 1)
    bad.write_bytes(b'user=Bob\nfamily=xp\ntweaks=games,rm_rf\n')
    check('profile mode refuses an unknown tweak', sh(f"usos_xp_settings_load '{posix(bad)}' '{posix(OUT / 'bad.out')}' 00000415 profile").returncode == 1)
    bad.write_bytes(b'user=Bob\nfamily=xp\ndisplay=640x480\n')
    check('profile mode refuses an unknown display mode', sh(f"usos_xp_settings_load '{posix(bad)}' '{posix(OUT / 'bad.out')}' 00000415 profile").returncode == 1)


def main() -> int:
    if SH is None:
        print('sh not found')
        return 1
    build = subprocess.run([str(ZIG), 'build', '--cache-dir', str(ROOT / 'tools' / 'cache' / 'zig'), 'answer-tool'], cwd=ROOT)
    if build.returncode != 0:
        print('FAIL zig build answer-tool')
        return 1
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)

    for vector, systems in (('full', NT6), ('minimal', MINIMAL)):
        for system, arch in systems:
            name = f'{vector}.{system}.{arch}.xml'
            r = tool('render', str(DATA / f'{vector}.profile.ini'), system, arch, str(OUT / name))
            check('render ' + name, r.returncode == 0, r.stderr.decode(errors='replace'))
            if r.returncode != 0:
                continue
            data = (OUT / name).read_bytes()
            golden(name, data)
            check_xml(name, data, arch)
    # Content rules on the full vector.
    ten = (OUT / 'full.windows-10.amd64.xml').read_text()
    eleven = (OUT / 'full.windows-11.amd64.xml').read_text()
    seven = (OUT / 'full.windows-7.x86.xml').read_text()
    server = (OUT / 'full.windows-server-2022.amd64.xml').read_text()
    check('11 has the chosen bypasses', all(k in eleven for k in ('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassNRO')))
    check('10 has no bypass', 'LabConfig' not in ten and 'BypassNRO' not in ten)
    check('10 local account, online screens hidden', '<HideOnlineAccountScreens>true' in ten and '<Name>Tester</Name>' in ten and '<Name>Drugi</Name>' in ten)
    check('7 no online screens, legacy network page', 'HideOnlineAccountScreens' not in seven and '<NetworkLocation>Work' in seven)
    vista = (OUT / 'full.windows-vista.x86.xml').read_text()
    r2 = (OUT / 'full.windows-server-2008-r2.amd64.xml').read_text()
    check('7 has only the Windows 7 OOBE settings', 'HideOEMRegistrationScreen' not in seven and '<HideWirelessSetupInOOBE>true' in seven and '<ShowWindowsLive>false' in seven)
    check('Vista has only the Vista OOBE settings', all(k not in vista for k in ('HideOEMRegistrationScreen', 'HideWirelessSetupInOOBE', 'ShowWindowsLive')) and '<NetworkLocation>Work' in vista)
    check('2008 R2 without the client-only Windows Live link', 'ShowWindowsLive' not in r2 and '<AdministratorPassword>' in r2)
    check('OOBE answers from the profile', '<ProtectYourPC>3' in seven and '<DisableWER>1' in seven and '<DisableWER>1' in ten)
    check('generic key used', '<Key>AAAAA-BBBBB-CCCCC-DDDDD-EEEEE</Key>' in ten)
    check('time zone name', '<TimeZone>Central European Standard Time</TimeZone>' in ten)
    check('escaped org', "O&apos;Brien Lab" in ten)
    check('server admin password', '<AdministratorPassword>' in server and '<AdministratorPassword>' not in ten)
    minimal = (OUT / 'minimal.windows-10.amd64.xml').read_text()
    check('minimal: no key, no language, Setup-chosen name', '<ProductKey>' not in minimal and 'International-Core' not in minimal and '<ComputerName>*</ComputerName>' in minimal)
    r = tool('render', str(DATA / 'full.profile.ini'), 'windows-10', 'amd64', str(OUT / 'typed.xml'), 'fffff-ggggg-hhhhh-jjjjj-kkkkk')
    check('typed key overrides the profile key', r.returncode == 0 and '<Key>FFFFF-GGGGG-HHHHH-JJJJJ-KKKKK</Key>' in (OUT / 'typed.xml').read_text())

    # Edition against the Windows 7 SP1 x64 pl install.wim metadata: the
    # per-system edition (localized name) is found by its EDITIONID and
    # written as /IMAGE/INDEX; the common one (Enterprise) is not on it.
    install_xml = DATA / 'win7-sp1-x64-pl.install.xml'
    for system, arch, expect in (('windows-7', 'amd64', '3'), ('windows-7', 'x86', '3'), ('windows-vista', 'amd64', None)):
        name = f'edition.{system}.{arch}.xml'
        r = tool('render', str(DATA / 'edition.profile.ini'), system, arch, str(OUT / name), '-', str(install_xml))
        check('render ' + name, r.returncode == 0, r.stderr.decode(errors='replace'))
        if r.returncode != 0:
            continue
        data = (OUT / name).read_bytes()
        golden(name, data)
        check_xml(name, data, arch)
        text = data.decode()
        if expect:
            check(name + ' edition by index', f'<Key>/IMAGE/INDEX</Key>' in text and f'<Value>{expect}</Value>' in text and 'image 3 (Windows 7 Professional)' in r.stderr.decode())
        else:
            check(name + ' edition not on the media: Setup asks', 'ImageInstall' not in text and 'not on the media' in r.stderr.decode())
        check(name + ' still no disk settings', 'InstallTo' not in text and 'DiskConfiguration' not in text)

    # NT5 through the staging merge.
    for system, base, _layout in NT5:
        rendered = OUT / f'full.{system}.nt5-settings.ini'
        r = tool('render', str(DATA / 'full.profile.ini'), system, 'x86', str(rendered))
        check('render nt5 ' + system, r.returncode == 0, r.stderr.decode(errors='replace'))
        golden(f'full.{system}.nt5-settings.ini', rendered.read_bytes())
        sif, accounts = nt5_merge(rendered, base, f'full.{system}', True)
        golden(f'full.{system}.WINNT.SIF', sif)
        golden(f'full.{system}.usos-users.cmd', accounts)
        text = sif.decode()
        check(system + ' regional settings', '[RegionalSettings]' in text and 'InputLocale=0415:00000415' in text and 'LanguageGroup="2"' in text)
        check(system + ' time zone 100', 'TimeZone=100' in text)
    xp = (GOLDEN / 'full.windows-xp.WINNT.SIF').read_text()
    w2k = (GOLDEN / 'full.windows-2000.WINNT.SIF').read_text()
    w2k3 = (GOLDEN / 'full.windows-server-2003.WINNT.SIF').read_text()
    check('XP key is the XP key', 'ProductKey=XXXXX-YYYYY-ZZZZZ-11111-22222' in xp)
    check('2000 uses ProductID', 'ProductID=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' in w2k and 'ProductKey=' not in w2k)
    check('2003 licensing page answered', '[LicenseFilePrintData]' in w2k3 and 'AutoMode=PerServer' in w2k3)
    check('XP keeps PAE and partition keys', 'UserExecute="C:\\USOS\\XP\\pae.exe"' in xp and 'Repartition=No' in xp and 'AutoPartition' not in xp)

    # usos-xp.ini -> model -> render -> merge == the old usos-xp.ini path.
    legacy = DATA / 'x470-usos-xp.ini'
    old_sif, old_accounts = nt5_merge(legacy, 'tools/xp_selected_partition_uefi_csm.sif', 'x470-legacy', False)
    imported = OUT / 'x470.profile.ini'
    r = tool('import-xp', str(legacy), str(imported))
    check('import usos-xp.ini', r.returncode == 0, r.stderr.decode(errors='replace'))
    golden('x470.profile.ini', imported.read_bytes())
    rendered = OUT / 'x470.nt5-settings.ini'
    tool('render', str(imported), 'windows-xp', 'x86', str(rendered))
    new_sif, new_accounts = nt5_merge(rendered, 'tools/xp_selected_partition_uefi_csm.sif', 'x470-profile', True)
    check('usos-xp.ini and its profile give the same WINNT.SIF', old_sif == new_sif and len(old_sif) > 500)
    check('usos-xp.ini and its profile give the same accounts script', old_accounts == new_accounts)
    golden('x470.WINNT.SIF', new_sif)
    # The profile mode still refuses unknown keys, the old mode the new keys.
    bad = OUT / 'bad.ini'
    bad.write_bytes(b'user=Bob\nlocale=00000415\n')
    check('usos-xp.ini refuses profile keys', sh(f"usos_xp_settings_load '{posix(bad)}' '{posix(OUT / 'bad.out')}' 00000415").returncode == 1)
    check('profile mode needs locale, input_locale and language_group together', sh(f"usos_xp_settings_load '{posix(bad)}' '{posix(OUT / 'bad.out')}' 00000415 profile").returncode == 1)

    # The plan hand-over (usos_xp_settings_plan / usos_answer_plan_take).
    esp = OUT / 'esp' / 'EFI' / 'USOS' / 'answer'
    esp.mkdir(parents=True)
    shutil.copy(OUT / 'full.windows-xp.nt5-settings.ini', esp / 'nt5-settings.ini')
    (esp / 'usos-plan.ini').write_bytes(b'[plan]\r\nversion=1\r\nprofile=xp-x86-sp3-uefi-csm\r\nsystem=windows-xp\r\n[answer]\r\nsource=profile\r\nname=Dom\r\nformat=nt5_settings\r\nfile=EFI/USOS/answer/nt5-settings.ini\r\narch=x86\r\nkey=yes\r\n')
    source = OUT / 'source' / 'I386'
    source.mkdir(parents=True)
    (source / 'TXTSETUP.SIF').write_bytes(b'[nls]\r\nDefaultLayout = 00000415\r\n')
    lib = posix(ROOT / 'tools' / 'xp_user_settings.sh')
    plan_cmd = subprocess.run([SH, '-c', f"USOS_XP_SETTINGS_OUT='{posix(OUT / 'plan.normalized')}'; . '{lib}'; "
                               f"usos_xp_settings_select x '{posix(OUT / 'source')}' '' plan '{posix(esp / 'usos-plan.ini')}' 2>&1; echo rc=$? settings=$XP_USER_SETTINGS"],
                              capture_output=True)
    out = plan_cmd.stdout.decode(errors='replace')
    check('plan: rendered settings consumed', 'profile "Dom" active' in out and 'rc=0' in out and 'family=xp' in out and 'plan.normalized' in out, out)
    check('plan: rendered file deleted from the ESP', not (esp / 'nt5-settings.ini').exists())
    check('plan: log has no key or password', 'XXXXX' not in out and 'Test123' not in out, out)
    check('plan: normalized settings equal the direct load', (OUT / 'plan.normalized').read_bytes() == (OUT / 'full.windows-xp.normalized').read_bytes())
    plan_cmd = subprocess.run([SH, '-c', f"USOS_XP_SETTINGS_OUT='{posix(OUT / 'plan2.normalized')}'; . '{lib}'; "
                               f"usos_xp_settings_select x '{posix(OUT / 'source')}' '' plan '{posix(esp / 'usos-plan.ini')}' 2>&1"],
                              capture_output=True)
    check('plan: missing rendered file stops before any write', plan_cmd.returncode == 1 and b'STOP' in plan_cmd.stdout)

    ap = posix(ROOT / 'tools' / 'answer_plan.sh')
    shutil.copy(OUT / 'full.windows-10.amd64.xml', esp / 'autounattend.xml')
    (esp / 'usos-plan.ini').write_bytes(b'[plan]\r\nversion=1\r\nprofile=windows-work\r\nsystem=windows-10\r\n[answer]\r\nsource=profile\r\nname=Dom\r\nformat=autounattend_xml\r\nfile=EFI/USOS/answer/autounattend.xml\r\narch=amd64\r\nkey=yes\r\n')
    taken = OUT / 'taken' / 'Autounattend.xml'
    r = subprocess.run([SH, '-c', f". '{ap}'; usos_answer_plan_take '{posix(esp / 'usos-plan.ini')}' autounattend_xml '{posix(taken)}'"], capture_output=True)
    check('WORK plan: file taken', r.returncode == 0 and taken.read_bytes() == (OUT / 'full.windows-10.amd64.xml').read_bytes(), r.stdout.decode(errors='replace'))
    check('WORK plan: rendered file deleted from the ESP', not (esp / 'autounattend.xml').exists())
    r = subprocess.run([SH, '-c', f". '{ap}'; usos_answer_plan_take '{posix(esp / 'usos-plan.ini')}' autounattend_xml '{posix(taken)}'"], capture_output=True)
    check('WORK plan: refuses a missing rendered file', r.returncode == 1)
    r = subprocess.run([SH, '-c', f". '{ap}'; usos_answer_plan_take '{posix(esp / 'usos-plan.ini')}' nt5_settings '{posix(taken)}'"], capture_output=True)
    check('WORK plan: refuses another format', r.returncode == 1)

    check_linux()
    check_tweaks()

    # Architecture-mismatch warning on a user's (Schneegans) amd64-only file.
    for candidate in (ROOT / 'zig-out' / 'usb' / 'Systems' / 'Windows' / 'Windows 11' / 'Unattended').glob('*.xml') if (ROOT / 'zig-out' / 'usb').exists() else []:
        r = tool('check-xml', str(candidate), 'x86')
        check(f'user file {candidate.name}: well-formed, x86 mismatch warned', r.returncode == 3, r.stderr.decode(errors='replace'))
        r = tool('check-xml', str(candidate), 'amd64')
        check(f'user file {candidate.name}: amd64 no warning', r.returncode == 0, r.stderr.decode(errors='replace'))

    print('ALL PASS' if not failures else f'{len(failures)} FAILED: ' + ', '.join(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
