"""CSMWrap prototype: boot an XP disk prepared by the USOS XP package under
OVMF (UEFI, no CSM) through CSMWrap, the design of
docs/design/csmwrap-integration.md (target-side ESP).

The prepared disk (phase 1 of run_seabios_xp_uefi_csm_textmode.py:
MBR, one active NTFS partition from LBA 2048, $WIN_NT$.~BT) is only read:
the script puts a qcow2 overlay on it, grows the overlay by 32 MiB and adds
MBR partition 2 (type 0xEF) holding a FAT16 ESP with
EFI/BOOT/BOOTX64.EFI = the pinned CSMWrap and EFI/BOOT/csmwrap.ini.

  before: OVMF + the overlay WITHOUT the ESP  -> no UEFI boot option
  after:  OVMF + the overlay WITH the ESP     -> CSMWrap -> SeaBIOS CSM ->
          disk MBR -> NTFS -> SETUPLDR -> XP text-mode Setup

  python tools/tests/legacy_bios/run_csmwrap_xp_ovmf.py --output zig-out/csmwrap-xp-ovmf \
      --prepared zig-out/xp-uefi-textmode-en-v5/target.qcow2 [--vga std|bochs-display] [--minutes 12]

Test tool only (not in the release). Disposable images only; no physical disk access.
"""
from pathlib import Path
import argparse, hashlib, json, shutil, struct, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'tools'))
from run_seabios_xp_uefi_csm_textmode import Monitor, free_port, vga_text  # noqa: E402

QEMU = ROOT / 'tools/qemu/qemu-system-x86_64.exe'
QEMU_IMG = ROOT / 'tools/qemu/qemu-img.exe'
OVMF_CODE = ROOT / 'tools/qemu/share/edk2-x86_64-code.fd'
OVMF_VARS = ROOT / 'tools/qemu/share/edk2-i386-vars.fd'
CSMWRAP_DIR = ROOT / 'tools/vendor/csmwrap/3.1.2-usos3'  # the release binary (1.1; 1.0 shipped 3.1.2-usos1)

SECTOR = 512
ESP_SECTORS = 65536          # 32 MiB FAT16
SPC = 4                      # 2 KiB clusters -> ~16k clusters (FAT16 range)
RESERVED = 4
ROOT_ENTRIES = 512


def _name83(name):
    base, _, ext = name.upper().partition('.')
    return (base.ljust(8)[:8] + ext.ljust(3)[:3]).encode('ascii')


def _dirent(name83, attr, cluster, size):
    # Fixed timestamp 2026-01-01 00:00 keeps the image deterministic.
    date = ((2026 - 1980) << 9) | (1 << 5) | 1
    return struct.pack('<11sBBBHHHHHHHI', name83, attr, 0, 0, 0, date, date, 0, 0, date, cluster, size)


def build_fat16(files, hidden_sectors):
    """files: {'EFI/BOOT/BOOTX64.EFI': bytes}. Returns the partition image."""
    fat_sectors = (ESP_SECTORS // SPC * 2 + SECTOR - 1) // SECTOR + 1
    root_sectors = ROOT_ENTRIES * 32 // SECTOR
    data_start = RESERVED + 2 * fat_sectors + root_sectors
    csize = SPC * SECTOR
    nclusters = (ESP_SECTORS - data_start) // SPC
    assert 4085 <= nclusters < 65525
    fat = [0xFFF8, 0xFFFF]
    data = bytearray()

    def alloc(payload):
        n = max(1, (len(payload) + csize - 1) // csize)
        first = len(fat)
        for i in range(n):
            fat.append(first + i + 1 if i < n - 1 else 0xFFFF)
        data.extend(payload.ljust(n * csize, b'\0'))
        return first

    # Directory tree: dirs are allocated after their children's content is known,
    # so build bottom-up with placeholder parents fixed afterwards.
    tree = {}
    for path, blob in files.items():
        parts = path.split('/')
        node = tree
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        node[parts[-1]] = blob

    def write_dir(node, parent_cluster):
        # Reserve the directory cluster first so '.' can point at it.
        me = alloc(b'\0' * csize)
        entries = [_dirent(b'.          ', 0x10, me, 0), _dirent(b'..         ', 0x10, parent_cluster, 0)]
        for name, val in sorted(node.items()):
            if isinstance(val, dict):
                entries.append(_dirent(_name83(name), 0x10, write_dir(val, me), 0))
            else:
                entries.append(_dirent(_name83(name), 0x20, alloc(val), len(val)))
        blob = b''.join(entries)
        assert len(blob) <= csize
        off = (me - 2) * csize
        data[off:off + len(blob)] = blob
        return me

    root = []
    for name, val in sorted(tree.items()):
        if isinstance(val, dict):
            root.append(_dirent(_name83(name), 0x10, write_dir(val, 0), 0))
        else:
            root.append(_dirent(_name83(name), 0x20, alloc(val), len(val)))
    root.insert(0, struct.pack('<11sB20s', b'CSMWRAP-ESP', 0x08, b'\0' * 20))
    assert len(fat) - 2 <= nclusters

    bs = bytearray(SECTOR)
    bs[0:3] = b'\xeb\x3c\x90'
    bs[3:11] = b'USOSCSMW'
    struct.pack_into('<HBHBHHBHHHII', bs, 11, SECTOR, SPC, RESERVED, 2, ROOT_ENTRIES, 0, 0xF8,
                     fat_sectors, 63, 255, hidden_sectors, ESP_SECTORS)
    struct.pack_into('<BBBI11s8s', bs, 36, 0x80, 0, 0x29, 0x55534F53, b'CSMWRAP-ESP', b'FAT16   ')
    # Not BIOS-bootable on purpose: int 18h hands control back to the BIOS.
    bs[0x3E:0x43] = b'\xcd\x18\xf4\xeb\xfd'
    bs[510:512] = b'\x55\xaa'
    fat_bytes = struct.pack('<%dH' % len(fat), *fat).ljust(fat_sectors * SECTOR, b'\0')
    img = bytearray(ESP_SECTORS * SECTOR)
    img[0:SECTOR] = bs
    o = RESERVED * SECTOR
    img[o:o + len(fat_bytes)] = fat_bytes
    img[o + len(fat_bytes):o + 2 * len(fat_bytes)] = fat_bytes
    r = (RESERVED + 2 * fat_sectors) * SECTOR
    rb = b''.join(root)
    img[r:r + len(rb)] = rb
    d = data_start * SECTOR
    img[d:d + len(data)] = data
    return bytes(img)


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


def make_overlay(prepared, path, esp, ini, efi_path=None):
    path.unlink(missing_ok=True)
    run([QEMU_IMG, 'create', '-q', '-f', 'qcow2', '-F', 'qcow2', '-b', prepared.resolve(), path])
    if not esp:
        return
    size = int(json.loads(subprocess.run([str(QEMU_IMG), 'info', '--output=json', str(prepared)],
                                         capture_output=True, check=True, text=True).stdout)['virtual-size'])
    start = size // SECTOR
    run([QEMU_IMG, 'resize', '-q', path, str(size + ESP_SECTORS * SECTOR)])
    mbr_file = path.with_suffix('.mbr')
    mbr_file.unlink(missing_ok=True)
    run([QEMU_IMG, 'dd', '-f', 'qcow2', '-O', 'raw', f'if={path}', f'of={mbr_file}', 'bs=512', 'count=1'])
    mbr = bytearray(mbr_file.read_bytes())
    assert mbr[510:512] == b'\x55\xaa'
    assert mbr[446 + 16:446 + 32] == b'\0' * 16, 'partition slot 2 is not free'
    mbr[446 + 16:446 + 32] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0xEF, b'\xfe\xff\xff', start, ESP_SECTORS)
    mbr_file.write_bytes(mbr)
    if efi_path is None:
        efi = (CSMWRAP_DIR / 'csmwrapx64.efi').read_bytes()
        pinned = json.loads((CSMWRAP_DIR / 'manifest.json').read_text())['files']['csmwrapx64.efi']
        assert hashlib.sha256(efi).hexdigest() == pinned, 'CSMWrap binary does not match manifest'
    else:
        efi = efi_path.read_bytes()
    print('[ESP] CSMWrap', efi_path or 'pinned 3.1.2-usos3', hashlib.sha256(efi).hexdigest(), flush=True)
    part = path.with_suffix('.esp')
    part.write_bytes(build_fat16({'EFI/BOOT/BOOTX64.EFI': efi, 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, start))
    # qemu-io 'write -s' reads its pattern file in text mode on Windows (stops at
    # 0x1A), so write through a raw offset/size window over the qcow2 instead.
    write_window(path, mbr_file, 0, SECTOR)
    write_window(path, part, start * SECTOR, ESP_SECTORS * SECTOR)
    part.unlink()
    mbr_file.unlink()


def write_window(qcow2, src, offset, size):
    opts = (f'driver=raw,offset={offset},size={size},file.driver=qcow2,'
            f'file.file.driver=file,file.file.filename={qcow2.as_posix()}')
    run([QEMU_IMG, 'convert', '-n', '-f', 'raw', src, '--target-image-opts', opts])


def to_png(ppm):
    try:
        from PIL import Image
        png = ppm.with_suffix('.png')
        Image.open(ppm).save(png)
        ppm.unlink()
        return png
    except Exception:
        return ppm



USB_ONLY = ['-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0', '-device', 'usb-tablet,bus=xhci.0']


def usb_input(mon, shots, tag):
    """Pointer through the USB tablet only (selected with mouse_set: an
    absolute move lands only when the guest's xHCI + HID stack runs) and keys
    (HMP sendkey goes to QEMU's active keyboard). The 8042 stays present:
    the X470 has one, and NTDETECT hangs without any keyboard controller."""
    mice = mon.query('info mice')
    (shots / (tag + '-mice.txt')).write_text(mice, encoding='utf-8')
    for line in mice.splitlines():
        if 'Tablet' in line and 'Mouse #' in line:
            mon.cmd('mouse_set ' + line.split('Mouse #')[1].split(':')[0].strip())
    mon.cmd(f'screendump "{(shots / (tag + "-before.ppm")).as_posix()}"')
    for key in ('q', 'w', 'e', 'r', 't', '1', '2', '3'):
        mon.cmd('sendkey ' + key)
        time.sleep(0.3)
    time.sleep(2)
    mon.cmd(f'screendump "{(shots / (tag + "-typed.ppm")).as_posix()}"')
    for x, y in ((100, 100), (500, 400), (320, 240)):
        mon.cmd(f'mouse_move {x} {y}')
        time.sleep(0.5)
    time.sleep(1)
    mon.cmd(f'screendump "{(shots / (tag + "-pointer.ppm")).as_posix()}"')


def boot(out, disk, tag, vga, accel, minutes, shots_every=3.0, run_through=False, usb_only=False, ahci=False, type_at=()):
    shots = out / tag
    shutil.rmtree(shots, ignore_errors=True)
    shots.mkdir(parents=True)
    vars_copy = shots / 'vars.fd'
    shutil.copyfile(OVMF_VARS, vars_copy)
    port = free_port()
    serial = shots / 'serial.log'
    cmd = [QEMU, '-machine', 'pc', '-accel', accel, '-cpu', 'max', '-m', '1024', '-smp', '2',
           '-drive', f'if=pflash,unit=0,format=raw,readonly=on,file={OVMF_CODE}',
           '-drive', f'if=pflash,unit=1,format=raw,file={vars_copy}',
           '-display', 'none', '-nic', 'none', '-serial', f'file:{serial}',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off',
           *(['-device', 'ahci,id=ahci', '-drive', f'if=none,id=target,format=qcow2,file={disk}', '-device', 'ide-hd,drive=target,bus=ahci.0']
             if ahci else ['-drive', f'if=ide,index=0,format=qcow2,file={disk}'])]
    cmd += ['-vga', 'std'] if vga == 'std' else ['-vga', 'none', '-device', vga]
    cmd += USB_ONLY if usb_only else []
    pending = sorted(type_at)
    proc = subprocess.Popen([str(c) for c in cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    events, last, result = [], None, 'timeout'
    start = time.time()
    try:
        time.sleep(1.0)
        mon = Monitor(port)
        n = frame = 0
        last_shot = 0.0
        while time.time() - start < minutes * 60 and proc.poll() is None:
            dump = shots / 'cur.bin'
            dump.unlink(missing_ok=True)
            mon.cmd(f'pmemsave 0xb8000 8000 "{dump.as_posix()}"')
            for _ in range(20):
                if dump.exists() and dump.stat().st_size == 8000:
                    break
                time.sleep(0.05)
            text = vga_text(dump, 50) if dump.exists() else ''
            now = round(time.time() - start, 1)
            if text.strip() and text != last and any(c.isalpha() for c in text):
                n += 1
                last = text
                ppm = shots / ('text-%03d.ppm' % n)
                mon.cmd(f'screendump "{ppm.as_posix()}"')
                (shots / ('text-%03d.txt' % n)).write_text(text, encoding='utf-8')
                events.append({'n': n, 't': now, 'text': text})
                print(f'--- {tag} screen {n} at {now}s ---\n{text.strip()[:400]}\n', flush=True)
            if time.time() - last_shot >= shots_every:
                last_shot = time.time()
                frame += 1
                mon.cmd(f'screendump "{(shots / ("frame-%03d.ppm" % frame)).as_posix()}"')
            while pending and time.time() - start >= pending[0]:
                usb_input(mon, shots, 'usb-%d' % int(pending.pop(0)))
            low = text.lower()
            if ('copying files' in low or 'kopiuje pliki' in low) and '%' in low and result != 'copying':
                result = 'copying'
                if not run_through:
                    time.sleep(2)
                    mon.cmd(f'screendump "{(shots / "final.ppm").as_posix()}"')
                    break
            time.sleep(0.5)
        else:
            try:
                mon.cmd(f'screendump "{(shots / "final.ppm").as_posix()}"')
            except Exception:
                pass
    finally:
        try:
            mon.cmd('quit')
        except Exception:
            pass
        try:
            proc.wait(10)
        except Exception:
            proc.kill()
    time.sleep(0.5)
    for ppm in sorted(shots.glob('*.ppm')):
        to_png(ppm)
    (shots / 'cur.bin').unlink(missing_ok=True)
    vars_copy.unlink(missing_ok=True)
    summary = {'tag': tag, 'result': result, 'seconds': round(time.time() - start, 1), 'vga': vga,
               'accel': accel, 'usb_only': usb_only, 'ahci': ahci, 'type_at': list(type_at), 'events': events}
    (shots / 'result.json').write_text(json.dumps(summary, indent=1, ensure_ascii=False), encoding='utf-8')
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--prepared', type=Path, required=True, help='disk prepared by run_seabios_xp_uefi_csm_textmode.py')
    p.add_argument('--vga', default='std', help="'std' (vgabios-stdvga OpROM) or a -device name such as bochs-display")
    p.add_argument('--accel', default='tcg,thread=multi')
    p.add_argument('--minutes', type=float, default=12)
    p.add_argument('--before-minutes', type=float, default=1.0)
    p.add_argument('--skip-before', action='store_true')
    p.add_argument('--run-through', action='store_true', help='keep running after text-mode copying (reboots, GUI Setup); frames every 20 s')
    p.add_argument('--csmwrap-efi', type=Path, help='CSMWrap binary to test instead of the pinned 3.1.2-usos3 (e.g. tools/vendor/csmwrap/3.1.2/csmwrapx64.efi, upstream)')
    p.add_argument('--verbose', choices=('true', 'false'), default='true', help='csmwrap.ini verbose value')
    p.add_argument('--tag', default='', help='suffix of the after-* screenshot folder')
    p.add_argument('--shots-every', type=float, default=0, help='seconds between frame-*.png (default 3, 20 with --run-through; 0.2 catches the CSMWrap screen)')
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ini = f'serial = true\nserial_port = 0x3f8\nverbose = {a.verbose}\n'
    results = {}
    if not a.skip_before:
        before = out / 'before.qcow2'
        make_overlay(a.prepared, before, esp=False, ini=ini)
        results['before'] = boot(out, before, 'before', a.vga, a.accel, a.before_minutes)
    after = out / 'after.qcow2'
    make_overlay(a.prepared, after, esp=True, ini=ini, efi_path=a.csmwrap_efi)
    results['after'] = boot(out, after, 'after-' + a.vga.split(',')[0] + ('-norom' if 'romfile=' in a.vga else '') + a.tag, a.vga, a.accel, a.minutes,
                             shots_every=a.shots_every or (20.0 if a.run_through else 3.0), run_through=a.run_through)
    print(json.dumps(results))
    return 0 if results['after'] == 'copying' else 1


if __name__ == '__main__':
    sys.exit(main())
