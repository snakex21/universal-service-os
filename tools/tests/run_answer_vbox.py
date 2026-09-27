"""Install Windows in a throw-away VirtualBox VM with an autounattend.xml
rendered from a USOS answer profile (docs/answer-profiles.md).

  python tools/tests/run_answer_vbox.py prepare --iso WIN.iso --system windows-10 --arch x86 --key GENERIC-KEY
  python tools/tests/run_answer_vbox.py destroy

prepare: renders src/flow/answer/testdata/vbox.profile.ini with
zig-out/bin/usos-answer, writes it as Autounattend.xml on a 1.44 MiB FAT12
floppy (long file name entry; Setup searches removable media roots) and
creates the VM usos-test-answer (BIOS, SATA, empty 40 GB disk, the ISO, the
floppy, no network). Then run
  python tools/tests/legacy_bios/run_xp_vbox.py boot --name usos-test-answer --output DIR
and steer it with DIR/control.txt (key:1c 9c = Enter). The key is only
passed on the command line (a Microsoft generic installation key for the
edition); it is written to the floppy under zig-out, never to the repo.
The disk page must appear (manual disk selection kept); everything else
(language, key, EULA, OOBE, account) must be answered by the file.
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VBOX = Path(r'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe')
NAME = 'usos-test-answer'
WORK = ROOT / 'zig-out' / 'answer-vbox'


def vbox(*args, check=True):
    r = subprocess.run([str(VBOX), *map(str, args)], capture_output=True, text=True, errors='replace')
    if check and r.returncode != 0:
        raise SystemExit(f'VBoxManage {" ".join(map(str, args))} failed:\n{r.stdout}\n{r.stderr}')
    return r


def lfn_entries(long_name: str, short: bytes) -> list[bytes]:
    checksum = 0
    for b in short:
        checksum = (((checksum & 1) << 7) + (checksum >> 1) + b) & 0xff
    units = [ord(c) for c in long_name] + [0]
    units += [0xffff] * (-len(units) % 13)
    parts = [units[i:i + 13] for i in range(0, len(units), 13)]
    out = []
    for index, part in enumerate(parts, 1):
        e = bytearray(32)
        e[0] = index | (0x40 if index == len(parts) else 0)
        e[1:11] = struct.pack('<5H', *part[0:5])
        e[11] = 0x0f
        e[13] = checksum
        e[14:26] = struct.pack('<6H', *part[5:11])
        e[28:32] = struct.pack('<2H', *part[11:13])
        out.append(bytes(e))
    return list(reversed(out))


def floppy(files: dict[str, bytes]) -> bytes:
    """1.44 MiB FAT12 image, root directory only, long names."""
    image = bytearray(1474560)
    boot = bytearray(512)
    boot[0:3] = b'\xeb\x3c\x90'
    boot[3:11] = b'USOS    '
    struct.pack_into('<HBHBHHBHHHLL', boot, 11, 512, 1, 1, 2, 224, 2880, 0xf0, 9, 18, 2, 0, 0)
    boot[36] = 0
    boot[38] = 0x29
    boot[39:43] = b'\x55\x05\x05\x05'
    boot[43:54] = b'USOSANSWER '
    boot[54:62] = b'FAT12   '
    boot[510:512] = b'\x55\xaa'
    image[0:512] = boot
    fat = bytearray(9 * 512)
    fat[0:3] = b'\xf0\xff\xff'

    def set_fat(cluster, value):
        offset = cluster * 3 // 2
        if cluster & 1:
            fat[offset] = (fat[offset] & 0x0f) | ((value << 4) & 0xf0)
            fat[offset + 1] = (value >> 4) & 0xff
        else:
            fat[offset] = value & 0xff
            fat[offset + 1] = (fat[offset + 1] & 0xf0) | ((value >> 8) & 0x0f)

    root = bytearray()
    cluster = 2
    for index, (name, data) in enumerate(files.items()):
        stem, _, ext = name.upper().partition('.')
        short = (stem[:6] + '~' + str(index + 1)).ljust(8)[:8].encode() + ext[:3].ljust(3).encode()
        for entry in lfn_entries(name, short):
            root += entry
        clusters = max(1, -(-len(data) // 512))
        e = bytearray(32)
        e[0:11] = short
        e[11] = 0x20
        struct.pack_into('<HH', e, 22, 0, 0x5b3a)  # 2025-09-26
        struct.pack_into('<H', e, 26, cluster)
        struct.pack_into('<L', e, 28, len(data))
        root += e
        for i in range(clusters):
            set_fat(cluster + i, 0xfff if i == clusters - 1 else cluster + i + 1)
        start = (33 + cluster - 2) * 512
        image[start:start + len(data)] = data
        cluster += clusters
    assert len(root) <= 224 * 32
    image[512:512 + len(fat)] = fat
    image[512 + len(fat):512 + 2 * len(fat)] = fat
    image[19 * 512:19 * 512 + len(root)] = root
    return bytes(image)


def prepare(a) -> int:
    WORK.mkdir(parents=True, exist_ok=True)
    tool = ROOT / 'zig-out' / 'bin' / 'usos-answer.exe'
    subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'build', '--cache-dir', str(ROOT / 'tools/cache/zig'), 'answer-tool'], check=True, cwd=ROOT)
    xml = WORK / 'Autounattend.xml'
    profile = ROOT / 'src/flow/answer/testdata/vbox.profile.ini'
    if a.edition:
        # The same profile with an edition (docs/answer-profiles.md "Edition").
        edited = WORK / 'vbox-edition.profile.ini'
        edited.write_bytes(profile.read_bytes().rstrip() + ('\r\nedition=' + a.edition + '\r\n').encode())
        profile = edited
    render = [str(tool), 'render', str(profile), a.system, a.arch, str(xml), a.key or '-']
    if a.install_xml:
        render.append(str(Path(a.install_xml).resolve()))
    subprocess.run(render, check=True, cwd=ROOT)
    (WORK / 'answer.img').write_bytes(floppy({'Autounattend.xml': xml.read_bytes()}))
    if vbox('showvminfo', NAME, check=False).returncode == 0:
        raise SystemExit('VM exists already: ' + NAME)
    base = WORK / 'vm'
    family = {'windows-7': 'Windows7', 'windows-vista': 'WindowsVista'}.get(a.system, 'Windows10')
    vbox('createvm', '--name', NAME, '--ostype', family if a.arch == 'x86' else family + '_64', '--basefolder', base, '--register')
    folder = base / NAME
    vbox('modifyvm', NAME, '--memory', a.memory, '--cpus', '2', '--firmware', 'bios', '--ioapic', 'on', '--pae', 'on', '--acpi', 'on',
         '--nic1', 'none', '--audio-enabled', 'off', '--usb-ohci', 'off', '--graphicscontroller', 'vboxsvga', '--vram', '64',
         '--boot1', 'disk', '--boot2', 'dvd', '--boot3', 'none', '--boot4', 'none', '--rtc-use-utc', 'on')
    vbox('storagectl', NAME, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', '2')
    vbox('storagectl', NAME, '--name', 'IDE', '--add', 'ide', '--controller', 'PIIX4')
    vbox('storagectl', NAME, '--name', 'Floppy', '--add', 'floppy')
    disk = folder / 'disk0.vdi'
    vbox('createmedium', 'disk', '--filename', disk, '--size', '40960', '--format', 'VDI')
    vbox('storageattach', NAME, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', disk)
    vbox('storageattach', NAME, '--storagectl', 'IDE', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', Path(a.iso).resolve())
    vbox('storageattach', NAME, '--storagectl', 'Floppy', '--port', '0', '--device', '0', '--type', 'fdd', '--medium', WORK / 'answer.img')
    print('[PASS] prepared', NAME, 'answer', xml)
    return 0


def destroy(_a) -> int:
    if vbox('showvminfo', NAME, check=False).returncode != 0:
        print('no VM', NAME)
        return 0
    vbox('controlvm', NAME, 'poweroff', check=False)
    subprocess.run(['timeout', '/t', '3'], capture_output=True, shell=True)
    vbox('storageattach', NAME, '--storagectl', 'IDE', '--port', '1', '--device', '0', '--medium', 'none', check=False)
    vbox('storageattach', NAME, '--storagectl', 'Floppy', '--port', '0', '--device', '0', '--medium', 'none', check=False)
    vbox('closemedium', 'floppy', WORK / 'answer.img', check=False)
    vbox('unregistervm', NAME, '--delete-all')
    print('[PASS] destroyed', NAME)
    return 0


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('prepare')
    c.add_argument('--iso', required=True)
    c.add_argument('--system', default='windows-10')
    c.add_argument('--arch', default='x86')
    c.add_argument('--key', default='', help='generic installation key; empty: none (Setup asks)')
    c.add_argument('--memory', default='3072')
    c.add_argument('--edition', default='', help='edition= for the profile (matched against --install-xml)')
    c.add_argument('--install-xml', default='', help="the ISO's install.wim XML metadata (UTF-16LE)")
    sub.add_parser('destroy')
    a = p.parse_args()
    sys.exit({'prepare': prepare, 'destroy': destroy}[a.cmd](a))
