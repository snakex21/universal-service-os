"""QEMU test helper (docs/win9x-modern-2026-09-30.md): the Windows 9x boot
logo hangs QEMU's i440FX in SeaBIOS SMM. Writes Logo=0 into MSDOS.SYS of the
first FAT partition of a raw test disk, in place (the first ";xxx...a"
padding line is replaced, the file size stays), so Me (whose Setup writes its
own MSDOS.SYS) can be tested. Test disks only.

  python win9x_logo_off.py DISK.raw
"""
import re, sys
from fat32_read import Fat


def main():
    fs = Fat(sys.argv[1])
    cluster, _, size = fs.find('MSDOS.SYS')
    offset = fs.data + (cluster - 2) * fs.csize
    if size > fs.csize:
        raise SystemExit('MSDOS.SYS spans clusters')
    data = bytearray(fs.read(offset, size))
    if re.search(rb'(?im)^logo=0', data):
        print('Logo=0 already set')
        return
    m = re.search(rb';x+a\r\n', data)
    if not m or b'[Options]' not in data:
        raise SystemExit('unexpected MSDOS.SYS layout')
    line = b'Logo=0\r\n'
    pad = (m.end() - m.start()) - len(line) - 2
    data[m.start():m.end()] = line + b';' + b'x' * (pad - 1) + b'\r\n'
    with open(sys.argv[1], 'r+b') as f:
        f.seek(offset)
        f.write(data)
    print('Logo=0 written')


if __name__ == '__main__':
    main()
