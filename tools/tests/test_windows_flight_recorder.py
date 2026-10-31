"""Opt-in flight recorder USOSFLT for the installed x86 NT6 system (2026-10-31).

    python tools/tests/test_windows_flight_recorder.py [usos-x86-csmwrap.exe] [usos-flight.exe]

1. tools/windows_flight_register.h through usos-x86-csmwrap.exe flight-test on
   a scratch key under HKCU (no elevation): Services\\USOSFLT in the
   Select\\Current control set with Type 0x10, Start 2, ErrorControl 0,
   ImagePath REG_EXPAND_SZ, LocalSystem, group "Event Log"; idempotent; the
   Vista / 7 variant edits nothing else; faststartup-test (flag absent) never
   creates the service (default OFF).
2. usos-flight.exe /console <log> 4: lines written and flushed (BOOT, T
   ticks, END), the counter file increments per start. Read-only probing.
3. Wiring: opt-in flag flight-recorder.txt, the helper copies usos-flight.exe
   to System32\\USOSFLT.EXE, the build packs it, write-through + flush.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "zig-out" / "windows-modern" / "usos-x86-csmwrap.exe"
FLT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "zig-out" / "windows-modern" / "usos-flight.exe"
KEY = r"Software\USOS-flight-recorder-test"


def reg(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    r = subprocess.run(["reg", *args], capture_output=True, text=True, errors="replace")
    if check:
        assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r


def values(key: str) -> dict[str, tuple[str, str]]:
    r = reg("query", key, check=False)
    out: dict[str, tuple[str, str]] = {}
    if r.returncode:
        return out
    for line in r.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) >= 2 and parts[1].startswith("REG_"):
            out[parts[0]] = (parts[1], parts[2] if len(parts) == 3 else "")
    return out


def helper() -> None:
    if not EXE.is_file():
        print(f"[helper] SKIP: not built: {EXE}")
        return
    reg("delete", "HKCU\\" + KEY, "/f", check=False)
    reg("add", "HKCU\\" + KEY + r"\Select", "/v", "Current", "/t", "REG_DWORD", "/d", "2", "/f")
    reg("add", "HKCU\\" + KEY + r"\ControlSet002\Services", "/f")
    svc = "HKCU\\" + KEY + r"\ControlSet002\Services\USOSFLT"
    try:
        # Default OFF: the plain faststartup edit never registers the service.
        assert subprocess.run([str(EXE), "faststartup-test", KEY]).returncode == 0
        assert not values(svc), values(svc)
        # Opt-in: written (0) in the Select\Current set, hive edit result 1 = already done.
        rc = subprocess.run([str(EXE), "flight-test", KEY]).returncode
        assert rc == 0 * 10 + 1, rc
        v = values(svc)
        assert v["Type"] == ("REG_DWORD", "0x10") and v["Start"] == ("REG_DWORD", "0x2") and v["ErrorControl"] == ("REG_DWORD", "0x0"), v
        assert v["ImagePath"] == ("REG_EXPAND_SZ", r"%SystemRoot%\System32\USOSFLT.EXE"), v
        assert v["ObjectName"] == ("REG_SZ", "LocalSystem") and v["Group"] == ("REG_SZ", "Event Log"), v
        assert not values("HKCU\\" + KEY + r"\ControlSet001\Services\USOSFLT")
        # Idempotent: present (1).
        assert subprocess.run([str(EXE), "flight-test", KEY]).returncode // 10 == 1
        # A changed Start value is repaired.
        reg("add", svc, "/v", "Start", "/t", "REG_DWORD", "/d", "4", "/f")
        assert subprocess.run([str(EXE), "flight-test", KEY]).returncode // 10 == 0
        assert values(svc)["Start"] == ("REG_DWORD", "0x2")
        # Vista / 7 variant: service only, no CrashControl / Power edit (2 = skipped).
        reg("delete", "HKCU\\" + KEY + r"\ControlSet002\Control", "/f", check=False)
        reg("delete", svc, "/f")
        assert subprocess.run([str(EXE), "flight-test", KEY, "vista"]).returncode == 0 * 10 + 2
        assert values(svc)["Start"] == ("REG_DWORD", "0x2")
        assert reg("query", "HKCU\\" + KEY + r"\ControlSet002\Control", check=False).returncode != 0
        print("[helper] default off; opt-in USOSFLT service in ControlSet00N, idempotent, repaired; Vista/7 service-only")
    finally:
        reg("delete", "HKCU\\" + KEY, "/f", check=False)


def console() -> None:
    if not FLT.is_file():
        print(f"[console] SKIP: not built: {FLT}")
        return
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "FLIGHT.LOG"
        for run in (1, 2):
            r = subprocess.run([str(FLT), "/console", str(log), "4"], capture_output=True, timeout=60)
            assert r.returncode == 0, r.returncode
            assert (Path(str(log) + ".cnt")).read_text().strip() == str(run)
        lines = log.read_text(encoding="ascii").splitlines()
        assert sum(" BOOT usosflt" in x for x in lines) == 2
        assert sum(" END " in x for x in lines) == 2
        ticks = [x for x in lines if " T " in x]
        assert len(ticks) >= 6, len(ticks)
        assert all(x.split()[0] in ("1", "2") for x in lines)
        assert " br=" in ticks[0] and " gpu=" in ticks[0] and " setup=" in ticks[0]
    print(f"[console] two 4 s runs: {len(ticks)} tick lines, boot counter 1 -> 2")


def wiring() -> None:
    c = (ROOT / "tools/windows_x86_csmwrap.c").read_text(encoding="utf-8")
    assert 'L"flight-recorder.txt"' in c and 'L"usos-flight.exe"' in c and 'Windows\\\\System32\\\\USOSFLT.EXE' in c
    assert "static void flight_recorder(" in c and "usos_fs_flight = TRUE;" in c
    fs = (ROOT / "tools/windows_fast_startup.h").read_text(encoding="utf-8")
    assert '#include "windows_flight_register.h"' in fs and "if (usos_fs_flight) usos_fs_flight_result" in fs
    h = (ROOT / "tools/windows_flight_register.h").read_text(encoding="utf-8")
    assert "static BOOL usos_fs_flight;" in h  # FALSE by default: opt-in
    src = (ROOT / "tools/windows_flight_recorder.c").read_text(encoding="utf-8")
    assert "FILE_FLAG_WRITE_THROUGH" in src and "FlushFileBuffers(logf)" in src
    assert "CM_Register_Notification" in src and "EnumDeviceDrivers" in src and "CreateToolhelp32Snapshot" in src
    b = (ROOT / "tools/build_windows_native_support.py").read_text(encoding="utf-8")
    assert "tools/windows_flight_recorder.c" in b and "writer.add_file('usos-flight.exe'" in b
    print("[wiring] opt-in flag, copy + registration in the faststartup hive load, packed in modern-support.cpio")


def main() -> int:
    wiring()
    helper()
    console()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
