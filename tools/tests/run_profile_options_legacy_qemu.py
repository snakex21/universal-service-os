#!/usr/bin/env python3
"""Answer-profile options on Windows NT 4.0 and 98 SE: one QEMU install each
through the REAL micro-Linux (nested, dev PC only), then an offline check of
the installed registry hives.

Route (both families): host QEMU boots zig-out/micro-linux (kernel +
initramfs-usos + qemu9x.cpio + an overlay cpio) with the target as a scratch
qcow2 on IDE and the CD as a read-only virtio disk, like
run_nt3_micro_linux_qemu.py. The overlay carries this checkout's NT/9x
scripts (/usr/lib/usos), the answer rendered from the profile
(`usos-answer render PROFILE.ini windows-nt-4 x86 NT4.SIF` /
`... windows-98-se x86 MSBATCH.INF`, it may hold a key: keep it outside the
checkout), this checkout's usos-reg.exe (/usr/lib/usos/usos-reg.exe) and,
for 9x, the ESP helpers (zig-out/dos-native as EFI/USOS/dos-native).

  nt4   step 620's NT calls: nt4_csmwrap_target.sh, nt4_vm_install,
        nt4_vm_finish (the install runs in the inner QEMU to the first
        Administrator logon, POST.CMD -> usos-reg.exe). --boot then starts
        the finished disk once more under SeaBIOS (q35 AHCI, pentium3),
        presses Ctrl+Alt+Del + Enter at the logon and keeps screenshots
        (no "Welcome to Windows NT" dialog expected).
  98se  w9x_csmwrap_target.sh (W9X_VM_PHASE1=1) + w9x_phase1_run +
        w9x_phase1_verify (Setup phase 1 in the inner QEMU, ends at Setup's
        first restart). --boot then runs Setup phase 2 under plain SeaBIOS
        (-machine pc) for --boot-seconds with screenshots (no key in the
        profile: phase 2 stops at the key page).

check: converts the qcow2 to raw, extracts the hives with 7-Zip and checks
the expected values (NT 4.0: python-registry; 98 SE: tools/tests/w9x_creg.py).
Results go to OUT/check.txt.

    python tools/tests/run_profile_options_legacy_qemu.py nt4 --iso NT4.iso --answer NT4.SIF --out DIR --root BUILD [--boot]
    python tools/tests/run_profile_options_legacy_qemu.py 98se --iso 98SE.iso --answer MSBATCH.INF --out DIR --root BUILD [--boot]
    python tools/tests/run_profile_options_legacy_qemu.py check nt4|98se --out DIR

--qemu: a renamed copy of qemu-system-x86_64.exe inside ROOT/tools/qemu (so
only this run's processes can be stopped by PID). Scratch images only (OUT);
no physical disk is opened. Delete OUT afterwards.
"""
from __future__ import annotations

import argparse
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "uefi_drivers"))
import run_nt3_micro_linux_qemu as nt3  # noqa: E402
from run_stage_drivers_qemu import Console  # noqa: E402

SEVEN_ZIP = Path(r"C:\Program Files\7-Zip\7z.exe")

GUEST_98 = r'''#!/bin/sh
# run_profile_options_legacy_qemu.py guest part: step 620's 98 SE calls, no screens.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
TARGET=/dev/sda
SRC=/dev/vda
log() { echo "E2E: $*"; }
for m in ahci sd_mod virtio_pci virtio_blk loop isofs vfat fat nls_cp437 nls_iso8859_1 nls_utf8; do modprobe "$m" 2>/dev/null; done
sleep 2; mdev -s 2>/dev/null
[ -b "$TARGET" ] && [ -b "$SRC" ] || { log "no $TARGET or $SRC"; echo E2E-RESULT=FAIL; exit 1; }
mkdir -p /mnt/data /tmp/w9x/phase1 /run
dd if="$SRC" of=/mnt/data/source.iso bs=1M 2>/dev/null || { echo E2E-RESULT=FAIL; exit 1; }
cp /usos-e2e/msbatch.inf /run/w9x-answer.inf
log "iso $(wc -c < /mnt/data/source.iso) bytes; target script $(md5sum /usr/lib/usos/w9x_csmwrap_target.sh | cut -c1-12)"
. /usr/lib/usos/w9x_phase1_qemu.sh
vm_reason=$(w9x_vm_available 98SE) || { log "VM not available: $vm_reason"; echo E2E-RESULT=FAIL; exit 1; }
log "$vm_reason"
if ! env TARGET_DEVICE="$TARGET" W9X_SOURCE_ISO=/mnt/data/source.iso W9X_SETUP_FOLDER=WIN98 W9X_TAG=98SE \
    W9X_ANSWER_INF=/run/w9x-answer.inf W9X_ANSWER_KIND=PROFILE W9X_BOOT_FLOPPY= W9X_SIZE_GIB=2 \
    W9X_USB_DIR=/mnt/data/Drivers/none/USB W9X_TIME_ZONE="Central European" W9X_VM_PHASE1=1 \
    W9X_ESP_DIR=/usos-e2e/esp/EFI/USOS USOS_CSMWRAP_DIR=/usos-e2e/csmwrap \
    sh /usr/lib/usos/w9x_csmwrap_target.sh > /tmp/prepare.log 2>&1 < /dev/null; then
    cat /tmp/prepare.log; echo E2E-RESULT=FAIL; exit 1
fi
cat /tmp/prepare.log
accel=$(w9x_vm_accel)
w9x_phase1_progress() { log "progress elapsed=$1 written=$2MB"; }
w9x_phase1_run "$TARGET" "$accel"
vm_rc=$?
log "vm rc=$vm_rc elapsed=${W9X_VM_ELAPSED:-?}"
w9x_phase1_keep_logs /tmp/w9x/phase1
if [ "$vm_rc" != 0 ] || ! check=$(w9x_phase1_verify "$TARGET" /tmp/w9x/phase1); then
    log "phase1 FAIL ${check:-}"; ls -la /tmp/w9x/phase1; echo E2E-RESULT=FAIL; exit 1
fi
log "phase1 PASS $check"
sync
echo E2E-RESULT=PASS
'''


def overlay(family: str, answer: Path, usos_reg: Path, build: Path, csmwrap: Path, keep_default_msbatch: bool = True) -> bytes:
    entries: list[tuple[str, int, bytes]] = []
    dirs: set[str] = set()

    def add(path: str, data: bytes, mode: int = 0o100644) -> None:
        parts = path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in dirs:
                dirs.add(d)
                entries.append((d, 0o040755, b""))
        entries.append((path, mode, data))

    if family == "nt4":
        add("usos-e2e/nt3.sh", nt3.GUEST.replace("\r\n", "\n").encode(), 0o100755)
        add("usos-e2e/winnt.sif", answer.read_bytes())
    else:
        add("usos-e2e/nt3.sh", GUEST_98.replace("\r\n", "\n").encode(), 0o100755)
        add("usos-e2e/msbatch.inf", answer.read_bytes())
        dos = build / "zig-out" / "dos-native"
        for f in sorted(dos.rglob("*")):
            # win9x/MSBATCH.INF (the default answer) is copied by
            # w9x_csmwrap_target.sh AFTER the chosen answer into C:\USOS9X and
            # replaces it (2026-10-12); --no-default-msbatch leaves it out to
            # test the rendered answer itself.
            if not keep_default_msbatch and f.relative_to(dos).as_posix() == "win9x/MSBATCH.INF":
                continue
            if f.is_file() and f.name != "source.zip":
                add("usos-e2e/esp/EFI/USOS/dos-native/" + f.relative_to(dos).as_posix(), f.read_bytes())
    for f in sorted(csmwrap.rglob("*")):
        if f.is_file():
            add("usos-e2e/csmwrap/" + f.relative_to(csmwrap).as_posix(), f.read_bytes())
    add("usr/lib/usos/usos-reg.exe", usos_reg.read_bytes())
    for name in nt3.SCRIPTS + ("w9x_csmwrap_target.sh",):
        add("usr/lib/usos/" + name, (ROOT / "tools" / name).read_bytes(), 0o100755)
    return nt3.cpio_newc(entries)


def install(args, out: Path, target: Path) -> bool:
    ml = args.root / "zig-out" / "micro-linux"
    initrd = out / "initrd.cpio"
    with initrd.open("wb") as f:
        for part in ((ml / "initramfs-usos").read_bytes(), (ml / "qemu9x.cpio").read_bytes(),
                     overlay(args.family, args.answer, args.usos_reg, args.root, args.csmwrap, not args.no_default_msbatch)):
            f.write(part)
            f.write(b"\0" * (-f.tell() % 4))
    port = nt3.free_port()
    cmd = [str(args.qemu), "-machine", "q35", "-accel", "whpx", "-accel", "tcg", "-m", str(args.outer_mb), "-smp", "2",
           "-display", "none", "-nic", "none",
           "-kernel", str(ml / "vmlinuz-virt"), "-initrd", str(initrd),
           "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
           "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
           "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,cache=writeback", "-device", "ide-hd,drive=t,bus=ide.0",
           "-drive", f"file={Path(args.iso).as_posix()},format=raw,if=none,id=cd,readonly=on", "-device", "virtio-blk-pci,drive=cd"]
    stderr = (out / "outer-qemu.log").open("wb")
    q = subprocess.Popen(cmd, stderr=stderr)
    (out / "outer-qemu.pid").write_text(str(q.pid))
    print(f"outer qemu pid {q.pid}", flush=True)
    console = None
    try:
        console = Console(port)
        time.sleep(10)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s 2>/dev/null; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp /run; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run", "SETUP-DONE", 120)
        start = len(console.text)
        env = " ".join(args.env)
        tag = "TAG=NT4 NT_MAJOR=4 NT_MINOR= NT4_EDITION=" if args.family == "nt4" else ""
        console.sock.sendall(f"{env} {tag} sh /usos-e2e/nt3.sh 2>&1; echo E2E-EXIT\n".encode())
        deadline = time.time() + args.timeout
        shown = start
        while "E2E-RESULT=" not in console.text[start:] or "\nE2E-EXIT" not in console.text[start:]:
            if time.time() > deadline or q.poll() is not None:
                break
            try:
                chunk = console.sock.recv(65536)
                if chunk:
                    console.text += chunk.decode("utf-8", errors="replace")
            except socket.timeout:
                pass
            new = console.text[shown:]
            if "\n" in new:
                cut = new.rindex("\n") + 1
                for line in new[:cut].splitlines():
                    if line.startswith(("E2E", "[NT4_CSMWRAP]", "[W9X_CSMWRAP]", "run ", "answer ", "stalled", "rc=")):
                        print(line.rstrip(), flush=True)
                shown += cut
        ok = "E2E-RESULT=PASS" in console.text[start:]
        # Keep the inner VM logs (screens are PPM; small text only).
        console.run("for f in /tmp/w9x/nt4/runs.txt /tmp/w9x/nt4/POST.LOG /tmp/w9x/phase1/*.txt /tmp/w9x/phase1/*.log /tmp/w9x/phase1/*.LOG; do "
                    "[ -f \"$f\" ] && { echo \"=== $f\"; tr -d '\\r' < \"$f\" | tail -n 60; }; done", "LOGS-DONE", 60)
        console.run("sync", "SYNC-DONE", 120)
        return ok
    finally:
        if console is not None:
            (out / "console.log").write_text(console.text, encoding="utf-8")
            try:
                console.sock.sendall(b"sync; poweroff -f\n")
                q.wait(timeout=60)
            except Exception:
                pass
        if q.poll() is None:
            q.kill()
        q.wait()
        stderr.close()


def boot(args, out: Path, target: Path) -> None:
    """SeaBIOS boot of the target (pentium3, 256 MB); screenshots."""
    port = nt3.free_port()
    # NT 4.0: the finished system boots from ahcint (POST.CMD), so the disk
    # sits on q35's ICH9 AHCI as on the X470 (plain IDE: atapi.sys is not a
    # boot driver any more -> STOP 0x7B); SeaBIOS, not OVMF + CSMWrap (the RTM
    # kernel without SP6a needs an old CPU model anyway). 98 SE: i440FX IDE.
    if args.family == "nt4":
        disk = ["-machine", "q35", "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,cache=writeback",
                "-device", "ide-hd,drive=t,bus=ide.0"]
    else:
        disk = ["-machine", "pc", "-drive", f"file={target.as_posix()},format=qcow2,if=ide,index=0,cache=writeback"]
    cmd = [str(args.qemu), *disk, "-accel", "tcg", "-cpu", "pentium3", "-m", str(args.guest_mb),
           "-display", "none", "-nic", "none", "-vga", "std", "-rtc", "base=localtime",
           "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off"]
    q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=(out / "boot-qemu.log").open("wb"))
    (out / "boot-qemu.pid").write_text(str(q.pid))
    print(f"boot qemu pid {q.pid}", flush=True)
    try:
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
            except Exception:  # noqa: BLE001 - keep the ppm
                pass

        t0 = time.time()
        n = 0
        while time.time() - t0 < args.boot_seconds and q.poll() is None:
            time.sleep(30)
            n += 1
            shot(f"boot-{n:02d}")
            print(f"boot screenshot {n} at {int(time.time() - t0)} s", flush=True)
        if args.family == "nt4":
            hmp("sendkey ctrl-alt-delete", 5)
            shot("boot-cad")
            hmp("sendkey ret", 90)
            shot("boot-logon")
            hmp("sendkey ret", 30)
            shot("boot-logon2")
        # Clean shutdown is not needed for the check (hives are flushed on
        # logon); stop only this process.
    finally:
        q.kill()
        q.wait()


# ---------------------------------------------------------------- offline check

def extract(out: Path, qemu_img: Path, paths: list[str]) -> Path:
    raw = out / "target.raw"
    raw.unlink(missing_ok=True)
    subprocess.run([str(qemu_img), "convert", "-O", "raw", str(out / "target.qcow2"), str(raw)], check=True)
    dest = out / "files"
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir()
    # 7-Zip opens an MBR image with one partition as that file system; with
    # several (98 SE: C: + the CSMWrap ESP) it lists 0.fat, 1.fat, ... and the
    # first one is extracted (-tMBR) and opened.
    listing = subprocess.run([str(SEVEN_ZIP), "l", "-slt", str(raw)], capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    first = sorted(line[7:] for line in listing.splitlines() if line.startswith("Path = 0.") and "\\" not in line)
    if first and "Type = FAT" not in listing:
        part = out / "part"
        shutil.rmtree(part, ignore_errors=True)
        subprocess.run([str(SEVEN_ZIP), "e", "-tMBR", "-y", f"-o{part}", str(raw), first[0]], check=True, stdout=subprocess.DEVNULL)
        src = part / first[0]
    else:
        part, src = None, raw
    subprocess.run([str(SEVEN_ZIP), "x", "-y", f"-o{dest}", str(src), *paths], check=False, stdout=subprocess.DEVNULL)
    if part is not None:
        shutil.rmtree(part, ignore_errors=True)
    raw.unlink()
    return dest


def find_ci(base: Path, rel: str) -> Path | None:
    cur = base
    for comp in rel.replace("\\", "/").split("/"):
        if not cur.is_dir():
            return None
        match = [c for c in cur.iterdir() if c.name.lower() == comp.lower()]
        if not match:
            return None
        cur = match[0]
    return cur


def nt_value(hive: Path, key: str, name: str):
    from Registry import Registry  # type: ignore
    reg = Registry.Registry(str(hive))
    try:
        k = reg.open(key)
    except Registry.RegistryKeyNotFoundException:
        return "<no key>"
    for v in k.values():
        if v.name().lower() == name.lower():
            return (v.value_type_str(), v.value())
    return "<no value>"


def check_nt4(out: Path, qemu_img: Path) -> list[str]:
    files = extract(out, qemu_img, ["WINNT/system32/config/*", "WINNT/Profiles/*/NTUSER.DAT", "USOS/NT4/*.LOG",
                                    "USOS/NT4/*.TXT", "USOSPOST.LOG"])
    lines = []

    def res(label: str, got, want) -> None:
        ok = got == want
        lines.append(f"{'PASS' if ok else 'FAIL'}  {label}: got {got!r} want {want!r}")

    system = find_ci(files, "WINNT/system32/config/SYSTEM")
    software = find_ci(files, "WINNT/system32/config/SOFTWARE")
    default = find_ci(files, "WINNT/system32/config/DEFAULT")
    if software:
        res("HKLM\\SOFTWARE\\...\\Policies\\Explorer NoDriveTypeAutoRun", nt_value(software, r"Microsoft\Windows\CurrentVersion\Policies\Explorer", "NoDriveTypeAutoRun"), ("RegDWord", 255))
    else:
        lines.append("FAIL  no SOFTWARE hive")
    if system:
        from Registry import Registry  # type: ignore
        reg = Registry.Registry(str(system))
        sel = reg.open("Select")
        cur = [v.value() for v in sel.values() if v.name() == "Current"][0]
        res(f"HKLM\\SYSTEM\\ControlSet{cur:03d}\\Services\\Cdrom Autorun", nt_value(system, f"ControlSet{cur:03d}\\Services\\Cdrom", "Autorun"), ("RegDWord", 0))
    else:
        lines.append("FAIL  no SYSTEM hive")
    if default:
        res("HKU\\.DEFAULT Control Panel\\Keyboard InitialKeyboardIndicators", nt_value(default, r"Control Panel\Keyboard", "InitialKeyboardIndicators"), ("RegSZ", "2"))
    else:
        lines.append("FAIL  no DEFAULT hive")
    profiles = find_ci(files, "WINNT/Profiles")
    names = sorted(p.name for p in profiles.iterdir()) if profiles else []
    lines.append(f"INFO  profiles: {names}")
    for prof in ("Default User", "Administrator"):
        hive = find_ci(files, f"WINNT/Profiles/{prof}/NTUSER.DAT")
        if hive is None:
            lines.append(f"FAIL  no {prof}\\NTUSER.DAT")
            continue
        res(f"{prof} NTUSER Explorer\\Tips Show", nt_value(hive, r"Software\Microsoft\Windows\CurrentVersion\Explorer\Tips", "Show"), ("RegDWord", 0))
        res(f"{prof} NTUSER Control Panel\\Keyboard InitialKeyboardIndicators", nt_value(hive, r"Control Panel\Keyboard", "InitialKeyboardIndicators"), ("RegSZ", "2"))
        # Stage 2 (2026-10-14).
        res(f"{prof} NTUSER Explorer link", nt_value(hive, r"Software\Microsoft\Windows\CurrentVersion\Explorer", "link"), ("RegBin", bytes(4)))
        res(f"{prof} NTUSER WindowMetrics MinAnimate", nt_value(hive, r"Control Panel\Desktop\WindowMetrics", "MinAnimate"), ("RegSZ", "0"))
        res(f"{prof} NTUSER Mouse MouseSpeed", nt_value(hive, r"Control Panel\Mouse", "MouseSpeed"), ("RegSZ", "0"))
    if system:
        res(f"HKLM\\SYSTEM\\ControlSet{cur:03d}\\Control\\FileSystem NtfsDisableLastAccessUpdate", nt_value(system, f"ControlSet{cur:03d}\\Control\\FileSystem", "NtfsDisableLastAccessUpdate"), ("RegDWord", 1))
    for rel in ("USOS/NT4/USOS-REG.LOG", "USOS/NT4/POST.LOG"):
        p = find_ci(files, rel)
        text = p.read_bytes().decode("cp1250", errors="replace") if p else "<missing>"
        lines.append(f"INFO  === {rel}\n{text.rstrip()}")
    post = find_ci(files, "USOS/NT4/POST.LOG")
    ptxt = post.read_bytes().decode("cp1250", errors="replace") if post else ""
    lines.append(f"{'PASS' if 'profile registry set applied 0' in ptxt else 'FAIL'}  POST.LOG 'profile registry set applied 0'")
    lines.append(f"{'PASS' if find_ci(files, 'USOS/NT4/USOS-REG.TXT') is None else 'FAIL'}  USOS-REG.TXT deleted after apply")
    return lines


def check_98se(out: Path, qemu_img: Path) -> list[str]:
    import w9x_creg
    files = extract(out, qemu_img, ["WINDOWS/USER.DAT", "WINDOWS/SYSTEM.DAT", "WINDOWS/SYSTEM.INI", "WINDOWS/SETUPLOG.TXT"])
    lines = []
    user = find_ci(files, "WINDOWS/USER.DAT")
    system = find_ci(files, "WINDOWS/SYSTEM.DAT")
    if user is None or system is None:
        return [f"FAIL  hives missing (USER.DAT {user}, SYSTEM.DAT {system})"]
    u = w9x_creg.Hive(user.read_bytes())
    s = w9x_creg.Hive(system.read_bytes())

    def res(label: str, got, want) -> None:
        lines.append(f"{'PASS' if got == want else 'FAIL'}  {label}: got {got!r} want {want!r}")

    adv = r"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    pol = r"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    tips_key = r"Software\Microsoft\Windows\CurrentVersion\Explorer\Tips"
    vnetsup = r"System\CurrentControlSet\Services\VxD\VNETSUP"
    # USER.DAT holds HKEY_USERS: Setup's HKCU writes land in .DEFAULT (no user
    # profiles yet), the template of every user.
    p = ".DEFAULT\\"
    res("USER.DAT .DEFAULT Explorer\\Advanced HideFileExt", u.value(p + adv, "HideFileExt"), (3, bytes.fromhex("00000000")))
    res("USER.DAT .DEFAULT Explorer\\Advanced Hidden", u.value(p + adv, "Hidden"), (3, bytes.fromhex("01000000")))
    res("USER.DAT .DEFAULT Policies\\Explorer NoDriveTypeAutoRun", u.value(p + pol, "NoDriveTypeAutoRun"), (3, bytes.fromhex("ff000000")))
    superhidden = u.value(p + adv, "ShowSuperHidden")
    lines.append(f"{'PASS' if superhidden is None else 'FAIL'}  show_protected not rendered for 98 (ShowSuperHidden absent): {superhidden!r}")
    tips = u.value(p + tips_key, "Show")
    lines.append(f"{'PASS' if tips is None else 'FAIL'}  no_tips not rendered for 98 (Explorer\\Tips Show absent): {tips!r}")
    lines.append(f"INFO  USER.DAT .DEFAULT Explorer\\Advanced values: {u.values(p + adv)}")
    # Stage 2 (2026-10-14): shortcut naming, visual effects, mouse acceleration.
    res("USER.DAT .DEFAULT Explorer link", u.value(p + r"Software\Microsoft\Windows\CurrentVersion\Explorer", "link"), (3, bytes.fromhex("00000000")))
    res("USER.DAT .DEFAULT WindowMetrics MinAnimate", u.value(p + r"Control Panel\Desktop\WindowMetrics", "MinAnimate"), (1, b"0"))
    res("USER.DAT .DEFAULT Desktop DragFullWindows", u.value(p + r"Control Panel\Desktop", "DragFullWindows"), (1, b"0"))
    for name in ("MouseSpeed", "MouseThreshold1", "MouseThreshold2"):
        res(f"USER.DAT .DEFAULT Mouse {name}", u.value(p + r"Control Panel\Mouse", name), (1, b"0"))
    # Win9x stores REG_SZ without the terminating NUL.
    res("SYSTEM.DAT VxD\\VNETSUP Workgroup", s.value(vnetsup, "Workgroup"), (1, b"USOSLAB"))
    lines.append(f"INFO  SYSTEM.DAT VNETSUP values: {s.values(vnetsup)}")
    runonce = s.values(r"Software\Microsoft\Windows\CurrentVersion\RunOnce") or []
    lines.append(f"INFO  SYSTEM.DAT RunOnce USOSWelcome (msbatch [Install] ran): {[v for v in runonce if v[0] == 'USOSWelcome']}")
    tips = s.value(r"Software\Microsoft\Windows\CurrentVersion\Explorer\Tips", "Show")
    lines.append(f"INFO  SYSTEM.DAT Explorer\\Tips Show (HKLM, not rendered for 98): {tips!r}")
    return lines


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("family", choices=["nt4", "98se", "check"])
    p.add_argument("check_family", nargs="?", choices=["nt4", "98se"])
    p.add_argument("--iso")
    p.add_argument("--answer", type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--root", type=Path, default=ROOT, help="checkout with zig-out (micro-linux, dos-native) and tools/qemu")
    p.add_argument("--csmwrap", type=Path,
                   help="built CSMWrap folder with licences/source/patches; xp_csmwrap_esp.sh checks the pinned hash "
                        "(default ROOT/zig-out/usb/EFI/USOS/csmwrap)")
    p.add_argument("--qemu", type=Path, help="renamed qemu-system-x86_64.exe copy (in ROOT/tools/qemu)")
    p.add_argument("--usos-reg", type=Path, default=ROOT / "zig-out/windows-usos-reg/usos-reg.exe")
    p.add_argument("--outer-mb", type=int, default=1536, help="micro-Linux host VM RAM (holds the ISO in RAM)")
    p.add_argument("--guest-mb", type=int, default=256, help="Windows guest RAM (inner VM and --boot)")
    p.add_argument("--timeout", type=int, default=7200)
    p.add_argument("--env", action="append", default=[])
    p.add_argument("--no-default-msbatch", action="store_true",
                   help="98se: leave the ESP's default win9x/MSBATCH.INF out (it overwrites the rendered answer)")
    p.add_argument("--boot", action="store_true")
    p.add_argument("--boot-only", action="store_true")
    p.add_argument("--boot-seconds", type=int, default=420)
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    qemu_img = args.root / "tools" / "qemu" / "qemu-img.exe"
    if args.family == "check":
        lines = check_nt4(args.out, qemu_img) if args.check_family == "nt4" else check_98se(args.out, qemu_img)
        text = "\n".join(lines)
        (args.out / "check.txt").write_text(text + "\n", encoding="utf-8")
        print(text)
        return 0 if not any(line.startswith("FAIL") for line in lines) else 1
    args.csmwrap = args.csmwrap or args.root / "zig-out" / "usb" / "EFI" / "USOS" / "csmwrap"
    args.qemu = args.qemu or args.root / "tools" / "qemu" / "qemu-system-x86_64.exe"
    args.env += [f"NT4_VM_MB={args.guest_mb}", f"W9X_VM_GUEST_MB={args.guest_mb}"]
    target = args.out / "target.qcow2"
    if not args.boot_only:
        if args.answer is None or args.iso is None:
            raise SystemExit("--iso and --answer are required")
        target.unlink(missing_ok=True)
        subprocess.run([str(qemu_img), "create", "-q", "-f", "qcow2", str(target), "4G" if args.family == "98se" else "8G"], check=True)
        ok = install(args, args.out, target)
        print(f"[{'PASS' if ok else 'FAIL'}] {args.family} install through micro-Linux (console.log)")
        if not ok:
            return 1
    if args.boot or args.boot_only:
        boot(args, args.out, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
