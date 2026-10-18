"""USB mouse for DOS programs under CSMWrap (docs/dos-mouse-2026-10-18.md):
FreeDOS boots from an NVMe disk through CSMWrap (OVMF without CSM, no i8042,
like the X470), VBADOS VBMOUSE.EXE (the INT 33h driver USOS stages for DOS
sessions) reads the USB mouse through SeaBIOS's PS/2 BIOS services (INT 15h
C2xxh), and M33TEST.COM (m33test.S) shows the INT 33h state on screen.

  MBR   USOS MBR code (zig-out/xp-geometry-fix-mbr), slot 1 FAT16 C:, slot 2
        the CSMWrap ESP (as run_nvme_freedos_probe.py)
  C:    FreeDOS 1.4 kernel + FreeCOM, VBMOUSE.EXE, M33TEST.COM, AUTOEXEC.BAT
  USB   qemu-xhci with usb-kbd and usb-mouse (relative), vmport=off
The monitor moves the mouse (mouse_move) and clicks (mouse_button). PASS when
INT 33h reports the driver (AX=FFFFh), X and Y follow the moves (right/down,
then back left/up) and the left press count grows after a click.
--wheel (with --csmwrap pointing at a build with patch 0016-usb-mouse-wheel):
also the INT 33h wheel API (AX=0011h: 574Dh, CX bit 0) and the AX=0003h
wheel count (BH) after mouse_move 0 0 dz: dz > 0 (QEMU wheel up) must give
a negative sum (CuteMouse convention: up negative), dz < 0 positive. Without
--wheel the probe also checks that no wheel shows up (an older CSMWrap).

--mode session (default): AUTOEXEC loads VBMOUSE and runs M33TEST (the
FreeDOS / MS-DOS RAM session wiring: FDAUTO.BAT, LIVE.BAT).
--mode dosmouse: the Windows 9x MS-DOS mode wrapper. C:\\USOS9X holds
DOSMOUSE.BAT (src/platform/bios/win9x/dosmouse.cmd), INWIN.COM (inwin.S) and
VBMOUSE.EXE; AUTOEXEC CALLs DOSMOUSE as DOSSTART.BAT does. The probe types
M33TEST at DOSMOUSE's nested prompt (USB keyboard), checks the mouse, types
EXIT and then expects "Driver uninstalled" and INT 33h gone (M33TEST again
from AUTOEXEC shows I=0000). FreeCOM's EXIT in the primary shell does
nothing, like COMMAND.COM /P at a "Command prompt only" start.

  python tools/tests/legacy_bios/run_dos_mouse_probe.py --output DIR [--mode dosmouse] [--keep]
      [--csmwrap EFI] [--wheel]

USOS_BUILD_ROOT: a checkout whose zig-out has the MBR code (and tools/zig,
tools/qemu when this checkout has none). USOS_QEMU_EXE selects a renamed QEMU
copy in tools/qemu. Disposable images only (deleted unless --keep); no
physical disk access.
"""
from pathlib import Path
import argparse, os, re, struct, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_csmwrap_xp_ovmf import build_fat16, ESP_SECTORS  # noqa: E402
from run_seabios_xp_uefi_csm_textmode import Monitor, free_port, vga_text  # noqa: E402
from run_nvme_freedos_probe import mbr_code  # noqa: E402


def tool_root() -> Path:
    for base in (ROOT, Path(os.environ.get('USOS_BUILD_ROOT', ROOT))):
        if (base / 'tools/zig/zig.exe').is_file() and (base / 'tools/qemu').is_dir():
            return base
    raise SystemExit('tools/zig and tools/qemu missing (set USOS_BUILD_ROOT to a checkout with toolchains)')


TOOLS = tool_root()
QEMU = TOOLS / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
OVMF_CODE = TOOLS / 'tools/qemu/share/edk2-x86_64-code.fd'
OVMF_VARS = TOOLS / 'tools/qemu/share/edk2-i386-vars.fd'
CSMWRAP = ROOT / 'tools/vendor/csmwrap/3.1.2-usos11/csmwrapx64.efi'
FREEDOS = ROOT / 'tools/vendor/freedos/1.4'
VBMOUSE = ROOT / 'tools/vendor/vbados/0.67/VBMOUSE.EXE'
WIN9X = ROOT / 'src/platform/bios/win9x'
SECTOR = 512
C_START, C_SECTORS = 2048, ESP_SECTORS
ESP_START = C_START + C_SECTORS + 2048
TOTAL = ESP_START + ESP_SECTORS + 2048
AFTER = 'USOS-AFTER-DOSMOUSE'
AUTOEXEC = {
    'session': '@echo off\r\nC:\\VBMOUSE.EXE\r\nC:\\M33TEST.COM\r\n',
    'dosmouse': '@echo off\r\nCALL C:\\USOS9X\\DOSMOUSE.BAT\r\necho ' + AFTER + '\r\nC:\\M33TEST.COM\r\n',
}
LINE = re.compile(r'M33 I=([0-9A-F]{4}) N=([0-9A-F]{4}) X=([0-9A-F]{4}) Y=([0-9A-F]{4}) B=([0-9A-F]{4}) P=([0-9A-F]{4})'
                  r' A=([0-9A-F]{4}) C=([0-9A-F]{4}) W=([0-9A-F]{4})')
KEYS = {' ': 'spc', '\n': 'ret', '\\': 'backslash', ':': 'shift-semicolon', '.': 'dot'}


def build_com(source: Path, work: Path) -> bytes:
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(TOOLS / 'tools/cache/zig-global'))
    zig = str(TOOLS / 'tools/zig/zig.exe')
    obj, elf, com = work / (source.stem + '.o'), work / (source.stem + '.elf'), work / (source.stem + '.com')
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c', str(source), '-o', str(obj)],
                   env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    for f in (obj, elf, com):
        f.unlink(missing_ok=True)
    return data


def dos_volume(mode: str, work: Path) -> bytes:
    files = {'KERNEL.SYS': (FREEDOS / 'KERNEL.SYS').read_bytes(), 'COMMAND.COM': (FREEDOS / 'COMMAND.COM').read_bytes(),
             'M33TEST.COM': build_com(Path(__file__).with_name('m33test.S'), work),
             'AUTOEXEC.BAT': AUTOEXEC[mode].encode('ascii')}
    if mode == 'session':
        files['VBMOUSE.EXE'] = VBMOUSE.read_bytes()
    else:
        bat = (WIN9X / 'dosmouse.cmd').read_text(encoding='ascii').replace('\r\n', '\n').replace('\n', '\r\n')
        files.update({'USOS9X/DOSMOUSE.BAT': bat.encode('ascii'), 'USOS9X/INWIN.COM': build_com(WIN9X / 'inwin.S', work),
                      'USOS9X/VBMOUSE.EXE': VBMOUSE.read_bytes()})
    vol = bytearray(build_fat16(files, C_START))
    boot = bytearray((FREEDOS / 'BOOT16.BIN').read_bytes()[:SECTOR])
    boot[0x0B:0x3E] = vol[0x0B:0x3E]
    boot[0x24] = 0x80
    boot[0x2B:0x36] = b'USOS-MOUSE '
    boot[510:512] = b'\x55\xaa'
    vol[0:SECTOR] = boot
    return bytes(vol)


def make_disk(path: Path, mode: str, work: Path, csmwrap: Path = CSMWRAP):
    mbr = bytearray(SECTOR)
    mbr[:440] = mbr_code()
    struct.pack_into('<I', mbr, 440, 0x55534D53)
    mbr[446:462] = struct.pack('<B3sB3sII', 0x80, b'\xfe\xff\xff', 0x06, b'\xfe\xff\xff', C_START, C_SECTORS)
    mbr[462:478] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0xEF, b'\xfe\xff\xff', ESP_START, ESP_SECTORS)
    mbr[510:512] = b'\x55\xaa'
    esp = build_fat16({'EFI/BOOT/BOOTX64.EFI': csmwrap.read_bytes(), 'EFI/BOOT/CSMWRAP.INI': b'serial = false\nverbose = false\n'}, ESP_START)
    with open(path, 'wb') as f:
        f.truncate(TOTAL * SECTOR)
        f.write(mbr)
        f.seek(C_START * SECTOR)
        f.write(dos_volume(mode, work))
        f.seek(ESP_START * SECTOR)
        f.write(esp)


class Screen:
    def __init__(self, mon: Monitor, out: Path):
        self.mon, self.dump = mon, out / 'vga.bin'

    def text(self) -> str:
        self.dump.unlink(missing_ok=True)
        self.mon.cmd(f'pmemsave 0xb8000 4000 "{self.dump.as_posix()}"')
        for _ in range(40):
            if self.dump.exists() and self.dump.stat().st_size == 4000:
                return vga_text(self.dump, 25)
            time.sleep(0.05)
        return ''

    def state(self):
        m = LINE.search(self.text())
        return tuple(int(v, 16) for v in m.groups()) if m else None

    def wait(self, pred, seconds):
        end = time.time() + seconds
        while time.time() < end:
            text = self.text()
            if pred(text):
                return text
            time.sleep(1.5)
        return None


def type_text(mon: Monitor, text: str):
    for ch in text:
        key = KEYS.get(ch) or (('shift-' + ch.lower()) if ch.isupper() else ch)
        mon.cmd('sendkey ' + key)
        time.sleep(0.1)


def mouse_checks(mon: Monitor, scr: Screen, first, log) -> bool:
    for _ in range(6):
        mon.cmd('mouse_move 15 10')
        time.sleep(0.4)
    time.sleep(1.5)
    moved = scr.state()
    log.append(f'after +x+y {moved}')
    for _ in range(3):
        mon.cmd('mouse_move -15 -10')
        time.sleep(0.4)
    time.sleep(1.5)
    back = scr.state()
    log.append(f'after -x-y {back}')
    mon.cmd('mouse_button 1')
    time.sleep(0.6)
    held = scr.state()
    mon.cmd('mouse_button 0')
    time.sleep(1.5)
    clicked = scr.state()
    log.append(f'held {held} released {clicked}')
    return bool(moved and back and held and clicked
                and moved[2] > first[2] and moved[3] > first[3]
                and back[2] < moved[2] and back[3] < moved[3]
                and held[4] & 1 and not clicked[4] & 1 and clicked[5] > first[5])


def signed16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


def wheel_checks(mon: Monitor, scr: Screen, want: bool, log) -> bool:
    """Indices 6..8: A (AX=0011h), C (its CX), W (wheel sum, signed)."""
    before = scr.state()
    for _ in range(3):
        mon.cmd('mouse_move 0 0 1')
        time.sleep(0.4)
    time.sleep(1.5)
    up = scr.state()
    for _ in range(5):
        mon.cmd('mouse_move 0 0 -1')
        time.sleep(0.4)
    time.sleep(1.5)
    down = scr.state()
    log.append(f'wheel: before {before} after dz+3 {up} after dz-5 {down}')
    if not (before and up and down):
        return False
    w0, w1, w2 = (signed16(s[8]) for s in (before, up, down))
    log.append(f'wheel sums {w0} {w1} {w2} api={before[6]:04X} caps={before[7]:04X}')
    if not want:
        return w0 == w1 == w2 and not before[7] & 1
    return before[6] == 0x574D and bool(before[7] & 1) and w1 < w0 and w2 > w1


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--mode', choices=sorted(AUTOEXEC), default='session')
    p.add_argument('--seconds', type=int, default=240)
    p.add_argument('--keep', action='store_true')
    p.add_argument('--csmwrap', type=Path, default=CSMWRAP, help='csmwrapx64.efi (default: 3.1.2-usos11)')
    p.add_argument('--wheel', action='store_true', help='expect the USB wheel (CSMWrap patch 0016)')
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    disk = out / 'dos-mouse.img'
    make_disk(disk, a.mode, out, a.csmwrap)
    vars_fd = out / 'vars.fd'
    vars_fd.write_bytes(OVMF_VARS.read_bytes())
    port = free_port()
    cmd = [str(QEMU), '-name', 'USOS-dos-mouse', '-machine', 'pc,i8042=off,vmport=off', '-accel', 'tcg', '-cpu', 'max',
           '-smp', '2', '-m', '1024', '-display', 'none', '-vga', 'std', '-nic', 'none',
           '-drive', f'if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}',
           '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=none,id=dos,format=raw,cache=writeback,file={disk.as_posix()}',
           '-device', 'nvme,drive=dos,serial=USOS-DOS-MOUSE',
           '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0', '-device', 'usb-mouse,bus=xhci.0']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print('QEMU PID', proc.pid, flush=True)
    log, ok, text = [], False, ''
    try:
        time.sleep(1)
        mon = Monitor(port)
        scr = Screen(mon, out)
        if a.mode == 'dosmouse':
            on = scr.wait(lambda t: 'USB mouse for DOS programs is on' in t, a.seconds)
            log.append('dosmouse on: ' + ('yes' if on else 'no'))
            if on:
                time.sleep(2)
                type_text(mon, 'C:\\M33TEST.COM\n')
        first = None
        if scr.wait(lambda t: LINE.search(t) is not None, a.seconds if a.mode == 'session' else 60):
            first = scr.state()
        log.append(f'start {first}')
        if first and first[0] == 0xFFFF:
            ok = mouse_checks(mon, scr, first, log)
            ok = wheel_checks(mon, scr, a.wheel, log) and ok
            if a.mode == 'dosmouse':
                mon.cmd('sendkey spc')
                time.sleep(1.5)
                type_text(mon, 'exit\n')
                after = scr.wait(lambda t: AFTER in t and LINE.search(t) is not None, 60)
                gone = scr.state() if after else None
                log.append(f'after EXIT: uninstalled={bool(after and "Driver uninstalled" in after)} state={gone}')
                ok = ok and bool(after and 'Driver uninstalled' in after and gone and gone[0] == 0)
        text = scr.text()
        mon.cmd(f'screendump "{(out / "screen.ppm").as_posix()}"')
        mon.cmd('quit')
    finally:
        try:
            proc.wait(15)
        except Exception:
            proc.kill()
    (out / 'screen.txt').write_text(text, encoding='utf-8')
    (out / 'probe.log').write_text('\n'.join(log) + '\n', encoding='utf-8')
    print(text)
    print('\n'.join(log))
    if not a.keep:
        for f in (disk, vars_fd, out / 'vga.bin'):
            f.unlink(missing_ok=True)
    print(f'DOS-MOUSE-{a.mode.upper()}-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
