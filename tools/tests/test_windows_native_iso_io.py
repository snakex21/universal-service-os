"""Compare production GPT/NTFS/UDF reads with an independent ISO extractor.

Run `zig build windows-native-io-probe -Doptimize=ReleaseFast` first, then pass
a disposable raw USOS disk and the original Vista ISO. Both inputs are read-only.
"""
from pathlib import Path
import argparse
import hashlib
import re
import subprocess


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('raw_disk', type=Path)
    parser.add_argument('iso', type=Path)
    parser.add_argument('--seven-zip', default=r'C:\Program Files\7-Zip\7z.exe')
    args = parser.parse_args()
    probe = root / 'zig-out/bin/usos-windows-native-io-probe.exe'
    result = subprocess.run([str(probe), str(args.raw_disk), args.iso.name],
                            capture_output=True, text=True, check=True)
    checks = re.findall(r'([^\r\n]+) size=(\d+) sha256=([0-9a-f]{64})', result.stderr)
    expected = ['bootmgr', 'boot/bcd', 'boot/boot.sdi', 'sources/boot.wim',
                'sources/setup.exe', 'sources/install.wim']
    if [path for path, _, _ in checks] != expected:
        raise RuntimeError('Incomplete native probe output: ' + result.stderr)
    for path, size, actual in checks:
        with subprocess.Popen([args.seven_zip, 'x', '-so', str(args.iso), path],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
            digest = hashlib.sha256()
            length = 0
            while block := proc.stdout.read(1024 * 1024):
                digest.update(block)
                length += len(block)
            error = proc.stderr.read()
            if proc.wait() != 0:
                raise RuntimeError(f'ISO extraction failed for {path}: {error!r}')
        if length != int(size) or digest.hexdigest() != actual:
            raise RuntimeError(f'Native and independent ISO reads differ: {path}')
        print(f'PASS {path}: {length} bytes, SHA256={actual}', flush=True)


if __name__ == '__main__':
    main()
