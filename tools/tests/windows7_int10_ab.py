"""QEMU/OVMF (no CSM) A/B: Windows 7 SP1 x64 Setup PE started by its own
6.1 boot manager, with and without an Int10 shim in front of it.
docs/design/win7-vista-no-csm.md section 8.2. Manual trial, not in run.ps1
(TCG, about 13 minutes per variant; variants can run in parallel).

  python tools/tests/windows7_int10_ab.py extract <Win7 SP1 x64 ISO>
  python tools/build_windows7_uefi.py                      # win7-wrapper.efi
  powershell -File tools/build_uefiseven.ps1 -OutFile zig-out/win7-int10-ab/UefiSeven-src.efi
  python tools/tests/windows7_int10_ab.py <variant> [minutes]

Variants (each a vvfat ESP with the ISO's BCD, fonts, boot.sdi and boot.wim):
  plain     EFI/BOOT/BOOTX64.EFI = bootmgfw.efi 6.1 from boot.wim index 1
  usos      the USOS target-ESP layout: win7-wrapper.efi, win7.efi = UefiSeven
            (source build), win7.original.efi = bootmgfw.efi
  usosrel   as usos with the shipped release UefiSeven.efi
  upstream  UefiSeven (source build) as BOOTX64.EFI, BOOTX64.original.efi =
            bootmgfw.efi (UefiSeven's own install mode, no USOS PAM unlock)
  usosrp    as usos, but the std VGA sits behind a PCIe root port at 00:03.0
            (the X470 topology: GPU behind a bridge)
  usosbroken  as usosrp, with tools/tests/windows7_vga_break.zig as
            BOOTX64.EFI: it clears the root port's VGA Enable and the GPU's I/O
            decode (the suspected X470 CSM-off state), then chainloads the
            dispatcher (EFI/BOOT/usos-dispatch.efi)
  usosnoattr  as usosbroken, and the GPU's PciIo.Attributes(Enable/Set) is
            made to return EFI_UNSUPPORTED, so the raw bridge fallback must work
  usosconflict  as usosnoattr, and an empty second root port (00:04.0) is
            given VGA Enable: the dispatcher must not route, must show the
            frozen-display note, and Windows then meets the X470 failure
  usoscsm   as usosbroken with a fake IVT 0x10 into E0000: the dispatcher takes
            its CSM path (checks usos-boot-csm.log and that no VGA routing
            runs; Windows itself cannot boot on the fake vector)
  oldbroken as usosbroken with OLD_WRAPPER (a dispatcher built before the VGA
            routing change) to show the emulated failure
Needs 7-Zip (%ProgramFiles%/7-Zip/7z.exe) for "extract", and Pillow.
"""
import json, os, shutil, socket, subprocess, sys, time
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parents[2]
SP = REPO / 'zig-out/win7-int10-ab'
QEMU = REPO / 'tools/qemu'
ISO = SP / 'win7iso'
UEFISEVEN = Path(os.environ.get('UEFISEVEN', str(SP / 'UefiSeven-src.efi')))
RELEASE = REPO / 'tools/vendor/uefiseven/1.30/UefiSeven.efi'
WRAPPER = REPO / 'zig-out/windows7-uefi/win7-wrapper.efi'
INI = b'[config]\r\nverbose=0\r\nlogfile=1\r\nskiperrors=1\r\nforce_fakevesa=0\r\n'
VARIANTS = ['plain', 'usos', 'upstream', 'usosrel', 'usosrp', 'usosbroken', 'oldbroken', 'usosnoattr', 'usosconflict', 'usoscsm']
OLD_WRAPPER = Path(os.environ.get('OLD_WRAPPER', str(SP / 'win7-wrapper-old.efi')))
BREAK = SP / 'vga-break.efi'
ROOT_PORT_VGA = ['-vga', 'none', '-device', 'pcie-root-port,id=rp1,bus=pcie.0,chassis=1,addr=0x3',
                 '-device', 'VGA,bus=rp1', '-device', 'pcie-root-port,id=rp2,bus=pcie.0,chassis=2,addr=0x4']


def link(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst.unlink()
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)


def esp(variant):
    root = SP / f'esp-{variant}'
    if root.exists():
        shutil.rmtree(root)
    boot = root / 'EFI/BOOT'
    boot.mkdir(parents=True, exist_ok=True)
    (root / 'EFI/Microsoft/Boot').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ISO / 'efi/microsoft/boot/bcd', root / 'EFI/Microsoft/Boot/BCD')
    for font in (ISO / 'efi/microsoft/boot/fonts').iterdir():
        link(font, root / 'EFI/Microsoft/Boot/Fonts' / font.name)
    link(ISO / 'boot/boot.sdi', root / 'boot/boot.sdi')
    link(ISO / 'sources/boot.wim', root / 'sources/boot.wim')
    bootmgfw = ISO / 'wimefi/bootmgfw.efi'
    if variant == 'plain':
        link(bootmgfw, boot / 'BOOTX64.EFI')
    elif variant in ('usosbroken', 'oldbroken', 'usosnoattr', 'usosconflict', 'usoscsm'):
        build_break()
        if variant == 'usoscsm':
            (boot / 'vga-break-fakeint10').write_bytes(b'1')
        if variant == 'usosconflict':
            (boot / 'vga-break-conflict').write_bytes(b'1')
        if variant in ('usosnoattr', 'usosconflict'):
            (boot / 'vga-break-noattr').write_bytes(b'1')
        shutil.copyfile(BREAK, boot / 'BOOTX64.EFI')
        shutil.copyfile(OLD_WRAPPER if variant == 'oldbroken' else WRAPPER, boot / 'usos-dispatch.efi')
        shutil.copyfile(RELEASE, boot / 'win7.efi')
        link(bootmgfw, boot / 'win7.original.efi')
        (boot / 'UefiSeven.ini').write_bytes(INI)
    elif variant in ('usos', 'usosrel', 'usosrp'):
        shutil.copyfile(WRAPPER, boot / 'BOOTX64.EFI')
        shutil.copyfile(RELEASE if variant == 'usosrel' else UEFISEVEN, boot / 'win7.efi')
        link(bootmgfw, boot / 'win7.original.efi')
        (boot / 'UefiSeven.ini').write_bytes(INI)
    elif variant == 'upstream':
        shutil.copyfile(UEFISEVEN, boot / 'BOOTX64.EFI')
        link(bootmgfw, boot / 'BOOTX64.original.efi')
        (boot / 'UefiSeven.ini').write_bytes(INI)
    else:
        raise SystemExit('unknown variant ' + variant)
    return root


def build_break():
    SP.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(REPO / 'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(SP / 'zig-cache'))
    subprocess.run([str(REPO / 'tools/zig/zig.exe'), 'build-exe', '-target', 'x86_64-uefi', '-O', 'ReleaseSmall',
                    '--dep', 'windows7_vga_routing', '-Mroot=' + str(REPO / 'tools/tests/windows7_vga_break.zig'),
                    '-Mwindows7_vga_routing=' + str(REPO / 'tools/windows7_vga_routing.zig'),
                    '-femit-bin=' + str(BREAK)], env=env, check=True)


def qmp(port):
    for _ in range(100):
        try:
            s = socket.create_connection(('127.0.0.1', port), timeout=5)
            break
        except OSError:
            time.sleep(0.2)
    else:
        raise RuntimeError('QMP not reachable')
    f = s.makefile('rw', encoding='utf-8', newline='\n')
    f.readline()

    def cmd(name, **args):
        f.write(json.dumps({'execute': name, 'arguments': args} if args else {'execute': name}) + '\n')
        f.flush()
        while True:
            reply = json.loads(f.readline())
            if 'return' in reply or 'error' in reply:
                return reply
    cmd('qmp_capabilities')
    return s, cmd


def run(variant, minutes, shots):
    root = esp(variant)
    out = SP / f'result-{variant}'
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    vars_fd = out / 'vars.fd'
    shutil.copyfile(QEMU / 'share/edk2-i386-vars.fd', vars_fd)
    port = 4450 + VARIANTS.index(variant)
    args = [str(QEMU / 'qemu-system-x86_64.exe'), '-machine', 'q35', '-accel', 'tcg', '-cpu', 'max',
            '-m', '2048', '-smp', '2', '-display', 'none', '-nic', 'none']
    args += ROOT_PORT_VGA if variant in ('usosrp', 'usosbroken', 'oldbroken', 'usosnoattr', 'usosconflict', 'usoscsm') else ['-vga', 'std']
    args += [
            '-drive', 'if=pflash,format=raw,readonly=on,file=' + str(QEMU / 'share/edk2-x86_64-code.fd'),
            '-drive', 'if=pflash,format=raw,file=' + str(vars_fd),
            '-drive', 'if=none,id=esp,format=raw,file=fat:rw:' + str(root),
            '-device', 'ahci,id=ahci', '-device', 'ide-hd,drive=esp,bus=ahci.0,bootindex=0',
            '-serial', 'file:' + str(out / 'serial.log'),
            '-debugcon', 'file:' + str(out / 'debugcon.log'), '-global', 'isa-debugcon.iobase=0x402',
            '-qmp', f'tcp:127.0.0.1:{port},server=on,wait=off']
    log = (out / 'qemu.log').open('wb')
    proc = subprocess.Popen(args, stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        sock, cmd = qmp(port)
        start = time.time()
        taken = []
        for at in shots:
            if at > minutes * 60:
                break
            while time.time() - start < at:
                if proc.poll() is not None:
                    raise RuntimeError(f'QEMU exited {proc.returncode}')
                time.sleep(1)
            ppm = out / f't{at:04d}.ppm'
            cmd('screendump', filename=str(ppm))
            time.sleep(1)
            png = out / f't{at:04d}.png'
            Image.open(ppm).save(png)
            ppm.unlink()
            taken.append(png.name)
            print(variant, at, png.name, flush=True)
        cmd('quit')
    finally:
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    for name in ('usos-boot.log', 'usos-boot-uefiseven.log', 'usos-boot-csm.log', 'UefiSeven.log',
                 'usos-memory.log', 'usos-amd-shadow.log'):
        for found in root.rglob(name):
            shutil.copyfile(found, out / found.name)
    return taken


def extract(iso):
    ISO.mkdir(parents=True, exist_ok=True)
    seven = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / '7-Zip' / '7z.exe'
    names = ['efi/microsoft/boot/bcd', 'efi/microsoft/boot/fonts/*', 'boot/boot.sdi', 'sources/boot.wim']
    subprocess.run([str(seven), 'x', '-y', '-o' + str(ISO), iso] + [n.replace('/', os.sep) for n in names],
                   check=True, stdout=subprocess.DEVNULL)
    bootmgfw = os.sep + os.sep.join(['Windows', 'Boot', 'EFI', 'bootmgfw.efi'])
    subprocess.run([str(REPO / 'tools/vendor/wimlib/1.14.5/wimlib-imagex.exe'), 'extract',
                    str(ISO / 'sources/boot.wim'), '1', bootmgfw,
                    '--dest-dir=' + str(ISO / 'wimefi'), '--no-acls'], check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    if sys.argv[1] == 'extract':
        extract(sys.argv[2])
        raise SystemExit(0)
    variant = sys.argv[1]
    minutes = float(sys.argv[2]) if len(sys.argv) > 2 else 12
    shots = [20, 45, 90, 150, 240, 360, 480, 600, 720, 900]
    print(run(variant, minutes, shots))
