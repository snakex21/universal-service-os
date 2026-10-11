"""Where does NT6 Setup put its boot files when BIOS drive 0x80 is a disk
Windows cannot see (the RAM-disk boot of csmwrap-integration 13.5)?

QEMU legacy SeaBIOS (no UEFI: only BIOS drive numbering matters here):
  CD       the Windows ISO, booted first (bootindex 0)
  0x80     virtio-blk, 64 MiB, MBR with a signature: SeaBIOS maps it first,
           Windows (no virtio driver in Setup) never sees it - the stand-in
           for the INT 13h RAM disk
  0x81     decoy: port 0 of the AHCI controller, MBR with an ACTIVE NTFS-type
           partition (Windows disk 0)
  0x82     target: port 1, blank (Windows disk 1) - the user picks it
  floppy   autounattend.xml (language + EULA only: Setup shows its disk page)

The script drives the pages with sendkey and screenshots each step, stops at
Setup's first reboot (-no-reboot) and reports: decoy / 0x80 disk
byte-identical?, target partition table (active flag, System Reserved).

  python tools/tests/legacy_bios/run_setup_system_disk_probe.py --iso <x86 iso> --output zig-out/sysdisk-win7 \
      [--edition-key KEY] [--accel whpx]

Test tool only; disposable images; media read-only.
"""
from pathlib import Path
import argparse, hashlib, json, os, socket, struct, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[3]
QEMU = ROOT / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
QEMU_IMG = ROOT / 'tools/qemu/qemu-img.exe'

UNATTEND = """<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="x86" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>pl-PL</UILanguage></SetupUILanguage>
      <InputLocale>0415:00000415</InputLocale><SystemLocale>pl-PL</SystemLocale><UILanguage>pl-PL</UILanguage><UserLocale>pl-PL</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="x86" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData><AcceptEula>true</AcceptEula>{key}</UserData>
    </component>
  </settings>
</unattend>
"""


class Monitor:
    def __init__(self, port):
        for _ in range(50):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=5)
                break
            except OSError:
                time.sleep(0.2)
        self.s.settimeout(2)
        self._drain()

    def _drain(self):
        try:
            while self.s.recv(65536):
                pass
        except OSError:
            pass

    def cmd(self, c):
        self.s.sendall((c + '\n').encode())
        time.sleep(0.3)
        self._drain()


def mbr(signature: int, active: bool, ptype: int) -> bytes:
    m = bytearray(512)
    m[0:2] = b'\xeb\xfe'  # jmp $ (never run: the CD boots)
    struct.pack_into('<I', m, 440, signature)
    m[446:462] = struct.pack('<B3sB3sII', 0x80 if active else 0, b'\xfe\xff\xff', ptype, b'\xfe\xff\xff', 2048, 2048 * 1024)
    m[510:512] = b'\x55\xaa'
    return bytes(m)


def raw_disk(path: Path, size: int, first: bytes):
    with open(path, 'wb') as f:
        f.truncate(size)
        f.write(first)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def partitions(path: Path):
    m = path.open('rb').read(512)
    out = []
    for i in range(4):
        e = m[446 + 16 * i:462 + 16 * i]
        if e[4]:
            out.append({'slot': i + 1, 'active': e[0] == 0x80, 'type': hex(e[4]),
                        'start': struct.unpack_from('<I', e, 8)[0], 'sectors': struct.unpack_from('<I', e, 12)[0]})
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--iso', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--edition-key', default='')
    p.add_argument('--accel', default='tcg,thread=multi')
    p.add_argument('--minutes', type=float, default=150)
    p.add_argument('--decoy', choices=('active', 'blank', 'none'), default='active', help='blank: an all-zero second disk (no MBR)')
    p.add_argument('--target-index', type=int, default=1, help='down presses on the disk page (1 = Windows disk 1)')
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    flop = out / 'floppy'
    flop.mkdir(exist_ok=True)
    key = f'<ProductKey><Key>{a.edition_key}</Key><WillShowUI>OnError</WillShowUI></ProductKey>' if a.edition_key else ''
    (flop / 'autounattend.xml').write_text(UNATTEND.replace('{key}', key), encoding='utf-8')
    ram, decoy, target = out / 'ramdisk-standin.img', out / 'decoy.img', out / 'target.qcow2'
    raw_disk(ram, 64 << 20, mbr(0x52414D44, True, 0x07))     # "RAMD"
    raw_disk(decoy, 2 << 30, mbr(0x44454359, True, 0x07) if a.decoy == 'active' else b'')  # "DECY"
    target.unlink(missing_ok=True)
    subprocess.run([str(QEMU_IMG), 'create', '-q', '-f', 'qcow2', str(target), '40G'], check=True)
    before = {'ram': digest(ram), 'decoy': digest(decoy)}
    port = free = None
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    accel = ['-accel', a.accel] + (['-cpu', 'qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt'] if a.accel.startswith('whpx') else ['-cpu', 'max'])
    cmd = [str(QEMU), '-name', 'USOS-sysdisk-probe', '-machine', 'pc', *accel, '-smp', '2', '-m', '2048',
           '-display', 'none', '-no-reboot', '-vga', 'std', '-nic', 'none',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=none,id=cd,media=cdrom,readonly=on,file={a.iso.as_posix()}', '-device', 'ide-cd,drive=cd,bus=ide.1,bootindex=0',
           '-drive', f'if=none,id=ram,format=raw,cache=writeback,file={ram.as_posix()}', '-device', 'virtio-blk-pci,drive=ram,bootindex=1',
           '-device', 'ahci,id=sata',
           *([] if a.decoy == 'none' else ['-drive', f'if=none,id=decoy,format=raw,cache=writeback,file={decoy.as_posix()}', '-device', 'ide-hd,bus=sata.0,drive=decoy,bootindex=2']),
           '-drive', f'if=none,id=target,format=qcow2,cache=writeback,file={target.as_posix()}', '-device', 'ide-hd,bus=sata.1,drive=target,bootindex=3',
           '-drive', f'if=floppy,format=raw,readonly=on,file=fat:floppy:{flop.as_posix()}']
    print(' '.join(cmd), flush=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    print(f'[QEMU] pid={proc.pid}', flush=True)
    (out / 'pid.txt').write_text(str(proc.pid))
    mon = Monitor(port)
    shots = out / 'shots'
    shots.mkdir(exist_ok=True)

    def shot(name):
        mon.cmd(f'screendump "{(shots / (name + ".ppm")).as_posix()}"')

    start = time.time()
    # Driven step by step by the operator through control files: the script
    # polls out/keys.txt (one monitor command per line) and executes new lines,
    # and takes a screenshot every 30 s (shots/t-<sec>.ppm, last.ppm).
    keys_file, done = out / 'keys.txt', 0
    keys_file.write_text('')
    try:
        # cdboot asks "Press any key to boot from CD" because 0x80 holds an MBR.
        while time.time() - start < 25:
            mon.cmd('sendkey spc')
            time.sleep(1.2)
        while proc.poll() is None and time.time() - start < a.minutes * 60:
            lines = keys_file.read_text().splitlines()
            for line in lines[done:]:
                if line.strip():
                    mon.cmd(line.strip())
            done = len(lines)
            t = int(time.time() - start)
            shot('last')
            if t % 30 < 3:
                shot(f't-{t:05d}')
            time.sleep(3)
    finally:
        if proc.poll() is None:
            proc.kill()  # own PID only
        proc.wait()
    after = {'ram': digest(ram), 'decoy': digest(decoy)}
    raw = out / 'target-head.bin'
    raw.unlink(missing_ok=True)
    subprocess.run([str(QEMU_IMG), 'dd', '-f', 'qcow2', '-O', 'raw', f'if={target}', f'of={raw}', 'bs=512', 'count=1'], check=True)
    result = {'exit': proc.returncode, 'seconds': int(time.time() - start),
              'ramdisk_standin_unchanged': before['ram'] == after['ram'],
              'decoy_unchanged': before['decoy'] == after['decoy'],
              'decoy_partitions': partitions(decoy), 'target_partitions': partitions(raw)}
    (out / 'result.json').write_text(json.dumps(result, indent=1))
    print(json.dumps(result, indent=1), flush=True)


if __name__ == '__main__':
    main()
