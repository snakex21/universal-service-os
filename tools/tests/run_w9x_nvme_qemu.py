#!/usr/bin/env python3
"""usosnvme.mpd (Windows 9x NVMe miniport) QEMU checks, dev PC only.

Starts from a Windows 98 SE disk whose Setup phase 1 already ran (the
target.qcow2 that run_w9x_micro_linux_qemu.py 98se leaves in its OUT),
copies it (the base stays untouched) and writes into its C: (FAT32 at LBA
2048, host side, pyfatfs):

  C:\\WINDOWS\\INF\\USOSNVME.INF, C:\\WINDOWS\\SYSTEM\\IOSUBSYS\\USOSNVME.MPD,
  C:\\WIN98\\USOSNVME.MPD (the INF's copy source), C:\\USOS9X\\NVTEST.EXE
  (tools/tests/w9x_nvme/nvtest.c) and, with --shell, SYSTEM.INI
  [boot] shell=C:\\USOS9X\\NVTEST.EXE <drive> /S /Q

  data   i440FX + SeaBIOS like the phase-1 VM: the 98 disk on IDE, a second
         disk on -device nvme (MBR + FAT32 made here) -> NVTEST writes and
         compares 64 MiB on it; afterwards the host reads every file back
         from the NVMe image and compares FAT 1 with FAT 2
  boot   the same disk as the ONLY disk, on NVMe behind a pcie-root-port,
         q35 + OVMF + the build's CSMWrap (as run_w9x_micro_linux_qemu.py
         --boot); NVTEST runs on C:

Port E9h goes to OUT/e9.log (usosnvme's own lines start with "USOSNVME"),
screenshots every --shot-seconds. Ends on "NVTEST shutdown" (+20 s), the
timeout or OUT/STOP. Only this run's QEMU is stopped (by PID).

    python tools/tests/run_w9x_nvme_qemu.py data --base PREP/target.qcow2 --out DIR [--shell] [--lba 4096]
    python tools/tests/run_w9x_nvme_qemu.py boot --base PREP/target.qcow2 --out DIR --root BUILD [--shell]
"""
from __future__ import annotations

import argparse
import shutil
import socket
import subprocess
import sys
import time
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "w9x_nvme"))
import run_nt3_micro_linux_qemu as nt3  # noqa: E402

PART = 2048 * 512
SIZES = (512, 4096, 4608, 65536, 131072, 131584, 200704, 1048576 + 4096, 4194304, 8388608 + 512, 16777216, 33554432)


def expected(idx: int, size: int) -> bytes:
    """nvtest.c's generator: xorshift32 seeded (idx + 1) * 0x9E3779B9, 4 bytes LE per step, per write chunk."""
    out = bytearray()
    chunk = 196608 + 512
    left = size
    x = ((idx + 1) * 0x9E3779B9) & 0xFFFFFFFF or 1
    while left:
        n = min(left, chunk)
        x0 = x
        buf = bytearray(n)
        for i in range(0, n - n % 4, 4):
            x0 ^= (x0 << 13) & 0xFFFFFFFF
            x0 ^= x0 >> 17
            x0 ^= (x0 << 5) & 0xFFFFFFFF
            buf[i:i + 4] = x0.to_bytes(4, "little")
        x = x0
        out += buf
        left -= n
    return bytes(out)


def fat_open(img: Path, offset: int, read_only: bool = False):
    from pyfatfs.PyFatFS import PyFatFS
    return PyFatFS(str(img), offset=offset, read_only=read_only, preserve_case=False)


def inject(img: Path, args) -> None:
    mpd = ROOT / "tools/nt/usosnvme/bin/W9X/usosnvme.mpd"
    inf = ROOT / "tools/nt/usosnvme/usosnvme9x.inf"
    sys.path.insert(0, str(HERE / "w9x_nvme"))
    from build_nvtest import build, wdk_root
    exe = build(args.out / "nvtest-build", wdk_root(None))
    fs = fat_open(img, PART)
    try:
        def put(path: str, data: bytes) -> None:
            with fs.openbin(path, "w") as f:
                f.write(data)
        put("/WINDOWS/INF/USOSNVME.INF", inf.read_bytes())
        put("/WINDOWS/SYSTEM/IOSUBSYS/USOSNVME.MPD", mpd.read_bytes())
        if fs.exists("/WIN98"):
            put("/WIN98/USOSNVME.MPD", mpd.read_bytes())
            put("/WIN98/USOSNVME.INF", inf.read_bytes())
        put("/USOS9X/NVTEST.EXE", exe.read_bytes())
        if args.verify_only:
            # NVTEST compares the files an earlier start left on the kept
            # data disk (read from the disk through usosnvme, not the cache)
            put("/USOS9X/NVTEST.VFY", b"verify")
        if args.shell:
            ini = fs.readbytes("/WINDOWS/SYSTEM.INI").decode("latin-1")
            (args.out / "SYSTEM.INI.orig").write_text(ini, encoding="latin-1")
            drive = "C" if args.mode == "boot" else "D"
            lines = []
            for line in ini.split("\r\n"):
                if line.lower().startswith("shell="):
                    line = f"shell=C:\\USOS9X\\NVTEST.EXE {drive} /S /Q"
                lines.append(line)
            put("/WINDOWS/SYSTEM.INI", "\r\n".join(lines).encode("latin-1"))
        if args.regbind:
            drive = "C" if args.mode == "boot" else "D"
            put("/USOS9X/NVTEST.REG", REGBIND.replace("@DRIVE@", drive).replace("\n", "\r\n").encode("latin-1"))
            put("/USOS9X/NVREG.BAT", NVREG_BAT.replace("\n", "\r\n").encode("latin-1"))
            auto = fs.readbytes("/AUTOEXEC.BAT")
            if b"NVREG.BAT" not in auto:
                put("/AUTOEXEC.BAT", b"@CALL C:\\USOS9X\\NVREG.BAT\r\n" + auto)
        for name in ("/WINDOWS/IOS.LOG", "/NVTEST.LOG", "/USOS9X/NVREG.OK", "/USOS9X/NVCHK.REG"):
            if fs.exists(name):
                fs.remove(name)
    finally:
        fs.close()


# --regbind: the 98 SE first-run wizard (product key) comes before Windows'
# PnP hardware setup, so without a key the PCI NVMe function never gets its
# INF-bound devnode. This registers usosnvme.mpd on a Root-enumerated SCSI
# adapter devnode instead (the W9X build scans PCI itself, like the NT4
# build), and NVTEST as a RunServices program, which Windows starts before
# the wizard. Imported once by real-mode REGEDIT from AUTOEXEC.BAT (as
# tools/w9x_vesa95.sh does). Test only: the shipped flow binds through
# USOSNVME.INF (PCI\CC_010802 / the PC's PCI ID).
REGBIND = r"""REGEDIT4

[HKEY_LOCAL_MACHINE\Enum\Root\SCSIAdapter\0000]
"Class"="SCSIAdapter"
"Driver"="SCSIAdapter\\0000"
"DeviceDesc"="USOS NVMe Controller (usosnvme)"
"Mfg"="USOS"
"HardwareID"="USOSNVME"
"ConfigFlags"=hex:00,00,00,00

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class\SCSIAdapter\0000]
"DevLoader"="*IOS"
"PortDriver"="usosnvme.mpd"
"DriverDesc"="USOS NVMe Controller (usosnvme)"
"DontLoadIfConflict"="Y"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunServices]
"USOSNVT"="C:\\USOS9X\\NVTEST.EXE @DRIVE@"

"""

NVREG_BAT = r"""@ECHO OFF
IF EXIST C:\USOS9X\NVREG.OK GOTO END
C:
CD \WINDOWS
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H USER.DAT
REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\NVTEST.REG
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\NVCHK.REG HKEY_LOCAL_MACHINE\Enum\Root\SCSIAdapter
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT
ECHO ok> C:\USOS9X\NVREG.OK
CD \
:END
"""


def make_data_disk(img: Path, mib: int, lba: int) -> None:
    """MBR + one FAT32 partition (type 0Ch) at 1 MiB."""
    from pyfatfs.PyFat import PyFat
    part = img.with_suffix(".part")
    size = (mib - 1) * 1024 * 1024
    with part.open("wb") as f:
        f.truncate(size)
    pf = PyFat()
    pf.mkfs(str(part), PyFat.FAT_TYPE_FAT32, size=size, label="NVMEDATA")
    pf.close()
    data = bytearray(part.read_bytes())
    data[0x1C:0x20] = (2048).to_bytes(4, "little")   # hidden sectors
    data[0x18:0x1A] = (63).to_bytes(2, "little")
    data[0x1A:0x1C] = (255).to_bytes(2, "little")
    data[0x40] = 0x80                                 # BIOS drive number
    part.unlink()
    mbr = bytearray(512)
    sectors = size // 512
    mbr[446:462] = bytes([0x00, 0xFE, 0xFF, 0xFF, 0x0C, 0xFE, 0xFF, 0xFF]) + (2048).to_bytes(4, "little") + sectors.to_bytes(4, "little")
    mbr[440:444] = (0x55534F53).to_bytes(4, "little")
    mbr[510:512] = b"\x55\xaa"
    with img.open("wb") as f:
        f.write(mbr)
        f.write(b"\0" * (PART - 512))
        f.write(data)
        f.truncate(mib * 1024 * 1024)


def verify_data(img: Path, out: Path) -> bool:
    ok = True
    report = []
    raw = img.read_bytes()
    bpb = raw[PART:PART + 512]
    rsvd = int.from_bytes(bpb[14:16], "little")
    nfat = bpb[16]
    fatsz = int.from_bytes(bpb[36:40], "little")
    f1 = raw[PART + rsvd * 512:PART + (rsvd + fatsz) * 512]
    f2 = raw[PART + (rsvd + fatsz) * 512:PART + (rsvd + 2 * fatsz) * 512]
    same = nfat < 2 or f1[8:] == f2[8:]
    report.append(f"FAT copies identical: {same}")
    ok &= same
    fs = fat_open(img, PART, read_only=True)
    try:
        for i, size in enumerate(SIZES):
            name = f"/NVT/F{i:02d}.BIN"
            if not fs.exists(name):
                report.append(f"{name}: missing")
                ok = False
                continue
            got = fs.readbytes(name)
            good = got == expected(i, size)
            report.append(f"{name}: {len(got)} B {'OK' if good else 'MISMATCH'}")
            ok &= good
    finally:
        fs.close()
    (out / "verify.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))
    return ok


def run_qemu(cmd: list[str], out: Path, args, port: int) -> None:
    q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=(out / "qemu.log").open("wb"))
    (out / "qemu.pid").write_text(str(q.pid))
    print(f"qemu pid {q.pid}", flush=True)
    e9 = out / "e9.log"
    try:
        mon = None
        for _ in range(100):
            try:
                mon = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                time.sleep(0.2)
        mon.settimeout(0.5)

        def hmp(text: str, wait: float = 0.5) -> None:
            mon.sendall(text.encode() + b"\n")
            time.sleep(wait)
            try:
                while mon.recv(65536):
                    pass
            except OSError:
                pass

        def shot(name: str) -> None:
            ppm = out / f"{name}.ppm"
            hmp(f'screendump "{ppm.as_posix()}"', 2)
            try:
                from PIL import Image
                Image.open(ppm).save(out / f"{name}.png")
                ppm.unlink()
            except Exception:  # noqa: BLE001
                pass

        t0 = time.time()
        n = 0
        done_at = None
        last = 0.0
        while time.time() - t0 < args.seconds and q.poll() is None:
            time.sleep(2)
            text = e9.read_text(encoding="latin-1", errors="replace") if e9.exists() else ""
            if done_at is None and ("NVTEST shutdown" in text or (args.regbind and "NVTEST RESULT=" in text)):
                done_at = time.time()
            if done_at and time.time() - done_at > 20:
                shot("final")
                break
            if time.time() - last >= args.shot_seconds:
                last = time.time()
                n += 1
                shot(f"shot-{n:02d}")
            if (out / "STOP").exists():
                shot("stop")
                break
        try:
            hmp("quit", 3)
        except OSError:
            pass
    finally:
        if q.poll() is None:
            try:
                q.wait(timeout=20)
            except subprocess.TimeoutExpired:
                q.kill()
        q.wait()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["data", "boot"])
    p.add_argument("--base", required=True, type=Path, help="phase-1 98 SE disk (qcow2)")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--root", type=Path, default=ROOT, help="checkout with tools/qemu (and zig-out for boot)")
    p.add_argument("--shell", action="store_true", help="NVTEST as the Windows shell (runs, ScanDisk, shuts down)")
    p.add_argument("--regbind", action="store_true", help="no key: Root devnode for usosnvme + RunServices NVTEST (see REGBIND)")
    p.add_argument("--verify-only", action="store_true", help="NVTEST only compares (use with --keep-data)")
    p.add_argument("--keep-data", action="store_true", help="data: keep OUT/nvme.img of an earlier run")
    p.add_argument("--no-inject", action="store_true", help="reuse OUT/disk.img as it is (a second start)")
    p.add_argument("--lba", type=int, default=512, help="data disk logical block size (negative test: 4096)")
    p.add_argument("--data-mib", type=int, default=512)
    p.add_argument("--seconds", type=int, default=2400)
    p.add_argument("--shot-seconds", type=int, default=60)
    p.add_argument("--accel", default="tcg")
    args = p.parse_args()
    nt3.set_root(args.root)
    args.out.mkdir(parents=True, exist_ok=True)
    disk = args.out / "disk.img"
    (args.out / "e9.log").unlink(missing_ok=True)
    if not args.no_inject:
        disk.unlink(missing_ok=True)
        subprocess.run([str(nt3.QEMU_IMG), "convert", "-O", "raw", str(args.base), str(disk)], check=True)
        inject(disk, args)
    port = nt3.free_port()
    e9 = ["-chardev", f"file,id=e9,path={(args.out / 'e9.log').as_posix()}", "-device", "isa-debugcon,iobase=0xe9,chardev=e9"]
    mon = ["-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off"]
    if args.mode == "data":
        data = args.out / "nvme.img"
        if not args.no_inject and not args.keep_data:
            make_data_disk(data, args.data_mib, args.lba)
        cmd = [str(nt3.QEMU), "-machine", "pc,acpi=off", "-accel", args.accel, "-cpu", "pentium3", "-smp", "1", "-m", "512",
               "-rtc", "base=localtime", "-vga", "std", "-display", "none", "-nic", "none",
               "-drive", f"file={disk.as_posix()},format=raw,if=ide,index=0,media=disk",
               "-drive", f"file={data.as_posix()},format=raw,if=none,id=n0",
               "-device", f"nvme,drive=n0,serial=USOS9XDATA,logical_block_size={args.lba},physical_block_size={args.lba}",
               "-boot", "order=c", *e9, *mon]
        run_qemu(cmd, args.out, args, port)
        if args.lba == 512 and (args.shell or args.regbind):
            ok = verify_data(data, args.out)
            print(f"[{'PASS' if ok else 'FAIL'}] host read-back of the NVMe data disk")
    else:
        vars_ = args.out / "vars.fd"
        shutil.copyfile(nt3.OVMF_VARS, vars_)
        # CSMWrap ESP of the prepared disk is already on it (xp_csmwrap_esp.sh)
        cmd = [str(nt3.QEMU), "-machine", "q35", "-accel", "tcg", "-cpu", "EPYC-Rome", "-smp", "2", "-m", "1024",
               "-drive", f"if=pflash,unit=0,format=raw,readonly=on,file={nt3.OVMF_CODE.as_posix()}",
               "-drive", f"if=pflash,unit=1,format=raw,file={vars_.as_posix()}",
               "-drive", f"file={disk.as_posix()},format=raw,if=none,id=t",
               "-device", "pcie-root-port,id=rpn,chassis=20,slot=20", "-device", "nvme,drive=t,serial=W9X-NVME-TARGET,bus=rpn",
               "-display", "none", "-nic", "none", "-vga", "std", "-rtc", "base=localtime",
               "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0", *e9, *mon]
        run_qemu(cmd, args.out, args, port)
    text = (args.out / "e9.log").read_text(encoding="latin-1", errors="replace") if (args.out / "e9.log").exists() else ""
    print("--- e9.log (usosnvme / NVTEST lines)")
    for line in text.splitlines():
        if line.startswith(("USOSNVME", "NVTEST")):
            print(line)
    fs = fat_open(disk, PART, read_only=True)
    try:
        for name in ("/WINDOWS/IOS.LOG", "/NVTEST.LOG"):
            if fs.exists(name):
                data = fs.readbytes(name)
                (args.out / Path(name).name).write_bytes(data)
                print(f"--- {name}\n{data.decode('latin-1', errors='replace')[:3000]}")
            else:
                print(f"--- {name}: not present")
    finally:
        fs.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
