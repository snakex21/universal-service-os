"""Fast Startup off in every USOS 8 / 8.1 / 10 / 11 install (2026-10-22).

    python tools/tests/test_windows_fast_startup.py [path-to-usos-x86-csmwrap.exe]

1. tools/windows_fast_startup.h through usos-x86-csmwrap.exe faststartup-test:
   the CurrentControlSet choice (Select\\Current -> ControlSet00N), the
   HiberbootEnabled=0 write, the readback and the "already 0" case on a scratch
   key under HKCU (no elevation; the SYSTEM hive load is the same pattern as
   hideesp / display).
2. Wiring: the x86 CSMWrap cmd calls faststartup after Setup and never fails
   the installation; the answer generator writes the same value for the native
   UEFI 8 / 8.1 / 10 / 11 path, with the DATA fast-startup-on.txt opt-out honoured
   before the render.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "zig-out" / "windows-modern" / "usos-x86-csmwrap.exe"
KEY = r"Software\USOS-fast-startup-test"
POWER = r"Control\Session Manager\Power"


def reg(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    r = subprocess.run(["reg", *args], capture_output=True, text=True, errors="replace")
    if check:
        assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r


def value(key: str) -> int | None:
    r = reg("query", key, "/v", "HiberbootEnabled", check=False)
    if r.returncode:
        return None
    for line in r.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0] == "HiberbootEnabled":
            return int(parts[2], 16) if parts[2].lower().startswith("0x") else int(parts[2])
    return None


def setup() -> None:
    reg("delete", "HKCU\\" + KEY, "/f", check=False)
    reg("add", "HKCU\\" + KEY + r"\Select", "/v", "Current", "/t", "REG_DWORD", "/d", "1", "/f")
    reg("add", "HKCU\\" + KEY + r"\ControlSet001\Control\Session Manager\Power", "/f")
    reg("add", "HKCU\\" + KEY + r"\ControlSet002\Control\Session Manager\Power", "/f")


def helper() -> None:
    if not EXE.is_file():
        print(f"[helper] SKIP: the x86 CSMWrap helper is not built: {EXE}")
        return
    setup()
    try:
        p1 = "HKCU\\" + KEY + r"\ControlSet001\Control\Session Manager\Power"
        p2 = "HKCU\\" + KEY + r"\ControlSet002\Control\Session Manager\Power"
        assert subprocess.run([str(EXE), "faststartup-test", KEY]).returncode == 0
        assert value(p1) == 0 and value(p2) is None
        # Idempotent: the second run reports "already 0".
        assert subprocess.run([str(EXE), "faststartup-test", KEY]).returncode == 1
        # The next boot's control set is the one edited (Select\Current=2).
        reg("add", "HKCU\\" + KEY + r"\Select", "/v", "Current", "/t", "REG_DWORD", "/d", "2", "/f")
        assert subprocess.run([str(EXE), "faststartup-test", KEY]).returncode == 0
        assert value(p2) == 0
        # A value that is not 0 is replaced.
        reg("add", p2, "/v", "HiberbootEnabled", "/t", "REG_DWORD", "/d", "1", "/f")
        assert subprocess.run([str(EXE), "faststartup-test", KEY]).returncode == 0
        assert value(p2) == 0
        # No Select key (a fresh hive): ControlSet001.
        reg("delete", "HKCU\\" + KEY + r"\Select", "/f", check=False)
        reg("delete", p1, "/v", "HiberbootEnabled", "/f", check=False)
        assert subprocess.run([str(EXE), "faststartup-test", KEY]).returncode == 0
        assert value(p1) == 0
        # A missing SYSTEM root (no ControlSet at all) is an error, never a crash.
        assert subprocess.run([str(EXE), "faststartup-test", KEY + r"\Nope"]).returncode == 99
        print("[helper] ControlSet00N from Select\\Current, 0 written, idempotent, non-zero replaced")
    finally:
        reg("delete", "HKCU\\" + KEY, "/f", check=False)


def wiring() -> None:
    cmd = (ROOT / "tools/windows_x86_csmwrap.cmd").read_text(encoding="utf-8")
    call = '"%~dp0usos-x86-csmwrap.exe" faststartup\n'
    assert call in cmd
    # After Setup succeeded and before the system boots from the disk.
    assert cmd.index('if not "%USOS_SETUP_RESULT%"=="0"') < cmd.index(call) < cmd.index("call :nt60_gate\n")
    assert "if errorlevel 1 echo [USOS] fast-startup: not changed" in cmd  # never fatal
    assert "fast-startup-on.txt" in cmd
    c = (ROOT / "tools/windows_x86_csmwrap.c").read_text(encoding="utf-8")
    assert '#include "windows_fast_startup.h"' in c and 'L"faststartup") == 0) ExitProcess(fast_startup())' in c
    header = (ROOT / "tools/windows_fast_startup.h").read_text(encoding="utf-8")
    assert r"C:\Session Manager\Power" not in header and "Session Manager\\\\Power" in header
    assert "HiberbootEnabled" in header and "USOS_FASTSTARTUP" in header
    answer = (ROOT / "src/flow/answer/autounattend.zig").read_text(encoding="utf-8")
    assert "/v HiberbootEnabled /t REG_DWORD /d 0 /f" in answer
    assert ".windows_8, .windows_8_1, .windows_10, .windows_11 => true" in answer
    uefi = (ROOT / "src/platform/uefi/answer_profiles.zig").read_text(encoding="utf-8")
    assert "fast-startup-on.txt" in uefi and "fastStartupOn(system_id)" in uefi
    print("[wiring] x86 cmd after Setup, never fatal; answer + DATA opt-out on the native path")


def main() -> int:
    wiring()
    helper()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
