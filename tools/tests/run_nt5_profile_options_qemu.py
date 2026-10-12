#!/usr/bin/env python3
"""NT5 (XP / 2000) typed answer-profile options end to end in QEMU (dev PC only).

1. prepare: the XP UEFI package's initramfs (USOS_XP_PACKAGE_DIR or --package)
   runs the real preparation chain (run_seabios_xp_uefi_csm_textmode.prepare)
   with this tree's xp_user_settings.sh + prepare_xp_ntfs_target.sh and
   usr/lib/usos/usos-reg.exe; the settings come from a rendered answer
   profile in plan mode (EFI/USOS/answer/usos-plan.ini + nt5-settings.ini,
   usos_xp_settings_plan), as the boot menu hands them over.
2. install: the prepared disk boots on SeaBIOS from IDE (the firmware-CSM
   stand-in; CSMWrap is not part of what is tested here), text mode, GUI
   Setup, setup-end usos-users.cmd (usos-reg.exe), first automatic logon.
   Screenshots every --shot seconds in OUT/shots. --cmd-at types
   `net config workstation` into Run once (screenshot), then the VM is shut
   down (`shutdown -s` typed for XP, the ACPI power button for 2000).
   Give the VM a NIC (--nic user,model=rtl8139): without a network adapter
   Setup ignores [Identification] JoinWorkgroup and joins WORKGROUP.
   Touch OUT/STOP-NOW once the desktop is up to do the same at that point.
3. check: the hives and logs are pulled from the qcow2 with 7-Zip and every
   reg= line of the rendered settings is compared (python-registry):
   HKLM -> SOFTWARE/SYSTEM, DEFAULT -> DEFAULT, USER -> Default User AND the
   profile user's NTUSER.DAT. Results in OUT/check.json.

  python tools/tests/run_nt5_profile_options_qemu.py --family xp --iso XP.iso \
      --settings nt5-settings.ini --out DIR [--exports USOS_XP_EDITION=mce]
  python tools/tests/run_nt5_profile_options_qemu.py --family w2k --iso W2K.iso --settings nt5-2000.ini --out DIR

Scratch images only (OUT); no physical disk. QEMU: a renamed copy (--qemu-exe)
in --qemu-dir, stopped only by its own PID. Delete OUT afterwards. The
settings file holds the logon password: keep it outside the repository.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE / 'legacy_bios'))
import run_seabios_xp_uefi_csm_textmode as tm  # noqa: E402

SEVENZIP = Path(r'C:\Program Files\7-Zip\7z.exe')
PROFILES = {'xp': 'xp-x86-sp3-uefi-csm', 'w2k': 'w2k-x86-sp4-uefi-csm'}
SETTINGS_LINE = ("if [ -r /usr/lib/usos/xp_user_settings.sh ]; then . /usr/lib/usos/xp_user_settings.sh; "
                 "usos_xp_settings_stage /probe-usos-xp.ini /mnt/source || finish 'FAIL settings'; fi")
PLAN_LINES = ("mkdir -p /mnt/esp/EFI/USOS/answer; cp /probe-answer/usos-plan.ini /probe-answer/nt5-settings.ini /mnt/esp/EFI/USOS/answer/\n"
              ". /usr/lib/usos/xp_user_settings.sh; usos_xp_settings_select '' /mnt/source '' plan /mnt/esp/EFI/USOS/answer/usos-plan.ini || finish 'FAIL settings'\n"
              "[ -e /mnt/esp/EFI/USOS/answer/nt5-settings.ini ] && finish 'FAIL rendered settings not deleted'")


def plan_text(family: str) -> bytes:
    system = {'xp': 'windows-xp', 'w2k': 'windows-2000'}[family]
    return ("; USOS plan (test)\r\n[plan]\r\nversion=1\r\nprofile=%s\r\nsystem=%s\r\n[answer]\r\nsource=profile\r\n"
            "name=Options NT5\r\nformat=nt5_settings\r\nfile=EFI/USOS/answer/nt5-settings.ini\r\narch=x86\r\nkey=no\r\n"
            % (PROFILES[family], system)).encode()


def prepare(a, out: Path) -> Path:
    tm.PROBE_INIT = tm.PROBE_INIT.replace(SETTINGS_LINE, PLAN_LINES)
    assert PLAN_LINES in tm.PROBE_INIT
    if a.exports:
        os.environ['USOS_TEST_PROBE_EXPORTS'] = ' '.join(a.exports)
    usos_reg = Path(a.usos_reg).read_bytes()
    extra = {'probe-answer/usos-plan.ini': plan_text(a.family),
             'probe-answer/nt5-settings.ini': Path(a.settings).read_bytes()}
    parse = tm.cpio.parse_newc

    def parse_with_answer(data):
        entries = parse(data)
        tm.cpio.put(entries, tm.cpio.Entry('probe-answer', stat.S_IFDIR | 0o755, b''))
        for name, blob in extra.items():
            tm.cpio.put(entries, tm.cpio.Entry(name, stat.S_IFREG | 0o644, blob))
        tm.cpio.put(entries, tm.cpio.Entry('usr/lib/usos/usos-reg.exe', stat.S_IFREG | 0o644, usos_reg))
        return entries
    tm.cpio.parse_newc = parse_with_answer
    target = tm.prepare(out, Path(a.iso), PROFILES[a.family], None, ('xp_user_settings.sh', 'prepare_xp_ntfs_target.sh'))
    log = (out / 'prepare-serial.log').read_text(errors='replace')
    lines = [l for l in log.splitlines() if re.search(r'XP_SETTINGS|registry set staged|usos-users.cmd staged|product key|RESULT', l)]
    (out / 'prepare-summary.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n'.join(lines), flush=True)
    if 'registry set staged' not in log:
        raise SystemExit('the registry set was not staged')
    (out / 'usos-blank.qcow2').unlink(missing_ok=True)
    return target


def install(a, out: Path, target: Path) -> str:
    shots = out / 'shots'
    shots.mkdir(exist_ok=True)
    port = tm.free_port()
    accel = ['-accel', 'whpx', '-accel', 'tcg'] if a.accel == 'whpx' else ['-accel', 'tcg,thread=multi']
    cmd = [str(tm.QEMU), '-machine', 'pc', *accel, '-cpu', 'max' if a.accel == 'whpx' else 'qemu32', '-m', '1024', '-smp', '1',
           '-bios', str(tm.SEABIOS), '-boot', 'order=c', '-display', 'none', '-vga', 'std', '-nic', a.nic, '-rtc', 'base=localtime',
           '-drive', f'file={target.as_posix()},format=qcow2,if=ide,index=0,media=disk,cache=writeback',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off']
    q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=(out / 'qemu.log').open('wb'))
    (out / 'qemu.pid').write_text(str(q.pid))
    print('qemu pid', q.pid, flush=True)
    mon = tm.Monitor(port)
    t0 = time.time()
    n = 0
    state = 'timeout'
    typed = False
    powerdown_at = None
    try:
        while q.poll() is None and time.time() - t0 < a.minutes * 60:
            time.sleep(a.shot)
            n += 1
            el = int(time.time() - t0)
            ppm = shots / f'{n:04d}-{el:05d}s.ppm'
            try:
                mon.cmd(f'screendump "{ppm.as_posix()}"')
                time.sleep(0.5)
                from PIL import Image
                Image.open(ppm).save(ppm.with_suffix('.png'))
                ppm.unlink()
            except Exception:  # noqa: BLE001
                pass
            stop = out / 'STOP-NOW'   # operator file: type the check command / power down now
            if not typed and (a.cmd_at and el >= a.cmd_at or stop.exists()):
                typed = True
                stop.unlink(missing_ok=True)
                type_text(mon, 'meta_l-r', None)
                time.sleep(3)
                type_text(mon, None, 'cmd /k net config workstation & net accounts')
                time.sleep(15)
                mon.cmd(f'screendump "{(out / "net-config.ppm").as_posix()}"')
                time.sleep(1)
                powerdown_at = time.time() + 30
            if powerdown_at and time.time() >= powerdown_at:
                powerdown_at = None
                if a.family == 'xp':
                    type_text(mon, None, 'shutdown -s -t 5')
                else:
                    mon.cmd('system_powerdown')
            print(f'shot {n} at {el} s', flush=True)
        state = 'ended' if q.poll() is not None else 'timeout'
    finally:
        if q.poll() is None:
            try:
                mon.cmd('quit')
                q.wait(20)
            except Exception:  # noqa: BLE001
                q.kill()
    print('install', state, 'after', int(time.time() - t0), 's', flush=True)
    return state


KEYS = {' ': 'spc', '/': 'slash', '-': 'minus', '.': 'dot', '\\': 'backslash', ':': 'shift-semicolon', '>': 'shift-dot', '_': 'shift-minus', '&': 'shift-7'}


def type_text(mon, combo, text):
    if combo:
        mon.cmd('sendkey ' + combo)
    if text is not None:
        for ch in text:
            k = KEYS.get(ch, ch.lower() if ch.isalnum() else None)
            if ch.isupper():
                k = 'shift-' + ch.lower()
            if k:
                mon.cmd('sendkey ' + k)
        mon.cmd('sendkey ret')


# ---- offline check ----

def extract(out: Path, target: Path, sysroot: str, user: str) -> Path:
    # 7-Zip reads the qcow2 itself (QCOW -> MBR -> NTFS) and opens a disk with one
    # NTFS partition as that volume; no raw copy of the 12 GiB disk is needed.
    ex = out / 'extract'
    ex.mkdir(exist_ok=True)
    img = target
    paths = [f'{sysroot}/system32/config/SOFTWARE', f'{sysroot}/system32/config/SYSTEM', f'{sysroot}/system32/config/DEFAULT',
             f'{sysroot}/system32/config/SECURITY', f'{sysroot}/system32/config/SAM', 'Documents and Settings/Default User/NTUSER.DAT',
             f'Documents and Settings/{user}/NTUSER.DAT', f'{sysroot}/usos-reg.log', f'{sysroot}/usos-users.log',
             f'{sysroot}/setuperr.log', 'USOS']
    for p in paths:
        sub = ex / p.replace('/', '_').replace(' ', '_')
        subprocess.run([str(SEVENZIP), 'x', '-y', f'-o{sub}', str(img), p.replace('/', '\\')], capture_output=True)
    return ex


# SHELLSTATE (shlobj.h), the flag DWORD after cbSize: fShowAllObjects bit 0, fShowSuperHidden bit 15.
SHELLSTATE_BITS = {'Hidden': 0, 'ShowSuperHidden': 15}


def shellstate_bit(blob, bit):
    if not isinstance(blob, (bytes, bytearray)) or len(blob) < 8:
        return None
    return (int.from_bytes(blob[4:8], 'little') >> bit) & 1


def find_one(d: Path) -> Path | None:
    files = [f for f in d.rglob('*') if f.is_file()] if d.exists() else []
    return files[0] if len(files) == 1 else (files[0] if files else None)


def check(a, out: Path, target: Path) -> int:
    from Registry import Registry
    sysroot = 'WINDOWS' if a.family == 'xp' else 'WINNT'
    ex = extract(out, target, sysroot, a.user)
    hive = {}
    for key, p in (('SOFTWARE', f'{sysroot}/system32/config/SOFTWARE'), ('SYSTEM', f'{sysroot}/system32/config/SYSTEM'),
                   ('DEFAULT', f'{sysroot}/system32/config/DEFAULT'), ('SECURITY', f'{sysroot}/system32/config/SECURITY'),
                   ('DEFUSER', 'Documents and Settings/Default User/NTUSER.DAT'), ('USER', f'Documents and Settings/{a.user}/NTUSER.DAT')):
        f = find_one(ex / p.replace('/', '_').replace(' ', '_'))
        hive[key] = Registry.Registry(str(f)) if f else None
    results = []

    def get(h, path, name):
        if hive.get(h) is None:
            return 'nohive', None
        try:
            k = hive[h].open(path)
        except Registry.RegistryKeyNotFoundException:
            return 'nokey', None
        try:
            v = k.value(name)
        except Registry.RegistryValueNotFoundException:
            return 'novalue', None
        return v.value_type_str(), v.value()

    current = 1
    if hive['SYSTEM']:
        current = hive['SYSTEM'].open('Select').value('Current').value()
    for line in Path(a.settings).read_text(errors='replace').splitlines():
        if not line.startswith('reg='):
            continue
        spec = line[4:]
        root_key, rest = spec.split('\\', 1)
        path, name, typ, data = rest.split('|', 3)
        if root_key == 'HKLM':
            top, path = path.split('\\', 1)
            path = path.replace('CurrentControlSet', 'ControlSet%03d' % current)
            targets = [top.upper()]
        elif root_key == 'DEFAULT':
            targets = ['DEFAULT']
        else:
            targets = ['DEFUSER', 'USER']
        for h in targets:
            got_type, got = get(h, path, name)
            if typ == 'del':
                ok = got_type in ('novalue', 'nokey')
            elif typ == 'dword':
                ok = got_type == 'RegDWord' and got == int(data, 0)
            else:
                ok = got_type == 'RegSZ' and str(got).rstrip('\x00') == data
            note = ''
            if not ok and h == 'USER' and typ == 'dword' and name in SHELLSTATE_BITS:
                # XP's first logon folds Hidden/ShowSuperHidden into Explorer\ShellState
                # (SHELLSTATE flags) and may drop the raw value: the effective setting counts.
                blob = get('USER', 'Software\\Microsoft\\Windows\\CurrentVersion\\Explorer', 'ShellState')[1]
                bit = shellstate_bit(blob, SHELLSTATE_BITS[name])
                ok = bit == (1 if int(data, 0) == 1 else 0)
                note = f'raw value {got_type}; ShellState flag bit {SHELLSTATE_BITS[name]} = {bit}'
            shown ='<password>' if name == 'DefaultPassword' else got
            results.append({'hive': h, 'line': spec if name != 'DefaultPassword' else spec.rsplit('|', 1)[0] + '|<password>',
                            'got_type': got_type, 'got': shown, 'note': note, 'result': 'PASS' if ok else 'FAIL'})
    # Extras: workgroup (SECURITY Policy\PolPrDmN holds the primary domain/workgroup name).
    wg = 'n/a'
    if hive['SECURITY']:
        try:
            raw = hive['SECURITY'].open('Policy\\PolPrDmN').value('(default)').raw_data()
            # Self-relative UNICODE_STRING: Length, MaximumLength, buffer offset (8), then the name.
            length = int.from_bytes(raw[0:2], 'little')
            wg = raw[8:8 + length].decode('utf-16-le', 'replace')
        except Exception as e:  # noqa: BLE001
            wg = 'error ' + type(e).__name__
    extras = {'workgroup_PolPrDmN': wg}
    # run=net.exe accounts /maxpwage:unlimited: SAM Domains\Account F, MaxPasswordAge (int64 at 0x18;
    # Windows' default is -42 days in 100 ns units, unlimited is 0x8000000000000000).
    sam = find_one(ex / f'{sysroot}/system32/config/SAM'.replace('/', '_'))
    if sam:
        f = Registry.Registry(str(sam)).open('SAM\\Domains\\Account').value('F').value()
        age = int.from_bytes(f[0x18:0x20], 'little', signed=True)
        extras['SAM MaxPasswordAge'] = hex(age & (2 ** 64 - 1))
        if any(l.strip() == 'run=net.exe accounts /maxpwage:unlimited' for l in Path(a.settings).read_text(errors='replace').splitlines()):
            results.append({'hive': 'SAM', 'line': 'run=net.exe accounts /maxpwage:unlimited', 'got_type': 'MaxPasswordAge',
                            'got': extras['SAM MaxPasswordAge'], 'note': '', 'result': 'PASS' if age == -2 ** 63 else 'FAIL'})
    want_wg = next((l[10:].strip() for l in Path(a.settings).read_text(errors='replace').splitlines() if l.startswith('workgroup=')), '')
    if want_wg:
        results.append({'hive': 'SECURITY', 'line': 'workgroup=' + want_wg + ' (Policy\\PolPrDmN)', 'got_type': 'PolPrDmN',
                        'got': wg, 'note': '', 'result': 'PASS' if wg == want_wg else 'FAIL'})
    for name in ('AutoAdminLogon', 'DefaultUserName', 'AutoLogonCount', 'DefaultDomainName'):
        t, v = get('SOFTWARE', 'Microsoft\\Windows NT\\CurrentVersion\\Winlogon', name)
        extras['Winlogon\\' + name] = [t, v]
    for name in ('Hidden', 'HideFileExt', 'ShowSuperHidden'):
        for h in ('DEFUSER', 'USER'):
            extras[f'{h} Advanced\\{name}'] = list(get(h, 'Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced', name))
    t, v = get('USER', 'Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Tips', 'Show')
    extras['USER Tips\\Show'] = [t, v]
    t, v = get('SOFTWARE', 'Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer', 'NoDriveTypeAutoRun')
    extras['NoDriveTypeAutoRun'] = [t, v]
    for log in ('usos-reg.log', 'usos-users.log', 'setuperr.log'):
        f = find_one(ex / f'{sysroot}/{log}'.replace('/', '_'))
        extras[log] = f.read_text(errors='replace') if f else None
    staged = sorted(str(p.relative_to(ex)) for p in (ex / 'USOS').rglob('*') if p.is_file()) if (ex / 'USOS').exists() else []
    extras['USOS tree left on C:'] = staged
    report = {'results': results, 'extras': extras,
              'summary': 'PASS' if results and all(r['result'] == 'PASS' for r in results) else 'FAIL'}
    (out / 'check.json').write_text(json.dumps(report, indent=1, default=str), encoding='utf-8')
    for r in results:
        print(r['result'], r['hive'], r['line'], r['got_type'], r['got'], r['note'])
    print(json.dumps(extras, indent=1, default=str))
    print('SUMMARY', report['summary'])
    return 0 if report['summary'] == 'PASS' else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--family', choices=list(PROFILES), required=True)
    p.add_argument('--iso', required=True)
    p.add_argument('--settings', required=True, help='nt5-settings.ini rendered by usos-answer render')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--package', type=Path, help='XP UEFI package dir (vmlinuz.efi, initramfs-xp)')
    p.add_argument('--qemu-dir', type=Path, help='dir with qemu-img.exe, share/bios-256k.bin and --qemu-exe')
    p.add_argument('--qemu-exe', default='qemu-system-x86_64.exe')
    p.add_argument('--usos-reg', default=str(ROOT / 'zig-out/windows-usos-reg/usos-reg.exe'))
    p.add_argument('--exports', action='append', default=[], help='USOS_TEST_PROBE_EXPORTS entries, e.g. USOS_XP_EDITION=mce')
    p.add_argument('--accel', choices=['whpx', 'tcg'], default='whpx')
    p.add_argument('--minutes', type=float, default=150)
    p.add_argument('--shot', type=int, default=30)
    p.add_argument('--cmd-at', type=int, default=0, help='seconds into the install VM: type net config workstation, then shut down')
    p.add_argument('--nic', default='none', help='QEMU -nic value, e.g. user,model=rtl8139 (Setup ignores [Identification] JoinWorkgroup without a NIC)')
    p.add_argument('--user', default='Tester')
    p.add_argument('--stage', choices=['all', 'prepare', 'install', 'check'], default='all')
    a = p.parse_args()
    if a.package:
        tm.PACKAGE = a.package
    if a.qemu_dir:
        tm.QEMU = a.qemu_dir / a.qemu_exe
        tm.QEMU_IMG = a.qemu_dir / 'qemu-img.exe'
        tm.SEABIOS = a.qemu_dir / 'share/bios-256k.bin'
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    target = out / 'target.qcow2'
    if a.stage in ('all', 'prepare'):
        target = prepare(a, out)
    if a.stage in ('all', 'install'):
        install(a, out, target)
    if a.stage in ('all', 'check'):
        return check(a, out, target)
    return 0


if __name__ == '__main__':
    sys.exit(main())
