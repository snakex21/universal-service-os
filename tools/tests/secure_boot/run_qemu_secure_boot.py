#!/usr/bin/env python3
"""USOS Secure Boot chain in QEMU with Microsoft keys enrolled.

Uses Fedora's SMM OVMF (fetch_ovmf_secboot.py) and a read-only QEMU vvfat
ESP built from the release layout in zig-out/usb. No physical disk is used.

Scenarios (each prints [PASS]/[FAIL]):

  unsigned     shim + an UNSIGNED grubx64.efi: shim must refuse it and open
               MokManager ("Verification failed").
  enroll       signed USOS, empty MOK: MokManager opens; the USOS
               certificate is enrolled with keystrokes ("Enroll key from
               disk"), the machine reboots and USOS starts under Secure Boot.
  unsigned-mok the same enrolled NVRAM, unsigned grubx64.efi: still refused.
  probe        the enrolled NVRAM, grubx64.efi = the signed Secure Boot
               probe (secure_boot_probe_main.zig): signed child starts,
               unsigned child is rejected, the signed NTFS driver starts, the
               signed kernel loads, and systemd-boot boots micro-Linux.
  noauth       MokNew WITHOUT MokAuth (a password-less request): MokManager
               refuses to enroll ("Failed to get MokAuth"), USOS stays refused.
  wait         MokTimeout = -1 (the installer's "Prepare"): after
               "Verification failed" MokManager shows its menu with no
               countdown and waits; Enroll key from disk -> USOS_ESP ->
               USOS-KEY.cer (ESP root) -> Continue -> Yes -> Reboot starts USOS.
  direct       Secure Boot OFF with the Microsoft PK/KEK/db and a MokList that
               already holds another key: the probe runs mok_key.save() (the
               menu's "Add the key"), MokList stays NV|BS with both keys; then
               Secure Boot ON: shim starts USOS with no MokManager at all.

    python tools/tests/secure_boot/run_qemu_secure_boot.py [--keep-screens]

Needs the signing key (%APPDATA%\\USOS\\signing) for the probe and child
fixtures; the release layout must come from build.bat.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
from boot_ui_screens import QEMU, Monitor, free_port  # noqa: E402

CACHE = ROOT / "tools" / "cache" / "secure-boot"
WORK = ROOT / "tools" / "tests" / "artifacts" / "secure-boot"
USB = ROOT / "zig-out" / "usb"
INSTALLER = ROOT / "installer"
SBAT = ROOT / "assets" / "secure-boot" / "usos.sbat.csv"
CERT_NAME = "ENROLL_THIS_KEY_IN_MOKMANAGER.cer"
ROOT_CERT_NAME = "USOS-KEY.cer"
SHIM_GUID = "605dab50-e046-4300-abb6-3dd810dd8b23"


def efisign(*args: str) -> None:
    subprocess.run(["go", "run", "./cmd/usos-efisign", *args], cwd=INSTALLER, check=True)


def serial_text(path: Path) -> str:
    return path.read_text(errors="replace") if path.exists() else ""


def wait_for(path: Path, needles: list[str], timeout: float) -> str | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = serial_text(path)
        for needle in needles:
            if needle in text:
                return needle
        time.sleep(0.5)
    return None


class Machine:
    def __init__(self, name: str, esp: Path, vars_file: Path, keep_screens: bool):
        self.name = name
        self.serial = WORK / f"{name}.serial.log"
        self.keep_screens = keep_screens
        self.shots = 0
        if self.serial.exists():
            self.serial.unlink()
        port = free_port()
        args = [
            str(QEMU), "-name", f"USOS-SB-{name}",
            "-machine", "q35,smm=on", "-accel", "tcg,thread=multi", "-cpu", "max", "-m", "2048", "-smp", "2",
            "-global", "driver=cfi.pflash01,property=secure,value=on",
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={(CACHE / 'OVMF_CODE.secboot.fd').as_posix()}",
            "-drive", f"if=pflash,format=raw,unit=1,file={vars_file.as_posix()}",
            "-nic", "none", "-display", "none", "-vga", "std",
            "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
            "-serial", f"file:{self.serial.as_posix()}",
            "-drive", f"if=none,id=esp,format=raw,snapshot=on,file=fat:{esp.as_posix()}",
            "-device", "ide-hd,bus=ide.0,drive=esp,bootindex=1",
        ]
        self.stderr = open(WORK / f"{name}.qemu.stderr.log", "wb")
        self.process = subprocess.Popen(args, stderr=self.stderr)
        self.monitor = Monitor(port)

    def shot(self, label: str) -> None:
        if not self.keep_screens or self.process.poll() is not None:
            return
        self.shots += 1
        try:
            self.monitor.shot(WORK / f"{self.name}-{self.shots:02d}-{label}.png")
        except (OSError, RuntimeError) as error:
            print(f"[INFO] screenshot {label} skipped: {error}")

    def keys(self, *names: str, pause: float = 1.5) -> None:
        for name in names:
            self.monitor.key(name, pause)

    def stop(self) -> None:
        if self.process.poll() is None:
            try:
                self.monitor.command("quit")
            except OSError:
                pass
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.stderr.close()


def esp_tree(name: str, second_stage: Path, extra: dict[str, Path] | None = None) -> Path:
    """Copy the release ESP (without DATA) and replace the second stage."""
    target = WORK / f"esp-{name}"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(USB / "EFI", target / "EFI")
    if (USB / ROOT_CERT_NAME).exists():
        shutil.copyfile(USB / ROOT_CERT_NAME, target / ROOT_CERT_NAME)
    shutil.copyfile(second_stage, target / "EFI" / "BOOT" / "grubx64.efi")
    for relative, source in (extra or {}).items():
        path = target / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, path)
    return target


def unsigned_usos() -> Path:
    """Prepare() output: USOS with .sbat and padding, no signature."""
    source = ROOT / "zig-out" / "manual-usb" / "EFI" / "BOOT" / "BOOTX64.EFI"
    out = WORK / "grubx64-unsigned.efi"
    img = subprocess.run(["go", "run", "./cmd/usos-efisign", "derive-check", "-unsigned", str(source), "-signed", str(USB / "EFI" / "BOOT" / "grubx64.efi"), "-sbat", str(SBAT)], cwd=INSTALLER, capture_output=True, text=True)
    if img.returncode != 0:
        raise SystemExit("release grubx64.efi does not derive from manual-usb BOOTX64.EFI: " + img.stderr)
    # A byte copy of the unsigned build output is refused by shim both for the
    # missing signature and the missing .sbat; derive-check proved the signed
    # file is that output plus .sbat, so strip only the certificate table.
    data = bytearray((USB / "EFI" / "BOOT" / "grubx64.efi").read_bytes())
    pe = int.from_bytes(data[0x3C:0x40], "little")
    opt = pe + 24
    directory = opt + (112 if int.from_bytes(data[opt:opt + 2], "little") == 0x20B else 96) + 4 * 8
    offset = int.from_bytes(data[directory:directory + 4], "little")
    if offset:
        del data[offset:]
        data[directory:directory + 8] = bytes(8)
    out.write_bytes(bytes(data))
    return out


def fresh_vars(name: str) -> Path:
    path = WORK / f"vars-{name}.fd"
    shutil.copyfile(CACHE / "OVMF_VARS.secboot.fd", path)
    return path


def expect(result: bool, label: str, failures: list[str]) -> None:
    print(("[PASS] " if result else "[FAIL] ") + label, flush=True)
    if not result:
        failures.append(label)


def scenario_unsigned(args, failures: list[str]) -> None:
    esp = esp_tree("unsigned", unsigned_usos())
    machine = Machine("unsigned", esp, fresh_vars("unsigned"), args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["USOS MANUAL FLOW BOOT PASS", "Verification failed", "Security Violation"], 180)
        time.sleep(3)
        machine.shot("shim-refuses")
        expect(hit in ("Verification failed", "Security Violation"), "shim refuses an unsigned grubx64.efi under Secure Boot", failures)
        expect("USOS MANUAL FLOW BOOT PASS" not in serial_text(machine.serial), "unsigned USOS never started", failures)
    finally:
        machine.stop()


# MokManager (shim 16.1), verified with screenshots on 2026-09-24:
#   "Verification failed: (0x1A) Security Violation" [OK]    -> Enter
#   10 s countdown "Press any key to perform MOK management"  -> Space
#   Continue boot / Enroll key from disk / Enroll hash ...   -> Down, Enter
#   volume list: one vvfat volume                            -> Enter
#   /: EFI/                                                  -> Enter
#   EFI/: ../ BOOT/ USOS/                                    -> Down x2, Enter
#   EFI/USOS/: ../ build-info.ini ENROLL-README.txt
#              ENROLL_THIS_KEY_IN_MOKMANAGER.cer licenses/ ... -> Down x3, Enter
#   [Enroll MOK] View key 0 / Continue                       -> Down, Enter
#   Enroll the key(s)? No / Yes                              -> Down, Enter
#   Perform MOK management: Reboot / ...                     -> Enter
ENROLL_KEYS = [
    ["ret"], ["spc"], ["down", "ret"], ["ret"], ["ret"], ["down", "down", "ret"],
    ["down", "down", "down", "ret"], ["down", "ret"], ["down", "ret"], ["ret"],
]
ENROLL_LABELS = ["dismissed", "mok-management", "select-volume", "root", "efi", "usos",
                 "enroll-mok", "enroll-question", "enrolled", "reboot"]


def scenario_enroll(args, failures: list[str]) -> Path:
    vars_file = fresh_vars("enroll")
    esp = esp_tree("enroll", USB / "EFI" / "BOOT" / "grubx64.efi")
    machine = Machine("enroll", esp, vars_file, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["Verification failed", "Security Violation", "USOS MANUAL FLOW BOOT PASS"], 180)
        expect(hit in ("Verification failed", "Security Violation"), "signed USOS with an empty MOK list opens MokManager", failures)
        time.sleep(2)
        machine.shot("verification-failed")
        for keys, label in zip(ENROLL_KEYS, ENROLL_LABELS):
            machine.keys(*keys, pause=1.0)
            time.sleep(1.5)
            if label != "reboot":
                machine.shot(label)
        started = wait_for(machine.serial, ["[SECURE_BOOT] state="], 240)
        time.sleep(4)
        machine.shot("usos-after-enroll")
        text = serial_text(machine.serial)
        expect(started is not None and "USOS MANUAL FLOW BOOT PASS" in text, "after enrollment shim starts the MOK-signed USOS", failures)
        expect("[SECURE_BOOT] state=on shim_lock=yes shim_loader=yes" in text, "USOS reports Secure Boot on with shim 16 protocols", failures)
    finally:
        machine.stop()
    return vars_file


def scenario_timeout(args, failures: list[str]) -> None:
    """One OK press, then nothing: MokManager's 10 s countdown must be shown,
    and after it expires shim retries grubx64.efi and gives up."""
    esp = esp_tree("timeout", USB / "EFI" / "BOOT" / "grubx64.efi")
    machine = Machine("timeout", esp, fresh_vars("timeout"), args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["Verification failed", "Security Violation"], 180)
        expect(hit is not None, "timeout: shim refuses the not-yet-enrolled USOS", failures)
        time.sleep(2)
        machine.keys("ret", pause=0.5)
        countdown = wait_for(machine.serial, ["Press any key to perform MOK management"], 30)
        time.sleep(1)
        machine.shot("countdown")
        expect(countdown is not None, "timeout: MokManager shows its countdown after OK", failures)
        time.sleep(14)
        machine.shot("after-countdown")
        text = serial_text(machine.serial)
        expect(text.count("Verification failed") >= 2 or text.count("Security Violation") >= 2,
               "timeout: after the countdown shim retries grubx64.efi (second refusal)", failures)
    finally:
        machine.stop()


def scenario_repeat(args, failures: list[str]) -> None:
    """A burst of Enter keys (a held button / typematic repeat from a
    handheld's keyboard emulation): the first dismisses the dialog, the next
    ones skip the countdown, pick "Continue boot" and dismiss the second
    refusal, so shim exits back to the firmware without MokManager being
    visible. Informational: shows why a single held A press can look like
    "no MokManager at all"."""
    esp = esp_tree("repeat", USB / "EFI" / "BOOT" / "grubx64.efi")
    machine = Machine("repeat", esp, fresh_vars("repeat"), args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["Verification failed", "Security Violation"], 180)
        expect(hit is not None, "repeat: shim refuses the not-yet-enrolled USOS", failures)
        time.sleep(2)
        for _ in range(4):
            machine.keys("ret", pause=0.12)
        time.sleep(8)
        machine.shot("after-burst")
        text = serial_text(machine.serial)
        refusals = max(text.count("Verification failed"), text.count("Security Violation"))
        print(f"[INFO] repeat: refusals={refusals} countdown_seen={'Press any key to perform MOK management' in text} "
              f"start_image_returned={'start_image() returned' in text}")
    finally:
        machine.stop()


def mok_request_vars(name: str, password: str) -> Path:
    """Fresh Microsoft-keys NVRAM plus MokNew/MokAuth exactly as the Windows
    installer's enrollment helper writes them (bytes from the Go code)."""
    out = WORK / f"mok-request-{name}"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    efisign("mok-request", "-cert", str(USB / "EFI" / "USOS" / CERT_NAME), "-password", password, "-out", str(out))
    variables = []
    for var in ("MokNew", "MokAuth"):
        data = (out / f"{var}.bin").read_bytes()
        variables.append({"name": var, "guid": "605dab50-e046-4300-abb6-3dd810dd8b23", "attr": 7, "data": data.hex()})
    import json
    spec = out / "vars.json"
    spec.write_text(json.dumps({"version": 2, "variables": variables}))
    vars_file = WORK / f"vars-{name}.fd"
    env = dict(**__import__("os").environ)
    env["PYTHONPATH"] = str(CACHE / "pylib")
    subprocess.run([sys.executable, "-m", "virt.firmware.vars", "-i", str(CACHE / "OVMF_VARS.secboot.fd"),
                    "--set-json", str(spec), "-o", str(vars_file)], check=True, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return vars_file


# MokManager with a pending MokNew (no "Verification failed" first):
#   10 s countdown                                  -> Space
#   Continue boot / Enroll MOK / Enroll key from disk / Enroll hash  -> Down, Enter
#   [Enroll MOK] View key 0 / Continue              -> Down, Enter
#   Enroll the key(s)? No / Yes                     -> Down, Enter
#   Password:                                       -> u s o s Enter
#   Perform MOK management: Reboot                  -> Enter
HELPER_KEYS = [["spc"], ["down", "ret"], ["down", "ret"], ["down", "ret"], ["u", "s", "o", "s", "ret"], ["ret"]]
HELPER_LABELS = ["mok-management", "enroll-mok", "enroll-question", "password", "enrolled", "reboot"]


def scenario_helper(args, failures: list[str]) -> None:
    """The Windows helper's MokNew/MokAuth: MokManager opens by itself on the
    next boot, the password enrolls the key and USOS then starts."""
    try:
        vars_file = mok_request_vars("helper", "usos")
    except (subprocess.CalledProcessError, FileNotFoundError, ModuleNotFoundError) as error:
        expect(False, f"helper: could not prepare MokNew/MokAuth NVRAM ({error})", failures)
        return
    esp = esp_tree("helper", USB / "EFI" / "BOOT" / "grubx64.efi")
    machine = Machine("helper", esp, vars_file, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["Press any key to perform MOK management", "Verification failed", "USOS MANUAL FLOW BOOT PASS"], 180)
        expect(hit == "Press any key to perform MOK management",
               "helper: pending MokNew opens MokManager directly (before any verification failure)", failures)
        time.sleep(1)
        machine.shot("countdown")
        for keys, label in zip(HELPER_KEYS, HELPER_LABELS):
            machine.keys(*keys, pause=0.6)
            time.sleep(1.5)
            if label != "reboot":
                machine.shot(label)
        started = wait_for(machine.serial, ["[SECURE_BOOT] state="], 240)
        time.sleep(4)
        machine.shot("usos-after-helper")
        text = serial_text(machine.serial)
        expect(started is not None and "USOS MANUAL FLOW BOOT PASS" in text,
               "helper: after the password the MOK-signed USOS starts", failures)
        expect("Password doesn't match" not in text, "helper: MokManager accepted the helper's MokAuth password hash", failures)
    finally:
        machine.stop()


def virt_fw_vars(*args: str) -> subprocess.CompletedProcess:
    env = dict(**__import__("os").environ)
    env["PYTHONPATH"] = str(CACHE / "pylib")
    return subprocess.run([sys.executable, "-m", "virt.firmware.vars", *args], check=True, env=env,
                          capture_output=True, text=True)


def seeded_vars(name: str, variables: list[dict], base: Path | None = None, set_false: list[str] | None = None) -> Path:
    """Microsoft-keys NVRAM plus the given shim variables (virt-firmware)."""
    import json
    out = WORK / f"seed-{name}"
    out.mkdir(parents=True, exist_ok=True)
    spec = out / "vars.json"
    spec.write_text(json.dumps({"version": 2, "variables": variables}))
    vars_file = WORK / f"vars-{name}.fd"
    args = ["-i", str(base or (CACHE / "OVMF_VARS.secboot.fd"))]
    if variables:
        args += ["--set-json", str(spec)]
    for item in set_false or []:
        args += ["--set-false", item]
    virt_fw_vars(*args, "-o", str(vars_file))
    return vars_file


def dump_vars(vars_file: Path) -> dict:
    import json
    out = vars_file.with_suffix(".json")
    virt_fw_vars("-i", str(vars_file), "--output-json", str(out))
    data = json.loads(out.read_text())
    return {v["name"]: v for v in data.get("variables", [])}


def x509_list(der: bytes) -> bytes:
    """EFI_SIGNATURE_LIST with one X.509 certificate owned by shim."""
    import uuid
    size = 28 + 16 + len(der)
    return (uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072").bytes_le + size.to_bytes(4, "little")
            + (0).to_bytes(4, "little") + (16 + len(der)).to_bytes(4, "little")
            + uuid.UUID(SHIM_GUID).bytes_le + der)


def scenario_noauth(args, failures: list[str]) -> None:
    """A MokNew request without MokAuth: shim 16.1 MokManager enrolls with
    authenticate=TRUE, store_keys() needs MokAuth and fails."""
    der = (USB / "EFI" / "USOS" / CERT_NAME).read_bytes()
    try:
        vars_file = seeded_vars("noauth", [{"name": "MokNew", "guid": SHIM_GUID, "attr": 7, "data": x509_list(der).hex()}])
    except (subprocess.CalledProcessError, FileNotFoundError, ModuleNotFoundError) as error:
        expect(False, f"noauth: could not prepare NVRAM ({error})", failures)
        return
    esp = esp_tree("noauth", USB / "EFI" / "BOOT" / "grubx64.efi")
    machine = Machine("noauth", esp, vars_file, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["Press any key to perform MOK management", "Verification failed", "USOS MANUAL FLOW BOOT PASS"], 180)
        expect(hit == "Press any key to perform MOK management", "noauth: a pending MokNew opens MokManager", failures)
        time.sleep(1)
        # Space, Enroll MOK (2nd item), Continue, Yes.
        for keys, label in zip([["spc"], ["down", "ret"], ["down", "ret"], ["down", "ret"]], ["menu", "enroll-mok", "enroll-question", "after-yes"]):
            machine.keys(*keys, pause=0.6)
            time.sleep(1.5)
            machine.shot(label)
        failed = wait_for(machine.serial, ["Failed to get MokAuth", "Failed to enroll keys"], 30)
        time.sleep(2)
        machine.shot("failed")
        expect(failed is not None, "noauth: MokManager refuses the request without MokAuth (\"Failed to get MokAuth\")", failures)
        machine.keys("ret", pause=1.0)
        time.sleep(2)
        machine.keys("ret", pause=1.0)
        time.sleep(10)
        expect("USOS MANUAL FLOW BOOT PASS" not in serial_text(machine.serial), "noauth: nothing was enrolled, USOS is not started", failures)
    finally:
        machine.stop()


# MokManager with MokTimeout = -1 after "Verification failed":
#   [OK]                                              -> Enter (once)
#   no countdown: Continue boot / Enroll key from disk / Enroll hash  -> Down, Enter
#   volume list: one vvfat volume                     -> Enter
#   /: EFI/ USOS-KEY.cer                              -> Down, Enter
#   [Enroll MOK] View key 0 / Continue                -> Down, Enter
#   Enroll the key(s)? No / Yes                       -> Down, Enter
#   Perform MOK management: Reboot                    -> Enter
WAIT_KEYS = [["down", "ret"], ["ret"], ["down", "ret"], ["down", "ret"], ["down", "ret"], ["ret"]]
WAIT_LABELS = ["select-volume", "root", "enroll-mok", "enroll-question", "enrolled", "reboot"]


def scenario_wait(args, failures: list[str]) -> None:
    try:
        vars_file = seeded_vars("wait", [{"name": "MokTimeout", "guid": SHIM_GUID, "attr": 7, "data": "ffffffff"}])
    except (subprocess.CalledProcessError, FileNotFoundError, ModuleNotFoundError) as error:
        expect(False, f"wait: could not prepare NVRAM ({error})", failures)
        return
    esp = esp_tree("wait", USB / "EFI" / "BOOT" / "grubx64.efi")
    expect((esp / ROOT_CERT_NAME).exists(), "wait: USOS-KEY.cer is at the ESP root", failures)
    machine = Machine("wait", esp, vars_file, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["Verification failed", "Security Violation", "USOS MANUAL FLOW BOOT PASS"], 180)
        expect(hit in ("Verification failed", "Security Violation"), "wait: shim refuses the not-yet-enrolled USOS", failures)
        time.sleep(2)
        machine.keys("ret", pause=0.5)
        # Longer than the default 10 s countdown: the menu must still wait.
        time.sleep(15)
        machine.shot("menu-waits")
        text = serial_text(machine.serial)
        expect("Press any key to perform MOK management" not in text, "wait: MokTimeout=-1 skips the countdown", failures)
        expect(max(text.count("Verification failed"), text.count("Security Violation")) == 1,
               "wait: after 15 s MokManager still waits on its menu (no second refusal)", failures)
        for keys, label in zip(WAIT_KEYS, WAIT_LABELS):
            machine.keys(*keys, pause=1.0)
            time.sleep(1.5)
            if label != "reboot":
                machine.shot(label)
        started = wait_for(machine.serial, ["[SECURE_BOOT] state="], 240)
        time.sleep(4)
        machine.shot("usos-after-enroll")
        text = serial_text(machine.serial)
        expect(started is not None and "USOS MANUAL FLOW BOOT PASS" in text,
               "wait: Enroll key from disk -> USOS-KEY.cer at the ESP root enrolls the key and USOS starts", failures)
    finally:
        machine.stop()


def other_certificate() -> bytes:
    directory = WORK / "other-key"
    cert = directory / "usos-secure-boot.cer"
    if not cert.exists():
        efisign("keygen", "-key-dir", str(directory), "-cn", "Some Other Distribution MOK")
    return cert.read_bytes()


def scenario_direct(args, failures: list[str]) -> None:
    """Secure Boot off (PK present): the menu's "Add the key" writes MokList
    itself; then Secure Boot on: no MokManager, USOS starts."""
    der = (USB / "EFI" / "USOS" / CERT_NAME).read_bytes()
    other = other_certificate()
    try:
        vars_off = seeded_vars("direct-off", [{"name": "MokList", "guid": SHIM_GUID, "attr": 3, "data": x509_list(other).hex()}],
                               set_false=["SecureBootEnable"])
    except (subprocess.CalledProcessError, FileNotFoundError, ModuleNotFoundError) as error:
        expect(False, f"direct: could not prepare NVRAM ({error})", failures)
        return
    probe_src = ROOT / "zig-out" / "test-assets" / "secure-boot-probe-x86_64.efi"
    probe = WORK / "grubx64-probe.efi"
    efisign("sign", "-in", str(probe_src), "-out", str(probe), "-sbat", str(SBAT))
    esp = esp_tree("direct-off", probe)
    machine = Machine("direct-off", esp, vars_off, args.keep_screens)
    try:
        wait_for(machine.serial, ["[SB_PROBE] mok-save end", "[SB_PROBE] mok-save FAIL", "[SB_PROBE] ESP OPEN FAIL"], 240)
        time.sleep(2)
        text = serial_text(machine.serial)
        expect("[SB_PROBE] begin state=off" in text, "direct: Secure Boot is off with the platform key installed", failures)
        expect("[SB_PROBE] mok-save before key=missing lists=1 cert=yes can_save=yes" in text,
               "direct: the key is missing, another key is in MokList, saving is offered", failures)
        expect("[SB_PROBE] mok-save PASS key=saved lists=2" in text, "direct: mok_key.save() appends the USOS key (2 lists)", failures)
        expect("[SB_PROBE] mok-save second refused error=NotAllowed" in text and "[SB_PROBE] mok-save end lists=2" in text,
               "direct: saving again is refused and adds nothing", failures)
    finally:
        machine.stop()
    variables = dump_vars(vars_off)
    mok = variables.get("MokList")
    data = bytes.fromhex(mok["data"]) if mok else b""
    attr = mok.get("attr", 0) if mok else 0
    expect(mok is not None and der in data and other in data, "direct: MokList in NVRAM holds the USOS key and keeps the other key", failures)
    expect(attr & 0x7 == 0x3, f"direct: MokList attributes are NV|BS without RT (0x{attr:x})", failures)
    # Same NVRAM, Secure Boot on, the release USOS as the second stage.
    vars_on = WORK / "vars-direct-on.fd"
    virt_fw_vars("-i", str(vars_off), "--set-true", "SecureBootEnable", "-o", str(vars_on))
    esp_on = esp_tree("direct-on", USB / "EFI" / "BOOT" / "grubx64.efi")
    machine = Machine("direct-on", esp_on, vars_on, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["[SECURE_BOOT] state=", "Verification failed", "Security Violation"], 240)
        time.sleep(4)
        machine.shot("usos-secure-boot-on")
        text = serial_text(machine.serial)
        expect(hit == "[SECURE_BOOT] state=" and "Verification failed" not in text,
               "direct: with Secure Boot on shim trusts the saved key, no MokManager", failures)
        expect("[SECURE_BOOT] state=on shim_lock=yes shim_loader=yes" in text and "USOS MANUAL FLOW BOOT PASS" in text,
               "direct: USOS runs under Secure Boot", failures)
    finally:
        machine.stop()


def scenario_unsigned_after_mok(args, vars_file: Path, failures: list[str]) -> None:
    copy = WORK / "vars-unsigned-mok.fd"
    shutil.copyfile(vars_file, copy)
    esp = esp_tree("unsigned-mok", unsigned_usos())
    machine = Machine("unsigned-mok", esp, copy, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["USOS MANUAL FLOW BOOT PASS", "Verification failed", "Security Violation"], 180)
        machine.shot("refused")
        expect(hit in ("Verification failed", "Security Violation"), "unsigned grubx64.efi is still refused with the USOS key enrolled", failures)
    finally:
        machine.stop()


def scenario_probe(args, vars_file: Path, failures: list[str]) -> None:
    copy = WORK / "vars-probe.fd"
    shutil.copyfile(vars_file, copy)
    probe_src = ROOT / "zig-out" / "test-assets" / "secure-boot-probe-x86_64.efi"
    child_src = ROOT / "zig-out" / "test-assets" / "direct-efi-validation.efi"
    probe = WORK / "grubx64-probe.efi"
    signed_child = WORK / "signed-child.efi"
    efisign("sign", "-in", str(probe_src), "-out", str(probe), "-sbat", str(SBAT))
    efisign("sign", "-in", str(child_src), "-out", str(signed_child))
    esp = esp_tree("probe", probe, {
        "EFI/USOS/probe/signed-child.efi": signed_child,
        "EFI/USOS/probe/unsigned-child.efi": child_src,
        "EFI/USOS/micro-linux/vmlinuz-virt": ROOT / "zig-out" / "micro-linux" / "vmlinuz-virt",
        "EFI/USOS/micro-linux/initramfs-usos": ROOT / "zig-out" / "micro-linux" / "initramfs-usos",
        "EFI/USOS/systemd-bootx64.efi": ROOT / "zig-out" / "micro-linux" / "systemd-bootx64.efi",
        "EFI/USOS/ntfs_x64.efi": ROOT / "zig-out" / "test-assets" / "ntfs_x64.efi",
        "EFI/USOS/windows-native/wimboot": ROOT / "zig-out" / "windows-native" / "wimboot",
    })
    (esp / "loader" / "entries").mkdir(parents=True, exist_ok=True)
    (esp / "loader" / "loader.conf").write_text("default usos-micro-linux.conf\r\ntimeout 0\r\neditor no\r\n")
    (esp / "loader" / "entries" / "usos-micro-linux.conf").write_text(
        "title USOS micro-Linux preparation\r\nlinux /EFI/USOS/micro-linux/vmlinuz-virt\r\n"
        "initrd /EFI/USOS/micro-linux/initramfs-usos\r\n"
        "options console=ttyS0,115200 loglevel=6 rdinit=/usos-init usos.legacy_action=hardware\r\n")
    machine = Machine("probe", esp, copy, args.keep_screens)
    try:
        wait_for(machine.serial, ["[HARDWARE] READ-ONLY SESSION READY", "Kernel panic", "[SB_PROBE] end"], 600)
        time.sleep(8)
        machine.shot("probe")
        text = serial_text(machine.serial)
        expect("[SB_PROBE] begin state=on shim_lock=yes shim_loader=yes" in text, "probe runs under Secure Boot with shim 16", failures)
        expect("DIRECT EFI VALIDATION PASS" in text, "MOK-signed child EFI starts through the verified loader", failures)
        # shim prints "Verification failed: ..." between the probe's two writes.
        unsigned = text[text.find("[SB_PROBE] unsigned-child"):] if "[SB_PROBE] unsigned-child" in text else ""
        expect("LOAD REJECTED error=SecureBootRejected" in unsigned[:400] and "unsigned-child LOAD PASS" not in text,
               "unsigned child EFI is rejected with SecureBootRejected", failures)
        expect("[SB_PROBE] START PASS" in text, "a started child that returns hands control back safely (shim 16 StartImage)", failures)
        expect("[SB_PROBE] ntfs-driver START PASS" in text, "MOK-signed NTFS driver starts (verified + USOS PE loader)", failures)
        expect("[SB_PROBE] wimboot LOAD PASS" in text, "Microsoft-signed wimboot loads (db via shim's loader)", failures)
        expect("[SB_PROBE] kernel LOAD PASS" in text, "MOK-signed micro-Linux kernel loads", failures)
        expect("[SB_PROBE] systemd-boot LOAD PASS" in text, "MOK-signed systemd-boot loads", failures)
        expect("Linux version" in text, "systemd-boot started the MOK-signed kernel under Secure Boot", failures)
        expect("[HARDWARE] READ-ONLY SESSION READY" in text, "micro-Linux userland (initramfs, modules, framebuffer UI) runs under Secure Boot", failures)
    finally:
        machine.stop()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep-screens", action="store_true")
    parser.add_argument("--only", choices=["unsigned", "enroll", "probe", "timeout", "repeat", "helper", "noauth", "wait", "direct"], default=None)
    args = parser.parse_args()
    subprocess.run([sys.executable, str(Path(__file__).with_name("fetch_ovmf_secboot.py"))], check=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if not (USB / "EFI" / "USOS" / CERT_NAME).exists():
        raise SystemExit("zig-out/usb has no USOS certificate: build.bat ran without the signing key")
    failures: list[str] = []
    if args.only in (None, "unsigned"):
        scenario_unsigned(args, failures)
    if args.only in (None, "timeout"):
        scenario_timeout(args, failures)
    if args.only in (None, "repeat"):
        scenario_repeat(args, failures)
    if args.only in (None, "helper"):
        scenario_helper(args, failures)
    if args.only in (None, "noauth"):
        scenario_noauth(args, failures)
    if args.only in (None, "wait"):
        scenario_wait(args, failures)
    if args.only in (None, "direct"):
        scenario_direct(args, failures)
    if args.only in (None, "enroll", "probe"):
        enrolled = scenario_enroll(args, failures)
        if args.only is None:
            scenario_unsigned_after_mok(args, enrolled, failures)
        scenario_probe(args, enrolled, failures)
    print(f"[RESULT] {len(failures)} failure(s)" + ("" if not failures else ": " + "; ".join(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
