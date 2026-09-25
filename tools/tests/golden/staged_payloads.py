"""M0 characterization: fingerprints of what USOS stages for each OS family.

docs/design/refactor-os-pipeline.md, section 3 and M0. Host only: no ISO,
no stick, no VM. Reads the artifacts of the last build (zig-out) and the
committed payload.zip, and compares with tools/tests/golden/:

  staged_payloads.tsv
    initramfs     micro-Linux scripts and helpers (usr/lib/usos, usos-init);
                  the XP BIOS, 2000, Vista/7 BIOS, WORK (8/10/11/Linux ISO),
                  WIMBoot/VHDBoot paths all run from here
    xp_csm        entries the XP UEFI-CSM package derives from that base
                  (build_xp_uefi_csm_trial.overlay, with a stand-in pae.exe
                  and no driver bundle: those are fingerprinted by
                  compare_xp_packages.py / test_xp_reproducible.py)
    native_cpio   files wimboot injects into WinPE on the native UEFI paths
                  (support.cpio for all, win7-support.cpio for 7,
                  vista-support.cpio for Vista, modern-support.cpio for 10/11)
    payload_zip   member names of the embedded installer payload
  xp_winnt_bios.sif, xp_winnt_uefi_csm.sif
    the WINNT.SIF USOS writes for XP from BIOS and from UEFI-CSM (empty form)

Usage:
  python tools/tests/golden/staged_payloads.py            compare
  python tools/tests/golden/staged_payloads.py --update   rewrite the goldens

Fails with "stale build" when zig-out does not match the scripts in tools/
(run build.bat, or `zig build micro-linux` plus
tools/build_windows_native_support.py, first).
"""
from pathlib import Path
import argparse
import difflib
import gzip
import hashlib
import stat
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_micro_linux import parse_newc  # noqa: E402
import build_xp_uefi_csm_trial as xp_csm  # noqa: E402

GOLDEN = Path(__file__).resolve().parent
BASE = ROOT / 'zig-out/micro-linux/initramfs-usos'
NATIVE = ROOT / 'zig-out/windows-native'
PAYLOAD = ROOT / 'installer/internal/payload/assets/payload.zip'
# Built from Zig UI code: its bytes change with any Zig refactor that keeps
# behaviour; covered by zig build test and the QEMU screenshots instead.
UNHASHED = {'usr/bin/usos-fb-ui'}
# Carries the build identifier.
VARIABLE_MEMBERS = {'usos-build.txt'}
STAND_IN_PAE = b'USOS-M0-STAND-IN-PAE-HELPER\n'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load_initramfs(path):
    data = path.read_bytes()
    if data[:2] == b'\x1f\x8b':
        data = gzip.decompress(data)
    return parse_newc(data)


def kind(entry):
    if stat.S_ISDIR(entry.mode):
        return 'dir'
    if stat.S_ISLNK(entry.mode):
        return 'link:' + entry.data.decode('utf-8', 'replace')
    return sha(entry.data)


def tracked(name):
    return name in ('init', 'usos-init') or name.startswith('usr/lib/usos/')


def check_fresh(entries):
    stale = []
    for name, entry in entries.items():
        if not name.startswith('usr/lib/usos/') or name.count('/') != 3:
            continue
        source = ROOT / 'tools' / name.rsplit('/', 1)[1]
        if source.suffix in ('.sh', '.awk', '.sif') and source.is_file() and source.read_bytes() != entry.data:
            stale.append(name)
    init = ROOT / 'tools/micro_linux_init.sh'
    if entries['usos-init'].data != init.read_bytes():
        stale.append('usos-init')
    return stale


def newc_members(path):
    data = path.read_bytes()
    members, offset = [], 0
    while offset + 110 <= len(data):
        header = data[offset:offset + 110]
        if header[:6] != b'070701':
            raise ValueError(f'{path.name}: bad newc magic at {offset}')
        size = int(header[54:62], 16)
        name_size = int(header[94:102], 16)
        name = data[offset + 110:offset + 110 + name_size - 1].decode('utf-8')
        offset = (offset + 110 + name_size + 3) & ~3
        body = data[offset:offset + size]
        offset = (offset + size + 3) & ~3
        if name == 'TRAILER!!!':
            break
        members.append((name, body))
    return members


def render():
    lines, texts = [], {}
    base = load_initramfs(BASE)
    stale = check_fresh(base)
    if stale:
        raise SystemExit('stale build: zig-out/micro-linux differs from tools/ for ' + ', '.join(stale))

    lines.append('# initramfs: name mode sha256')
    for name in sorted(n for n in base if tracked(n)):
        entry = base[name]
        lines.append(f'initramfs\t{name}\t{entry.mode:o}\t{kind(entry)}')

    # XP UEFI-CSM package derived from this base, exactly as the package build does.
    scratch = ROOT / 'tools/tests/artifacts/golden'
    scratch.mkdir(parents=True, exist_ok=True)
    helper = scratch / 'stand-in-pae.exe'
    helper.write_bytes(STAND_IN_PAE)
    derived = parse_newc(gzip.decompress(xp_csm.overlay(BASE, helper, [])))
    lines.append('# xp_csm: entries added or changed by the UEFI-CSM overlay (stand-in pae.exe)')
    for name in sorted(derived):
        entry = derived[name]
        before = base.get(name)
        if before is not None and before.mode == entry.mode and before.data == entry.data:
            continue
        value = 'stand-in' if entry.data == STAND_IN_PAE else ('unhashed' if name in UNHASHED else kind(entry))
        lines.append(f'xp_csm\t{name}\t{entry.mode:o}\t{value}')
    removed = sorted(set(base) - set(derived))
    for name in removed:
        lines.append(f'xp_csm_removed\t{name}')

    texts['xp_winnt_bios.sif'] = base['usr/lib/usos/xp_selected_partition.sif'].data
    texts['xp_winnt_uefi_csm.sif'] = derived['usr/lib/usos/xp_selected_partition.sif'].data

    lines.append('# native_cpio: archive member size sha256')
    for archive in ('support.cpio', 'win7-support.cpio', 'vista-support.cpio', 'modern-support.cpio'):
        for member, body in newc_members(NATIVE / archive):
            value = 'variable' if member in VARIABLE_MEMBERS else f'{len(body)}\t{sha(body)}'
            lines.append(f'native_cpio\t{archive}\t{member}\t{value}')

    lines.append('# payload_zip: member names of the embedded installer payload')
    with zipfile.ZipFile(PAYLOAD) as archive:
        for name in sorted(archive.namelist()):
            lines.append(f'payload_zip\t{name}')
    texts['staged_payloads.tsv'] = ('\n'.join(lines) + '\n').encode('utf-8')
    return texts


def normalized(data):
    return data.replace(b'\r\n', b'\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--update', action='store_true')
    args = parser.parse_args()
    missing = [str(p.relative_to(ROOT)) for p in (BASE, NATIVE / 'support.cpio', PAYLOAD) if not p.is_file()]
    if missing and not args.update:
        print('SKIP staged payload goldens: no build output (' + ', '.join(missing) + '); run build.bat first')
        return 0
    texts = render()
    if args.update:
        for name, data in texts.items():
            (GOLDEN / name).write_bytes(data)
            print('updated', GOLDEN / name)
        return 0
    failed = False
    out_dir = ROOT / 'tools/tests/artifacts/golden'
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, data in texts.items():
        path = GOLDEN / name
        expected = normalized(path.read_bytes()) if path.is_file() else b''
        # SIF files are compared byte for byte (CRLF is part of the contract).
        actual = data if name.endswith('.sif') else normalized(data)
        if name.endswith('.sif'):
            expected = path.read_bytes() if path.is_file() else b''
        if expected == actual:
            print('PASS', name)
            continue
        failed = True
        (out_dir / name).write_bytes(data)
        diff = difflib.unified_diff(expected.decode('utf-8', 'replace').splitlines(), actual.decode('utf-8', 'replace').splitlines(),
                                    'golden/' + name, 'actual/' + name, lineterm='', n=1)
        print('FAIL', name, '(actual written to', out_dir / name, ')')
        for index, line in enumerate(diff):
            if index >= 60:
                print('  ...')
                break
            print(' ', line)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
