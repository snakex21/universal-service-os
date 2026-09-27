"""Test helper: screendump a running QEMU (qemu-state.json of a run folder in
tools/tests/artifacts) every --every seconds for --minutes, keeping a PNG only
when the picture changed. Prints one line per kept screen.

  python tools/tests/legacy_bios/watch_qemu_screens.py --run csmwrap-vista --minutes 10
"""
from pathlib import Path
import argparse, hashlib, json, socket, time

ROOT = Path(__file__).resolve().parents[3]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--run', required=True)
    p.add_argument('--minutes', type=float, default=10)
    p.add_argument('--every', type=float, default=15)
    p.add_argument('--prefix', default='w')
    a = p.parse_args()
    run = ROOT / 'tools/tests/artifacts' / a.run
    state = json.loads((run / 'qemu-state.json').read_text())
    shots = run / 'shots'
    shots.mkdir(exist_ok=True)
    from PIL import Image
    last = None
    start = time.time()
    n = 0
    while time.time() - start < a.minutes * 60:
        ppm = shots / 'watch.ppm'
        ppm.unlink(missing_ok=True)
        try:
            with socket.create_connection(('127.0.0.1', state['port']), timeout=5) as s:
                s.sendall(f'screendump {ppm.as_posix()}\n'.encode())
                time.sleep(1.5)
        except OSError:
            print('[WATCH] QEMU monitor gone', flush=True)
            return 1
        for _ in range(20):
            if ppm.exists() and ppm.stat().st_size > 0:
                break
            time.sleep(0.3)
        if ppm.exists():
            digest = hashlib.sha256(ppm.read_bytes()).hexdigest()
            if digest != last:
                last = digest
                n += 1
                png = shots / f'{a.prefix}{n:03d}-{int(time.time() - start):04d}s.png'
                Image.open(ppm).save(png)
                print(f'[WATCH] {png.name}', flush=True)
        time.sleep(a.every)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
