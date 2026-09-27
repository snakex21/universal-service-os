"""XP without firmware CSM (profile xp-x86-sp3-uefi-csmwrap): prepare a blank
disk with the XP package's own scripts in CSMWrap mode (the Windows plan keeps
the disk's last 65 MiB free, then tools/xp_csmwrap_esp.sh adds the CSMWrap ESP),
then boot that disk ALONE on OVMF without CSM: firmware -> the disk's
\\EFI\\BOOT\\BOOTX64.EFI (CSMWrap) -> SeaBIOS -> MBR -> XP text mode.

Phase 1 is run_seabios_xp_uefi_csm_textmode.prepare() (the package chain with
a test-only rdinit, menus skipped) plus the two CSMWrap steps; phase 2 is
run_csmwrap_xp_ovmf.boot() (TCG). --run-through keeps going after the file
copy until XP restarts and CSMWrap boots the disk a second time.

  python tools/tests/legacy_bios/run_csmwrap_xp_prepared.py --output zig-out/csmwrap-xp-prepared [--run-through] [--minutes 14]
Disposable images only; no physical disk access.
"""
from pathlib import Path
import argparse, json, stat, sys
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import run_seabios_xp_uefi_csm_textmode as textmode  # noqa: E402
import run_csmwrap_xp_ovmf as csm  # noqa: E402

TAIL = '133120'
CSMWRAP_FILES = ROOT / 'zig-out/usb/EFI/USOS/csmwrap'


def csmwrap_probe(base):
    plan = 'awk -f /usr/lib/usos/xp_windows_partition_plan.awk "$TARGET_SNAPSHOT"'
    assert base.count(plan) == 1 and base.count('finish PREPARED-PASS') == 1
    probe = base.replace(plan, 'export USOS_XP_ESP_TAIL_SECTORS=' + TAIL + '; ' + plan)
    return probe.replace('finish PREPARED-PASS',
                         "USOS_CSMWRAP_DIR=/csmwrap-src sh /usr/lib/usos/xp_csmwrap_esp.sh || finish 'FAIL csmwrap esp'\nfinish PREPARED-PASS")


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--iso', type=Path, default=textmode.DEFAULT_ISO)
    p.add_argument('--minutes', type=float, default=14)
    p.add_argument('--run-through', action='store_true')
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    files = {name: (CSMWRAP_FILES / name).read_bytes() for name in
             ('csmwrapx64.efi', 'LICENSE-CSMWrap-LGPL-2.1.txt', 'COPYING-SeaBIOS-LGPLv3.txt', 'COPYING-SeaBIOS-GPLv3.txt', 'SOURCES.txt')}
    textmode.PROBE_INIT = csmwrap_probe(textmode.PROBE_INIT)
    parse = textmode.cpio.parse_newc

    def parse_with_csmwrap(data):
        entries = parse(data)
        textmode.cpio.put(entries, textmode.cpio.Entry('csmwrap-src', stat.S_IFDIR | 0o755, b''))
        for name, blob in files.items():
            textmode.cpio.put(entries, textmode.cpio.Entry('csmwrap-src/' + name, stat.S_IFREG | 0o644, blob))
        return entries
    textmode.cpio.parse_newc = parse_with_csmwrap
    target = textmode.prepare(out, a.iso, tree_scripts=('xp_csmwrap_esp.sh', 'xp_windows_partition_plan.awk'))
    log = (out / 'prepare-serial.log').read_text(errors='replace')
    ok = 'CSMWrap ESP PASS' in log
    print('[PREPARE] CSMWrap ESP', 'PASS' if ok else 'MISSING')
    if not ok:
        raise SystemExit(log[-4000:])
    result = csm.boot(out, target, 'csmwrap-boot', 'std', 'tcg,thread=multi', a.minutes, run_through=a.run_through)
    serial = (out / 'csmwrap-boot/serial.log').read_text(errors='replace') if (out / 'csmwrap-boot/serial.log').exists() else ''
    summary = {'result': result, 'csmwrap_boots': serial.count('Unlock!'), 'seabios_banners': serial.count('SeaBIOS (version')}
    (out / 'summary.json').write_text(json.dumps(summary, indent=1), encoding='utf-8')
    print(json.dumps(summary))
    return 0 if result == 'copying' else 1


if __name__ == '__main__':
    sys.exit(main())
