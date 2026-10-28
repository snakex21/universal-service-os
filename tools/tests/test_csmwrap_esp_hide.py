"""Host test: the "no drive letter" entry for the CSMWrap ESP
(tools/windows_csmwrap_hide.h through usos-x86-csmwrap.exe hideesp-test).

    python tools/tests/test_csmwrap_esp_hide.py [path-to-usos-x86-csmwrap.exe]

Runs the MountedDevices edit (usos_hide_esp_in_key) on a scratch key under
HKCU (no elevation; the hive load/unload around it in the WinPE is the same
RegLoadKeyW pattern as the lowmem step). Also checks the wiring: the x86
CSMWrap cmd calls hideesp on every version, the Vista x64 installer calls the
header on the CSMWrap path, the target ini carries esp_start and the ESP
stays MBR type 0xEF.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "zig-out" / "windows-modern" / "usos-x86-csmwrap.exe"
KEY = r"Software\USOS-hide-esp-test"
SRC_KEY = "HKCU\\" + KEY
SIG = 0x5A5A0303
ESP_LBA = 3906885632  # ESP start on a 2 TB disk: byte offset above 4 GiB, LBA above 2^31
OTHER = "4433221100001000" + "00000000"  # another volume (signature 0x11223344, 1 MiB)


def ident(sig: int, lba: int) -> str:
    return (sig.to_bytes(4, "little") + (lba * 512).to_bytes(8, "little")).hex().upper()


def reg(*args: str, check: bool = True) -> str:
    r = subprocess.run(["reg", *args], capture_output=True, text=True, errors="replace")
    if check:
        assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r.stdout


def values() -> dict[str, str]:
    found = {}
    for line in reg("query", SRC_KEY + r"\MountedDevices").splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1] == "REG_BINARY":
            found[parts[0]] = parts[2].upper()
    return found


def run() -> int:
    return subprocess.run([str(EXE), "hideesp-test", KEY + r"\MountedDevices", f"{SIG:08x}", str(ESP_LBA)]).returncode


def wiring() -> None:
    cmd = (ROOT / "tools/windows_x86_csmwrap.cmd").read_text(encoding="utf-8")
    assert '"%~dp0usos-x86-csmwrap.exe" hideesp\n' in cmd
    assert cmd.index('"%~dp0usos-x86-csmwrap.exe" hideesp\n') < cmd.index('"%~dp0usos-x86-csmwrap.exe" after\n')
    vista = (ROOT / "tools/windows_vista_install.c").read_text(encoding="utf-8")
    assert '#include "windows_csmwrap_hide.h"' in vista and "usos_hide_esp_letter(hive,csm_signature,csm_esp_start" in vista
    target = (ROOT / "tools/vista_csmwrap_target.sh").read_text(encoding="utf-8")
    assert "esp_start=%s" in target, "usos-*-target.ini must carry esp_start"
    esp = (ROOT / "tools/xp_csmwrap_esp.sh").read_text(encoding="utf-8")
    assert r"printf '\000\376\377\377\357" in esp, "the CSMWrap ESP stays MBR type 0xEF"
    print("[wiring] x86 cmd, Vista x64 installer, target ini, ESP type 0xEF")


def main() -> int:
    wiring()
    assert EXE.is_file(), EXE
    esp = ident(SIG, ESP_LBA)
    reg("delete", SRC_KEY, "/f", check=False)
    try:
        reg("add", SRC_KEY + r"\MountedDevices", "/v", r"\DosDevices\C:", "/t", "REG_BINARY", "/d", OTHER, "/f")
        reg("add", SRC_KEY + r"\MountedDevices", "/v", r"\DosDevices\E:", "/t", "REG_BINARY", "/d", esp, "/f")
        reg("add", SRC_KEY + r"\MountedDevices", "/v", r"\??\Volume{00000000-1111-2222-3333-444444444444}", "/t", "REG_BINARY", "/d", OTHER, "/f")
        code = run()
        assert code == 1, code  # written (0) * 10 + one letter removed
        got = values()
        marker = "#{55534f53-4353-4d57-5a5a-0303" + f"{ESP_LBA & 0xffffffff:08x}" + "}"
        assert got.get(marker) == esp, got
        assert r"\DosDevices\E:" not in got, got
        assert got.get(r"\DosDevices\C:") == OTHER, got
        assert len(got) == 3, got
        print("[hide] marker written, ESP letter removed, other volumes untouched")
        code = run()
        assert code == 10, code  # present (1) * 10, nothing removed
        assert values() == got
        print("[hide] second run: already present, key unchanged")
    finally:
        reg("delete", SRC_KEY, "/f", check=False)
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
