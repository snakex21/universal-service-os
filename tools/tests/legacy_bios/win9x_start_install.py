"""Drive a running bios_csmwrap_vm.py VM from the USOS BIOS main menu to a
confirmed Windows 95/98/Me installation (docs/win9x-modern-2026-09-30.md).

  python win9x_start_install.py --out DIR --system windows-98-se [--answer N] [--size 0|1|2]

--answer: row on the answer-file screen (0 = none; omit when the system has
no Unattended files, the screen is then skipped). --size: 0 = 32 GiB,
1 = 8 GiB, 2 = 2 GiB. Screenshots of every step go to DIR.
"""
from pathlib import Path
import argparse, subprocess, sys, time

HERE = Path(__file__).resolve().parent
# Rows below the top of Windows (without Server images on DATA).
ROWS = {'windows-me': 10, 'windows-98-se': 11, 'windows-98': 12, 'windows-95': 13}


def vm(out, *args):
    return subprocess.run([sys.executable, str(HERE / 'bios_csmwrap_vm.py'), '--out', str(out), *args],
                          check=True, capture_output=True, text=True).stdout


def keys(out, *names, wait=2.0):
    vm(out, 'key', '--delay', '0.8', *names)
    time.sleep(wait)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--system', choices=sorted(ROWS), required=True)
    p.add_argument('--answer', type=int)
    p.add_argument('--size', type=int, default=0)
    p.add_argument('--prepare-wait', type=float, default=90.0, help='seconds for the RAM disk copy')
    a = p.parse_args()
    keys(a.out, 'ret')
    keys(a.out, *(['down'] * ROWS[a.system]), 'ret', wait=3)
    keys(a.out, 'ret', wait=4)            # the only image
    keys(a.out, 'ret', wait=15)           # Automatic (DOS Setup): reads the ISO
    if a.answer is not None:
        keys(a.out, *(['down'] * a.answer), 'ret', wait=3)
    vm(a.out, 'shot', 'start-action')
    keys(a.out, 'down', 'ret', wait=a.prepare_wait)   # new installation
    vm(a.out, 'shot', 'start-disks')
    keys(a.out, 'ret', wait=3)            # first disk
    keys(a.out, *(['down'] * a.size), 'ret', wait=3)
    vm(a.out, 'shot', 'start-confirm')
    keys(a.out, 'down', 'ret', wait=5)    # delete partitions and install
    print('install confirmed')


if __name__ == '__main__':
    main()
