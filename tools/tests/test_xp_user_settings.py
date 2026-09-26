"""Host tests for tools/xp_user_settings.sh (usos-xp.ini -> WINNT.SIF + $OEM$).

    python tools/tests/test_xp_user_settings.py

Runs the library under the MSYS2/Git sh. BusyBox awk (the initramfs) is
covered by run_seabios_xp_uefi_csm_textmode.py --prepare-only --settings.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'zig-out' / 'xp-user-settings-tests'
BASE = ROOT / 'tools' / 'xp_selected_partition_uefi_csm.sif'
SH = next((p for p in (r'C:\msys64\usr\bin\sh.exe', r'C:\Program Files\Git\usr\bin\sh.exe', shutil.which('sh') or '') if p and Path(p).exists()), None)
# The shell's own coreutils (head, od, awk) first: PowerShell runs lack them on PATH.
if SH:
    os.environ['PATH'] = str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', '')
CRLF = b'\r\n'
failures: list[str] = []


def posix(path: Path) -> str:
    s = str(path.resolve()).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if s[1:2] == ':' else s


def sh(command: str) -> subprocess.CompletedProcess:
    lib = posix(ROOT / 'tools' / 'xp_user_settings.sh')
    return subprocess.run([SH, '-c', f". '{lib}'; {command}"], capture_output=True)


def check(name: str, condition: bool, detail: str = '') -> None:
    print(('PASS ' if condition else 'FAIL ') + name + ('' if condition else ' ' + detail))
    if not condition:
        failures.append(name)


def load(name: str, content: bytes, layout: str = '00000415') -> tuple[int, str, str]:
    ini = OUT / (name + '.ini'); out = OUT / (name + '.out')
    ini.write_bytes(content); out.unlink(missing_ok=True)
    r = sh(f"usos_xp_settings_load '{posix(ini)}' '{posix(out)}' {layout}")
    return r.returncode, out.read_text() if out.exists() else '', r.stderr.decode(errors='replace')


def main() -> int:
    if SH is None:
        print('sh not found'); return 1
    shutil.rmtree(OUT, ignore_errors=True); OUT.mkdir(parents=True)
    active = b'\xef\xbb\xbf; comment' + CRLF + b'[usos]' + CRLF + b'USER = Jan Kowalski' + CRLF + b'user2=Ania' + CRLF + \
        b'Computer=PC-1' + CRLF + b'org="Firma X"' + CRLF + b'key=abcde-12345-abcde-12345-abcde' + CRLF + b'password=Tajne1!' + CRLF
    rc, out, _ = load('active', active)
    check('active BOM/CRLF/case/quotes', rc == 0 and out == 'user=Jan Kowalski\nuser2=Ania\ncomputer=PC-1\norg=Firma X\n'
          'key=ABCDE-12345-ABCDE-12345-ABCDE\ntimezone=95\npassword=Tajne1!\n', out)
    rc, out, _ = load('defaults-us', b'user=Bob\n', '00000409')
    check('defaults US', rc == 0 and 'computer=USOS-XP\n' in out and 'timezone=4\n' in out and 'key=\n' in out, out)
    rc, out, _ = load('defaults-other', b'user=Bob\n', '00000407')
    check('defaults other language', rc == 0 and 'timezone=85\n' in out, out)
    rc, _, _ = load('inactive', b'; all empty\r\nuser=\r\nuser2=\r\nkey=\r\npassword=\r\n')
    check('inactive when user= empty', rc == 2)
    for name, content in (('unknown', b'user=Bob\nfoo=1\n'), ('builtin', b'user=Administrator\n'), ('long', b'user=' + b'a' * 21 + b'\n'),
                          ('same', b'user=Bob\nuser2=bob\n'), ('computer', b'user=Bob\ncomputer=12345\n'), ('computer2', b'user=Bob\ncomputer=a_b\n'),
                          ('key', b'user=Bob\nkey=ABCDE-12345\n'), ('tz', b'user=Bob\ntimezone=999\n'), ('pwspace', b'user=Bob\npassword=a b\n'),
                          ('pwchar', b'user=Bob\npassword=SECRET%X\n'), ('org', b'user=Bob\norg=A&B\n'), ('nonascii', 'user=Zażółć\n'.encode()),
                          ('noeq', b'user=Bob\njusttext\n')):
        rc, out, err = load('bad-' + name, content)
        check('invalid ' + name, rc == 1 and out == '' and 'SECRET' not in err, f'rc={rc} err={err!r}')
    # WINNT.SIF merge
    settings = OUT / 'active.out'
    merged = sh(f"usos_xp_settings_sif '{posix(BASE)}' '{posix(settings)}'").stdout.decode()
    lines = merged.splitlines()
    sections = [l for l in lines if l.startswith('[')]
    check('sections unique', len(sections) == len(set(s.lower() for s in sections)), str(sections))
    for want in ('UnattendMode=FullUnattended', 'OemPreinstall=No', 'UnattendSwitch=Yes', 'OemSkipEula=Yes', 'OEMSkipRegional=1',
                 'OemSkipWelcome=1', 'TimeZone=95', 'AdminPassword="Tajne1!"', 'EncryptedAdminPassword=No', 'FullName="Jan Kowalski"',
                 'OrgName="Firma X"', 'ComputerName=PC-1', 'ProductKey=ABCDE-12345-ABCDE-12345-ABCDE', 'JoinWorkgroup=WORKGROUP',
                 'InstallDefaultComponents=Yes', 'UserExecute="C:\\USOS\\XP\\pae.exe"', 'Command0="%SystemDrive%\\USOS\\XP\\pae.exe /firstlogon"',
                 'DriverSigningPolicy=Ignore', 'Repartition=No', 'FileSystem=LeaveAlone'):
        check('sif has ' + want, want in lines)
    check('sif keeps no ProvideDefault', 'UnattendMode=ProvideDefault' not in lines and 'OemPreinstall=Yes' not in lines)
    unattended = lines[lines.index('[Unattended]') + 1:]
    unattended = unattended[:next(i for i, l in enumerate(unattended) if l.startswith('['))]
    check('UnattendSwitch inside [Unattended]', 'UnattendSwitch=Yes' in unattended)
    base_lines = [l for l in BASE.read_text().splitlines() if not l.startswith('UnattendMode=')]
    check('every other base line kept', all(l in lines for l in base_lines))
    nokey = OUT / 'defaults-us.out'
    merged2 = sh(f"usos_xp_settings_sif '{posix(BASE)}' '{posix(nokey)}'").stdout.decode().splitlines()
    check('no key -> DefaultHide, no ProductKey, AdminPassword=*', 'UnattendMode=DefaultHide' in merged2
          and not any(l.startswith('ProductKey') for l in merged2) and 'AdminPassword=*' in merged2)
    # Accounts script (C:\USOS\XP\usos-users.cmd, run hidden by pae.exe)
    users_file = OUT / 'usos-users.cmd'
    r = sh(f"usos_xp_settings_accounts '{posix(settings)}' '{posix(users_file)}'")
    users = users_file.read_bytes()
    check('accounts rc', r.returncode == 0)
    check('usos-users.cmd CRLF', users.count(b'\n') == users.count(b'\r\n'))
    text = users.decode()
    check('usos-users.cmd accounts', 'net user "Jan Kowalski" "Tajne1!" /add' in text and 'net user "Ania" "Tajne1!" /add' in text
          and text.count('do net localgroup %%G') == 2 and 'Administratorzy' in text)
    # A .sif chosen in the menu, merged into the automatic answer
    user_sif = OUT / 'user.sif'
    user_sif.write_bytes(b'[Data]\r\nAutoPartition=1\r\n[unattended]\r\nUnattendMode=FullUnattended\r\nRepartition=Yes\r\n'
                         b'TargetPath=\\XP\r\nOemPreinstall=Yes\r\n[GuiUnattended]\r\nTimeZone=85\r\n[UserData]\r\nFullName="Me"\r\n'
                         b'[SetupParams]\r\nUserExecute="other.exe"\r\n[GuiRunOnce]\r\nCommand0="notepad.exe"\r\n[Display]\r\nBitsPerPel=32\r\n')
    custom = sh(f"usos_xp_custom_sif '{posix(BASE)}' '{posix(user_sif)}'").stdout.decode().splitlines()
    sections = [l for l in custom if l.startswith('[')]
    check('custom: sections unique', len(sections) == len(set(s.lower() for s in sections)), str(sections))
    for want in ('UnattendMode=FullUnattended', 'Repartition=No', 'FileSystem=LeaveAlone', 'TargetPath=\\WINDOWS', 'OemPreinstall=No',
                 'DriverSigningPolicy=Ignore', 'UserExecute="C:\\USOS\\XP\\pae.exe"', 'Command0="notepad.exe"',
                 'Command1="%SystemDrive%\\USOS\\XP\\pae.exe /firstlogon"', 'TimeZone=85', 'FullName="Me"', 'BitsPerPel=32', 'msdosinitiated="1"'):
        check('custom has ' + want, want in custom)
    for unwanted in ('AutoPartition=1', 'Repartition=Yes', 'TargetPath=\\XP', 'OemPreinstall=Yes', 'UserExecute="other.exe"', 'UnattendMode=ProvideDefault'):
        check('custom drops ' + unwanted, unwanted not in custom)
    # Which settings the staging uses (legacy_xp_staging.sh): the UEFI menu's
    # "manual installation" row (usos.xp_settings=off) ignores even an active
    # usos-xp.ini, a selected .sif wins, otherwise the file is staged.
    active_ini = OUT / 'active.ini'
    missing = OUT / 'missing.ini'
    for name, args, want in (
            ('manual install', f"'{posix(active_ini)}' /nonexistent '' off", '[XP_SETTINGS] ignored: manual install chosen'),
            ('custom .sif', f"'{posix(active_ini)}' /nonexistent /x/a.sif ''", '[XP_SETTINGS] ignored: custom WINNT.SIF selected'),
            ('custom .sif wins over off', f"'{posix(active_ini)}' /nonexistent /x/a.sif off", '[XP_SETTINGS] ignored: custom WINNT.SIF selected'),
            ('default stages the file', f"'{posix(missing)}' /nonexistent '' ''", '[XP_SETTINGS] none (missing.ini absent)')):
        r = sh(f"XP_USER_SETTINGS=stale; usos_xp_settings_select {args}; rc=$?; printf 'rc=%s settings=[%s]\\n' $rc \"$XP_USER_SETTINGS\"")
        out = r.stdout.decode()
        check('select: ' + name, want in out and 'rc=0 settings=[]' in out, out)
    print('FAILED' if failures else 'ALL PASS', len(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
