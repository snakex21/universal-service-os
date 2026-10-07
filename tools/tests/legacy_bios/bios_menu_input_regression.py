"""QEMU regression test for the USOS BIOS menu keyboard paths
(docs/design/bios-via-csmwrap.md, INT 16h fallback and 8042 polling).

Every key must arrive exactly once, also right after screens that read the
stick through INT 13h (the Windows list scans DATA):
  ps2   plain SeaBIOS, PS/2 keyboard (the Core polls the 8042; IRQ1/IRQ12
        are masked during BIOS calls so SeaBIOS's IRQ1 handler cannot take
        or double a byte)
  usb   OVMF -> CSMWrap, USB keyboard on xHCI (SeaBIOS INT 16h fallback)

  python bios_menu_input_regression.py --stick S.vhd [--path ps2|usb|both]

The stick is any USOS test stick (create_bios_csmwrap_stick.ps1) whose DATA
has at least one Windows system; --system-row N also walks a Windows 95/98/Me
image to its boot method and Automatic (the screens that read the stick). It is opened read-only. The check reads the
highlight of the main menu tiles and of the list rows from screenshots.
"""
from pathlib import Path
import argparse, subprocess, sys, time
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
# Main menu: tile centres (left column x=90, right x=690) at the row heights.
TILES = {'windows': (90, 240), 'linux': (690, 240), 'beta': (90, 356), 'dos': (690, 356),
         'utilities': (90, 472), 'power': (690, 472)}
# List screens: the first rows (selection bar at x=600).
ROWS = [(600, 172 + 62 * i) for i in range(8)]


def vm(out, *args):
    return subprocess.run([sys.executable, str(HERE / 'bios_csmwrap_vm.py'), '--out', str(out), *args],
                          check=True, capture_output=True, text=True).stdout


def shot(out, name):
    vm(out, 'shot', name)
    return Image.open(out / (name + '.png')).convert('RGB')


def brightest(im, points):
    """Index of the highlighted point (the selection fill is brighter)."""
    values = [sum(im.getpixel(p)) for p in points]
    best = max(range(len(values)), key=values.__getitem__)
    others = sorted(values)[-2] if len(values) > 1 else 0
    return best if values[best] - others > 30 else None


def key(out, name, wait):
    vm(out, 'key', name)
    time.sleep(wait)


def run(path, stick, out, system_row=None):
    out.mkdir(parents=True, exist_ok=True)
    args = ['start', '--stick', str(stick), '--stick-ro', '--mem', '512', '--tag', path]
    if path == 'ps2':
        args += ['--fw', 'seabios', '--kbd', 'ps2']
    else:
        args += ['--fw', 'ovmf', '--kbd', 'usb']
    vm(out, *args)
    failures = []
    try:
        if path == 'usb':
            # UEFI menu -> Utilities -> Legacy BIOS mode (CSMWrap) -> Start.
            time.sleep(30)
            for name in ('down', 'down', 'ret', 'down', 'down', 'down', 'down', 'ret', 'down', 'ret'):
                key(out, name, 3)
            time.sleep(25)
        else:
            time.sleep(40)
        names = list(TILES)
        expect = [('down', 'beta'), ('down', 'utilities'), ('right', 'power'), ('up', 'dos'), ('left', 'beta'), ('up', 'windows')]
        for step, (name, want) in enumerate(expect):
            key(out, name, 2.5)
            got = brightest(shot(out, f'{path}-main{step}'), list(TILES.values()))
            if got is None or names[got] != want:
                failures.append(f'main menu after {name}: {names[got] if got is not None else "?"} (want {want})')
        # The Windows list reads DATA through INT 13h: keys right after it.
        key(out, 'ret', 6)
        for step in range(1, 4):
            key(out, 'down', 2.5)
            got = brightest(shot(out, f'{path}-list{step}'), ROWS[:5])
            if got != step:
                failures.append(f'Windows list after {step} x down: row {got} (want {step})')
        key(out, 'esc', 3)
        got = brightest(shot(out, f'{path}-back'), list(TILES.values()))
        if got is None or names[got] != 'windows':
            failures.append(f'Esc from the list: {names[got] if got is not None else "?"} (want windows)')
        # Type-ahead: the two downs arrive while the Core is still reading the
        # stick for the Windows list; both must be kept, none doubled.
        for attempt in range(3):
            vm(out, 'key', '--delay', '0.25', 'ret', 'down', 'down')
            time.sleep(8)
            got = brightest(shot(out, f'{path}-ahead{attempt}'), ROWS[:5])
            if got != 2:
                failures.append(f'type-ahead {attempt}: row {got} (want 2)')
            key(out, 'esc', 3)
        if system_row is not None:
            # The path that lost Enter with the old Core: a system's image
            # list, its boot method and Automatic (each reads the stick). The
            # Windows 95/98/Me action screen has no info panel on the right.
            key(out, 'ret', 6)
            for _ in range(system_row):
                key(out, 'down', 1.5)
            for step, name in enumerate(('images', 'method', 'automatic')):
                key(out, 'ret', 8 if step < 2 else 25)
                im = shot(out, f'{path}-deep{step}')
                panel = sum(im.getpixel((1000, 300))) > 60
                if step == 1 and not panel:
                    failures.append('Enter on the image did not open the boot method screen')
                if step == 2 and panel:
                    failures.append('Enter on Automatic did not reach the next screen')
    finally:
        vm(out, 'stop')
    return failures


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--stick', type=Path, required=True)
    p.add_argument('--path', choices=('ps2', 'usb', 'both'), default='both')
    p.add_argument('--out', type=Path, default=ROOT / 'zig-out/tests/bios-menu-input')
    p.add_argument('--system-row', type=int, help='row of a Windows 95/98/Me system with an image (Windows 95 = 13 without Server images)')
    a = p.parse_args()
    failed = False
    for path in (('ps2', 'usb') if a.path == 'both' else (a.path,)):
        failures = run(path, a.stick.resolve(), a.out / path, a.system_row)
        for line in failures:
            print(f'[FAIL] {path}: {line}')
        if not failures:
            print(f'[PASS] {path}: every menu key arrived once (main menu, list after INT 13h reads, Esc)')
        failed |= bool(failures)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
