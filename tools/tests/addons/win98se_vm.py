"""QEMU test of the legacy compatibility pack on a fresh Windows 98 SE
(docs/design/legacy-compat-pack.md section 6).

The host builds the target disk the way the 9x DOS Setup path is meant to
seed it (section 2.5, way (a)): MBR + FAT32 with C:\\WIN98 (Setup files
from the user's ISO), C:\\WIN98\\MSBATCH.INF and C:\\USOS\\ADDONS (staged
pack); the CD's own startup floppy (CONFIG.SYS/AUTOEXEC.BAT replaced) runs
FDISK /MBR, SYS C: and SETUP. The MSBATCH.INF adds the USOSADD RunOnce
entry exactly as the MSBATCH renderer will.

The product key is read from --key-file (a file outside the repository);
it ends up only in the VM disk and the floppy image in --work, which the
caller deletes after the test (`clean`).

  python win98se_vm.py prepare --work DIR --iso 98SE.iso --stage STAGED_ADDONS --key-file F
  python win98se_vm.py start --work DIR [--port 4471] [--disk-only] [--acceptance]
  python win98se_vm.py shot  --work DIR NAME        (PNG in DIR/shots)
  python win98se_vm.py keys  --work DIR ret tab ...
  python win98se_vm.py type  --work DIR "text"
  python win98se_vm.py quit  --work DIR
  python win98se_vm.py log   --work DIR             (C:\\USOS\\addons.log from the disk)
  python win98se_vm.py clean --work DIR             (deletes disk, floppy, answer file)
"""
from __future__ import annotations

import argparse
import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import fat_image  # noqa: E402

SEVEN = Path(r'C:\Program Files\7-Zip\7z.exe')
QEMU_CANDIDATES = [ROOT / 'tools/qemu/qemu-system-i386.exe',
                   ROOT.parent / 'usos-win9x/tools/qemu/qemu-system-i386.exe',
                   ROOT.parent / 'Universal_Service_OS/tools/qemu/qemu-system-i386.exe']

MSBATCH = r'''; USOS legacy pack VM test: default USOS answer (src/platform/bios/win9x/msbatch.inf
; on feature/win9x-modern) + product key + the USOSADD RunOnce entry.
[Version]
Signature="$CHICAGO$"

[Setup]
Express=1
InstallDir="C:\WINDOWS"
InstallType=1
EBD=0
ShowEula=0
ChangeDir=0
OptionalComponents=1
Network=1
System=0
CCP=0
CleanBoot=0
Display=0
DevicePath=0
NoDirWarn=1
NoPrompt2Boot=1
Uninstall=0
VRC=1
TimeZone="Central European"
ProductKey="{key}"

[NameAndOrg]
Name="USOS"
Org="USOS"
Display=0

[Network]
ComputerName="USOS-9X"
Workgroup="WORKGROUP"
Description="USOS"
Display=0
Clients=
Protocols=
Services=

[Install]
AddReg=USOS.RunOnce

[USOS.RunOnce]
HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce",USOSWelcome,,"%25%\rundll.exe setupx.dll,InstallHinfSection USOS.NoWelcome 4 %10%\msbatch.inf"
HKLM,"Software\Microsoft\Windows\CurrentVersion\Run",USOSAddons,,"C:\USOS\ADDONS\USOSADD.EXE"

[USOS.NoWelcome]
DelReg=USOS.Welcome.Del
AddReg=USOS.Regwiz

[USOS.Welcome.Del]
HKLM,"Software\Microsoft\Windows\CurrentVersion\Run",Welcome

[USOS.Regwiz]
HKLM,"Software\Microsoft\Windows\CurrentVersion\Welcome\Regwiz",,1,01,00,00,00
HKLM,"Software\Microsoft\Windows\CurrentVersion",RegDone,1,01,00,00,00
'''

CONFIG_SYS = 'DEVICE=A:\\HIMEM.SYS\r\nFILES=40\r\nBUFFERS=30\r\nLASTDRIVE=Z\r\n'
AUTOEXEC_BAT = (
    '@ECHO OFF\r\n'
    'ECHO USOS legacy pack VM test: preparing C: and starting Setup\r\n'
    'A:\\FDISK.EXE /MBR\r\n'
    'C:\\USOSTMP\\SYS.COM C:\r\n'
    'C:\\USOSTMP\\ATTRIB.EXE -H -S -R C:\\MSDOS.SYS\r\n'
    'ECHO [Options]>>C:\\MSDOS.SYS\r\n'
    'ECHO Logo=0>>C:\\MSDOS.SYS\r\n'
    'C:\\USOSTMP\\ATTRIB.EXE +H +S +R C:\\MSDOS.SYS\r\n'
    'C:\r\n'
    'CD \\WIN98\r\n'
    'C:\\WIN98\\SETUP.EXE C:\\WIN98\\MSBATCH.INF /IS /IE /NM\r\n'
)


def qemu() -> Path:
    for c in QEMU_CANDIDATES:
        if c.is_file():
            return c
    raise SystemExit('qemu-system-i386.exe not found')


def prepare(a) -> None:
    work = a.work
    work.mkdir(parents=True, exist_ok=True)
    src = work / 'iso'
    subprocess.run([str(SEVEN), 'x', '-y', f'-o{src}', str(a.iso), '[BOOT]/Boot-1.44M.img', 'win98/*'],
                   check=True, capture_output=True)
    floppy = work / 'floppy.img'
    shutil.copyfile(src / '[BOOT]' / 'Boot-1.44M.img', floppy)
    fl = work / 'fl'
    subprocess.run([str(SEVEN), 'x', '-y', f'-o{fl}', str(floppy)], check=True, capture_output=True)
    ebd = next(p for p in fl.iterdir() if p.name.lower() == 'ebd.cab')
    tools = work / 'ebd'
    subprocess.run([str(SEVEN), 'x', '-y', f'-o{tools}', str(ebd), 'SYS.COM', 'ATTRIB.EXE'], check=True, capture_output=True)
    # JO.SYS is the CD's "Boot from Hard Disk / CD-ROM" menu (default: hard disk)
    fat_image.floppy_hide(floppy, 'JO.SYS')
    fat_image.floppy_replace(floppy, 'CONFIG.SYS', CONFIG_SYS.encode('ascii'))
    fat_image.floppy_replace(floppy, 'AUTOEXEC.BAT', AUTOEXEC_BAT.encode('ascii'))
    key = a.key_file.read_text(encoding='ascii').strip()
    disk = work / 'disk.raw'
    w = fat_image.Fat32Writer(disk, a.size_gb * 1024 ** 3)
    n = w.add_tree(src / 'win98', ('WIN98',))
    w.add_file(('WIN98', 'MSBATCH.INF'), MSBATCH.replace('{key}', key).replace('\n', '\r\n').encode('ascii'))
    for name in ('SYS.COM', 'ATTRIB.EXE'):
        w.add_file(('USOSTMP', name), (tools / name).read_bytes())
    m = w.add_tree(a.stage, ('USOS', 'ADDONS'))
    w.finish()
    shutil.rmtree(fl, ignore_errors=True)
    shutil.rmtree(tools, ignore_errors=True)
    shutil.rmtree(src, ignore_errors=True)
    print(f'[PASS] disk {disk} ({a.size_gb} GiB): {n} Setup files, {m} pack files; floppy {floppy}')


class Monitor:
    def __init__(self, port: int):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=10)
        self.read()

    def read(self) -> str:
        self.s.settimeout(0.5)
        out = b''
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                out += chunk
        except (socket.timeout, TimeoutError):
            pass
        return out.decode(errors='replace')

    def cmd(self, text: str, wait: float = 0.3) -> str:
        self.s.sendall(text.encode() + b'\n')
        time.sleep(wait)
        return self.read()


def state(work: Path) -> dict:
    return json.loads((work / 'vm.json').read_text())


def start(a) -> None:
    port = a.port
    args = [str(qemu()), '-machine', 'pc,smm=off', '-cpu', 'pentium3', '-m', '256', '-accel', 'tcg',
            '-drive', f'file={a.work / "disk.raw"},format=raw,if=ide,index=0',
            '-boot', 'order=ac', '-vga', 'cirrus', '-nic', 'none', '-rtc', 'base=localtime',
            '-display', 'none', '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off']
    # The startup floppy only for the first boot (Setup); later starts boot C:
    # (a floppy left in would run INSTALL again: SYS C: and SETUP).
    if not a.disk_only:
        args[args.index('-boot'):args.index('-boot')] = ['-drive', f'file={a.work / "floppy.img"},format=raw,if=floppy,index=0']
    if a.acceptance:
        # Usability checks (docs/design/legacy-compat-pack.md section 6): a USB
        # stick with a marker file on EHCI (NUSB), a Sound Blaster 16.
        stick = a.work / 'stick.raw'
        if not stick.exists():
            w = fat_image.Fat32Writer(stick, 300 * 1024 ** 2, label='USOSSTICK')
            w.add_file(('USOSTEST.TXT',), b'USOS legacy pack USB stick check' + bytes([13, 10]))
            w.finish()
        args += ['-device', 'usb-ehci,id=ehci', '-drive', f'if=none,id=stick,file={stick},format=raw',
                 '-device', 'usb-storage,bus=ehci.0,drive=stick', '-device', 'sb16']
    log = open(a.work / 'qemu.log', 'w')
    p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                         creationflags=getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0))
    (a.work / 'vm.json').write_text(json.dumps({'port': port, 'pid': p.pid}))
    time.sleep(2)
    print('started pid', p.pid, 'port', port)


def shot(a) -> None:
    from PIL import Image
    shots = a.work / 'shots'
    shots.mkdir(exist_ok=True)
    ppm = shots / (a.name + '.ppm')
    Monitor(state(a.work)['port']).cmd(f'screendump "{ppm.as_posix()}"', 1.5)
    png = ppm.with_suffix('.png')
    Image.open(ppm).save(png)
    ppm.unlink()
    print(png)


def keys(a) -> None:
    m = Monitor(state(a.work)['port'])
    for k in a.keys:
        m.cmd('sendkey ' + k, a.delay)


def type_text(a) -> None:
    m = Monitor(state(a.work)['port'])
    special = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '\\': 'backslash', ':': 'shift-semicolon',
               '/': 'slash', ',': 'comma'}
    for ch in a.text:
        k = special.get(ch) or (('shift-' + ch.lower()) if ch.isupper() else ch)
        m.cmd('sendkey ' + k, 0.12)


def eject(a) -> None:
    print(Monitor(state(a.work)['port']).cmd('eject -f floppy0', 1.0).strip().splitlines()[-1:])


def quit_vm(a) -> None:
    try:
        Monitor(state(a.work)['port']).cmd('quit', 1.0)
    except OSError:
        pass


def log(a) -> None:
    r = fat_image.Fat32Reader(a.work / 'disk.raw')
    for parts in (('USOS', 'ADDONS.LOG'), ('USOS', 'ADDONS', 'STATE.INI')):
        try:
            print(f'===== C:\\{chr(92).join(parts)}')
            print(r.read(parts).decode('cp1250', errors='replace'))
        except FileNotFoundError:
            print('(missing)')


def clean(a) -> None:
    for name in ('disk.raw', 'floppy.img', 'vm.json', 'stick.raw'):
        (a.work / name).unlink(missing_ok=True)
    print('removed VM disk and floppy (they held the product key)')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('prepare', 'start', 'shot', 'keys', 'type', 'eject', 'quit', 'log', 'clean'):
        s = sub.add_parser(name)
        s.add_argument('--work', type=Path, required=True)
        if name == 'prepare':
            s.add_argument('--iso', type=Path, required=True)
            s.add_argument('--stage', type=Path, required=True)
            s.add_argument('--key-file', type=Path, required=True)
            s.add_argument('--size-gb', type=int, default=4)
        if name == 'start':
            s.add_argument('--port', type=int, default=4471)
            s.add_argument('--acceptance', action='store_true', help='add a USB stick (EHCI) and a Sound Blaster 16')
            s.add_argument('--disk-only', action='store_true', help='no floppy: boot the installed C:')
        if name == 'shot':
            s.add_argument('name')
        if name == 'keys':
            s.add_argument('keys', nargs='+')
            s.add_argument('--delay', type=float, default=0.4)
        if name == 'type':
            s.add_argument('text')
    a = ap.parse_args()
    {'prepare': prepare, 'start': start, 'shot': shot, 'keys': keys, 'type': type_text, 'eject': eject, 'quit': quit_vm,
     'log': log, 'clean': clean}[a.cmd](a)


if __name__ == '__main__':
    main()
