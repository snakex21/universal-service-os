#!/usr/bin/env python3
"""Windows NT 4.0 QEMU lab (dev PC only; never touches real disks).

Proves the NT4 install method chosen in the NT4 plan: the whole install runs
in QEMU with an old CPU model (-cpu pentium3, the RTM text-mode kernel
triple-faults on a Zen 3 CPUID), on emulated IDE, with no F6/OEM driver.
The first logon runs USOS\\POST.CMD from the lab CD ([GuiRunOnce]): it copies
AHCINT (NT4 build) and usosrst (NT4 build) to system32\\drivers, registers
both as boot-start services (NT4 is not PnP: a SCSI miniport needs only the
.sys and its Services key; it scans PCI itself) and installs SP6a
(SP6I386.EXE -u -z). 2026-10-07: [GuiRunOnce] did not fire (probably
needs OemPreinstall=Yes + $OEM$); POST.CMD was started by hand. The same disk is then booted on ich9-ahci, with
pentium3 and with a Zen 3 model (EPYC-Milan).

Subcommands
  iso   SRC_ISO OUT_ISO --key-file F [--local-source] [--sp6a SP6I386.EXE] [--ahcint SYS] [--usosrst SYS]
        RTM CD + \\I386\\WINNT.SIF (CD boot reads it: [Data] MsDosInitiated="0")
        + \\USOS\\{POST.CMD,DRIVERS.REG,...}. The OUT_ISO holds the product key:
        delete it after the test (test-key policy).
  disk  OUT_RAW [--size-gb 4] [--tree DIR]
        --tree DIR: DIR's contents become C: (e.g. $WIN_NT$.~LS/I386 = the RTM
        I386 tree, with iso --local-source: the only unattended layout that
        works; CD-only unattended + any partition = STOP 0x1E in setupdd).
        Own MBR boot code (MBR_CODE) is written too.
        MBR + one active FAT16 C: (type 06, LBA 63, 2000 MiB, 32 KiB clusters),
        the layout micro-Linux will create; Setup keeps it (FileSystem=LeaveAlone).
  run   NAME DISK [--iso ISO] [--cpu pentium3] [--bus ide|ahci] [--seconds N]
        [--interval S] [--port P]
        Boots QEMU (SeaBIOS, -machine pc), screenshots every S seconds to
        OUTDIR/NAME-NNN.png and NAME-last.png. Monitor on P (lab) and P+1 (free
        for `mon`).
  mon   PORT CMD...   send monitor commands (e.g. "sendkey ctrl-alt-delete").

Requires: pycdlib, Pillow, QEMU (USOS_QEMU or tools/qemu/qemu-system-x86_64.exe).
"""
from __future__ import annotations

import argparse
import os
import re
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

KEY_RE = re.compile(r'^\w+=(\d{5}-OEM-\d{7}-\d{5}|\d{3}-\d{7})$')


def read_key(path: Path) -> str:
    """First OEM (xxxxx-OEM-xxxxxxx-xxxxx) or retail (xxx-xxxxxxx) key; never printed."""
    oem = retail = None
    for line in path.read_text(encoding='utf-8').splitlines():
        m = KEY_RE.match(line.strip())
        if not m:
            continue
        if 'OEM' in m.group(1):
            oem = oem or m.group(1)
        else:
            retail = retail or m.group(1)
    key = oem or retail
    if not key:
        raise SystemExit('no NT4 key in key file')
    return key


def winnt_sif(key: str, computer: str = 'USOSNT4', local_source: bool = False) -> str:
    # CD boot (MsDosInitiated "0") + any existing partition = STOP 0x1E in
    # setupdd (QEMU 2026-10-07); local_source = winnt /b style C:\$WIN_NT$.~LS.
    data = 'MsDosInitiated = 1\nFloppyless = 1\n' if local_source else 'MsDosInitiated = "0"\n'
    return f'''[Data]
{data}UnattendedInstall = "Yes"

[Unattended]
OemPreinstall = No
NoWaitAfterTextMode = 1
NoWaitAfterGUIMode = 1
FileSystem = LeaveAlone
ExtendOemPartition = 0
ConfirmHardware = No
NtUpgrade = No
Win31Upgrade = No
TargetPath = \\WINNT
OverwriteOemFilesOnUpgrade = No

[UserData]
FullName = "USOS"
OrgName = "USOS"
ComputerName = {computer}
ProductId = "{key}"

[GuiUnattended]
OemSkipWelcome = 1
OEMBlankAdminPassword = 1

[Display]
ConfigureAtLogon = 0
AutoConfirm = 1
BitsPerPel = 8
XResolution = 640
YResolution = 480
VRefresh = 60

[GuiRunOnce]
"D:\\USOS\\POST.CMD"
'''


POST_CMD = r'''@echo off
rem USOS NT4 lab: first logon. Drivers first, SP6a last (it needs a reboot).
set S=
for %%d in (D E F G H) do if exist %%d:\USOS\POST.CMD set S=%%d:
if "%S%"=="" goto nocd
echo USOS NT4 post: source %S% > C:\USOSPOST.LOG
copy %S%\USOS\AHCINT.SYS %SystemRoot%\system32\drivers\ahcint.sys >> C:\USOSPOST.LOG
copy %S%\USOS\USOSRST.SYS %SystemRoot%\system32\drivers\usosrst.sys >> C:\USOSPOST.LOG
regedit /s %S%\USOS\DRIVERS.REG
echo drivers registered >> C:\USOSPOST.LOG
if exist %S%\USOS\SP6I386.EXE %S%\USOS\SP6I386.EXE -u -z
echo sp6a started >> C:\USOSPOST.LOG
goto end
:nocd
echo USOS CD not found > C:\USOSPOST.LOG
:end
'''

DRIVERS_REG = r'''REGEDIT4

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ahcint]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"Group"="SCSI miniport"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000000
"Group"="System Bus Extender"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst\Parameters]
"HpetLegacyOff"=dword:00000001
"RtcFix"=dword:00000001
'''

CHECK_CMD = r'''@echo off
rem USOS NT4 lab: show what loaded (run by hand or from RunOnce).
ver
regedit /e C:\USOSCHK.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosrst
type C:\USOSCHK.REG
type C:\USOSPOST.LOG
dir %SystemRoot%\system32\drivers\ahcint.sys %SystemRoot%\system32\drivers\usosrst.sys
'''


def cmd_iso(a) -> None:
    import pycdlib  # type: ignore
    key = read_key(Path(a.key_file))
    iso = pycdlib.PyCdlib()
    iso.open(a.src_iso)
    iso.interchange_level = 4
    fps = []

    def add_bytes(data: bytes, path: str) -> None:
        import io
        fp = io.BytesIO(data)
        fps.append(fp)
        iso.add_fp(fp, len(data), iso_path=path)

    def add_file(src: str, path: str) -> None:
        fp = open(src, 'rb')
        fps.append(fp)
        iso.add_fp(fp, os.path.getsize(src), iso_path=path)

    add_bytes(winnt_sif(key, local_source=a.local_source).replace('\n', '\r\n').encode('cp1250'), '/I386/WINNT.SIF')
    iso.add_directory(iso_path='/USOS')
    add_bytes(POST_CMD.replace('\n', '\r\n').encode('ascii'), '/USOS/POST.CMD')
    add_bytes(CHECK_CMD.replace('\n', '\r\n').encode('ascii'), '/USOS/CHECK.CMD')
    add_bytes(DRIVERS_REG.replace('\n', '\r\n').encode('ascii'), '/USOS/DRIVERS.REG')
    add_file(a.ahcint or str(REPO / 'tools/vendor/ahcint/1.3.0.0-usos4/bin/NT4/i386/ahcint.sys'), '/USOS/AHCINT.SYS')
    add_file(a.usosrst or str(REPO / 'tools/w2k/usosrst/bin/nt4/i386/usosrst.sys'), '/USOS/USOSRST.SYS')
    if a.sp6a:
        add_file(a.sp6a, '/USOS/SP6I386.EXE')
    iso.write(a.out_iso)
    iso.close()
    for fp in fps:
        fp.close()
    print('wrote', a.out_iso, '(contains the product key: delete after the test)')

# Own minimal MBR boot code (USOS, GPL): relocate to 0:0600, find the active
# entry, read its first sector with INT 13h AH=42h to 0:7C00, check 55AA,
# jump with DL from the BIOS and DS:SI -> entry. INT 18h on any failure.
MBR_CODE = bytes.fromhex(
    'fa31c08ed0bc007c8ed88ec0fbfcbe007cbf0006b90001f3a5ea1e060000'
    'bebe07b9040080 3c80 7407 83c610 e2f6 cd18'
    'bf8005 c7051000 c745020100 c74504007c c745060000 668b4408 66894508'
    '6631c0 6689450c 56 89fe b442 cd13 5e 720d 813efe7d55aa 7505 ea007c0000 cd18'
    .replace(' ', ''))


def fat16_disk(path: Path, size_gb: int = 4, tree: str | None = None) -> None:
    """tree: a local folder whose contents become the root of C: (8.3 names only)."""
    start, n = 63, 2000 * 2048
    spc, rsv, nf, rde, fatsz = 64, 1, 2, 512, 256

    def chs(lba: int) -> bytes:
        c, h, s = lba // (255 * 63), (lba // 63) % 255, lba % 63 + 1
        if c > 1023:
            c, h, s = 1023, 254, 63
        return bytes([h, s | ((c >> 2) & 0xC0), c & 0xFF])

    with open(path, 'wb') as d:
        d.truncate(size_gb * 1024 ** 3)
        mbr = bytearray(512)
        mbr[0:len(MBR_CODE)] = MBR_CODE
        mbr[446:462] = bytes([0x80]) + chs(start) + b'\x06' + chs(start + n - 1) + struct.pack('<II', start, n)
        mbr[440:444] = b'USOS'
        mbr[510:512] = b'\x55\xaa'
        d.write(mbr)
        bs = bytearray(512)
        bs[0:3] = b'\xEB\x3C\x90'
        bs[3:11] = b'MSWIN4.1'
        struct.pack_into('<HBHBHHBHHHII', bs, 11, 512, spc, rsv, nf, rde, 0, 0xF8, fatsz, 63, 255, start, n)
        struct.pack_into('<BBBI11s8s', bs, 36, 0x80, 0, 0x29, 0x55534F53, b'USOS-NT4   ', b'FAT16   ')
        bs[510:512] = b'\x55\xaa'
        clusters = (n - rsv - nf * fatsz - rde * 32 // 512) // spc
        assert clusters < 65525 and (clusters + 2) * 2 <= fatsz * 512
        d.seek(start * 512)
        d.write(bs)
        fat = bytearray(fatsz * 512)
        fat[0:4] = b'\xF8\xFF\xFF\xFF'
        root_sec = start + rsv + nf * fatsz
        data_sec = root_sec + rde * 32 // 512
        csize = spc * 512
        nxt = [2]

        def alloc(count: int) -> int:
            first = nxt[0]
            for c in range(first, first + count):
                struct.pack_into('<H', fat, c * 2, c + 1 if c < first + count - 1 else 0xFFFF)
            nxt[0] += count
            assert nxt[0] < clusters + 2, 'FAT16 C: full'
            return first

        def short(name: str) -> bytes:
            base, _, ext = name.upper().partition('.')
            assert 1 <= len(base) <= 8 and len(ext) <= 3, name
            return base.ljust(8).encode('ascii') + ext.ljust(3).encode('ascii')

        def entry(name: bytes, attr: int, clus: int, size: int) -> bytes:
            # 2026-10-07 12:00 (DOS date/time)
            t, dt = (12 << 11), ((2026 - 1980) << 9) | (10 << 5) | 7
            return struct.pack('<11sBBBHHHHHHHI', name, attr, 0, 0, t, dt, dt, 0, t, dt, clus, size)

        def write_dir(src: Path, parent: int, this: int | None) -> bytes:
            ents = []
            if this is not None:
                ents += [entry(b'.          ', 0x10, this, 0), entry(b'..         ', 0x10, parent, 0)]
            for p in sorted(src.iterdir()):
                if p.is_dir():
                    n_ent = 2 + len(list(p.iterdir()))
                    c = alloc(max(1, -(-n_ent * 32 // csize)))
                    blob = write_dir(p, this or 0, c)
                    d.seek((data_sec + (c - 2) * spc) * 512)
                    d.write(blob)
                    ents.append(entry(short(p.name), 0x10, c, 0))
                else:
                    data = p.read_bytes()
                    c = alloc(-(-len(data) // csize)) if data else 0
                    if data:
                        d.seek((data_sec + (c - 2) * spc) * 512)
                        d.write(data)
                    ents.append(entry(short(p.name), 0x20, c, len(data)))
            return b''.join(ents)

        if tree:
            root = write_dir(Path(tree), 0, None)
            assert len(root) <= rde * 32, 'too many root entries'
            d.seek(root_sec * 512)
            d.write(root)
        for i in range(nf):
            d.seek((start + rsv + i * fatsz) * 512)
            d.write(fat)


def qemu_path() -> str:
    env = os.environ.get('USOS_QEMU')
    if env:
        return env
    for cand in (REPO / 'tools/qemu/qemu-system-x86_64.exe',
                 REPO.parent / 'usos-win9x/tools/qemu/qemu-system-x86_64.exe'):
        if cand.exists():
            return str(cand)
    return 'qemu-system-x86_64'


class Monitor:
    def __init__(self, port: int):
        self.s = socket.create_connection(('127.0.0.1', port))
        self.s.settimeout(0.3)
        self.read()

    def read(self) -> bytes:
        out = b''
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                out += chunk
        except OSError:
            pass
        return out

    def cmd(self, c: str, wait: float = 0.5) -> str:
        self.s.sendall((c + '\n').encode())
        time.sleep(wait)
        return self.read().decode(errors='replace')


def cmd_run(a) -> None:
    from PIL import Image  # type: ignore
    out = Path(a.outdir)
    out.mkdir(parents=True, exist_ok=True)
    cmd = [qemu_path(), '-machine', 'pc,vmport=off', '-accel', 'tcg', '-cpu', a.cpu, '-m', str(a.mem),
           '-display', 'none', '-nic', 'none', '-rtc', 'base=localtime', '-vga', 'std',
           '-monitor', f'tcp:127.0.0.1:{a.port},server=on,wait=off',
           '-monitor', f'tcp:127.0.0.1:{a.port + 1},server=on,wait=off']
    if a.bus == 'ahci':
        cmd += ['-device', 'ahci,id=ahci', '-drive', f'if=none,id=t,format=raw,file={a.disk}',
                '-device', 'ide-hd,drive=t,bus=ahci.0']
    else:
        cmd += ['-drive', f'if=ide,index=0,format=raw,file={a.disk}']
    if a.iso:
        cmd += ['-drive', f'if=ide,index=2,media=cdrom,readonly=on,format=raw,file={a.iso}']
    cmd += ['-boot', 'order=c,once=d' if a.cd_boot else 'order=c']
    (out / f'{a.name}-cmd.txt').write_text(' '.join(cmd))
    q = subprocess.Popen(cmd, stdout=open(out / f'{a.name}-qemu.log', 'w'), stderr=subprocess.STDOUT)
    time.sleep(2)
    mon = Monitor(a.port)
    t0, i = time.time(), 0
    while time.time() - t0 < a.seconds and q.poll() is None:
        time.sleep(a.interval)
        i += 1
        ppm = out / f'{a.name}.ppm'
        try:
            mon.cmd('screendump ' + ppm.as_posix(), 2.5)
            img = Image.open(ppm)
            img.save(out / f'{a.name}-{i:03d}.png')
            img.save(out / f'{a.name}-last.png')
            img.close()
            ppm.unlink()
        except OSError as e:
            print('screenshot failed:', e)
    print('qemu exit code', q.poll())


def cmd_mon(a) -> None:
    m = Monitor(a.port)
    for c in a.cmds:
        print(m.cmd(c, 0.15))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='sub', required=True)
    s = sub.add_parser('iso')
    s.add_argument('src_iso'); s.add_argument('out_iso'); s.add_argument('--key-file', required=True)
    s.add_argument('--sp6a'); s.add_argument('--local-source', action='store_true'); s.add_argument('--ahcint'); s.add_argument('--usosrst')
    s = sub.add_parser('disk')
    s.add_argument('out_raw'); s.add_argument('--size-gb', type=int, default=4); s.add_argument('--tree')
    s = sub.add_parser('run')
    s.add_argument('name'); s.add_argument('disk'); s.add_argument('--iso')
    s.add_argument('--cd-boot', action='store_true'); s.add_argument('--cpu', default='pentium3')
    s.add_argument('--bus', choices=('ide', 'ahci'), default='ide'); s.add_argument('--mem', type=int, default=512)
    s.add_argument('--seconds', type=int, default=600); s.add_argument('--interval', type=float, default=20)
    s.add_argument('--port', type=int, default=46200); s.add_argument('--outdir', default='nt4lab-out')
    s = sub.add_parser('mon')
    s.add_argument('port', type=int); s.add_argument('cmds', nargs='+')
    a = p.parse_args()
    if a.sub == 'iso':
        cmd_iso(a)
    elif a.sub == 'disk':
        fat16_disk(Path(a.out_raw), a.size_gb, a.tree)
        print('wrote', a.out_raw)
    elif a.sub == 'run':
        cmd_run(a)
    else:
        cmd_mon(a)


if __name__ == '__main__':
    sys.exit(main())
