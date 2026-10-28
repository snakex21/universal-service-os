"""Host test: the POSReady 2009 display helper (docs/display-policy.md).

    python tools/tests/test_display_posready.py

POSReady 2009 has the NT 5.1 core (XP SP3), so it gets the XP / Server 2003
USOSRES contract under \\USOS\\POSR instead of \\USOS\\XP:

1. posready_csmwrap_target.sh stages USOSRES.EXE + DISPLAY.TXT on the PE
   partition (\\USOS\\POSR) with the same helper as the NT52 path
   (tools/display_profile.sh: auto request, native= from the UEFI EDID
   record), and reads them back from the FAT16 image.
2. posready_after_setup copies \\USOS\\POSR onto the Windows partition
   (C:\\USOS\\POSR) and reads DISPLAY.TXT back.
3. posready_logon.cmd (first logon) registers the helper under the same
   HKLM Run value as usos-users.cmd on XP: USOSDisplay.

Host only: no install, no disk, no Windows API.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/tests"))
from test_nt4_flow import function_text

SH = shutil.which("sh") or r"C:\Program Files\Git\usr\bin\sh.exe"
ENV = dict(os.environ, PATH=str(Path(SH).parent) + os.pathsep + os.environ.get("PATH", ""))
TARGET = ROOT / "tools/posready_csmwrap_target.sh"
LOGON = ROOT / "tools/posready_logon.cmd"
RUN_LINE = (b'if exist "%S%USOSRES.EXE" reg add '
            b'"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" /v USOSDisplay '
            b'/t REG_SZ /d "%SystemDrive%\\USOS\\POSR\\USOSRES.EXE" /f >> "%S%FIRST.LOG" 2>&1')


def shell(code: str) -> subprocess.CompletedProcess:
    return subprocess.run([SH, "-c", code], cwd=ROOT, env=ENV, capture_output=True)


def quote(p) -> str:
    return "'" + str(p).replace("\\", "/") + "'"


@unittest.skipUnless(SH, "no sh")
class Staging(unittest.TestCase):
    """usos_posr_display_stage from posready_csmwrap_target.sh."""

    def stage(self, native: bytes | None, helper: bool = True, keep: str = ""):
        tmp = Path(tempfile.mkdtemp(prefix="posr-display-"))
        self.addCleanup(shutil.rmtree, tmp)
        lib = tmp / "lib"
        lib.mkdir()
        shutil.copy(ROOT / "tools/display_profile.sh", lib / "display_profile.sh")
        if helper:
            (lib / "USOSRES.EXE").write_bytes(b"own helper fixture")
        record = tmp / "display-native.txt"
        if native is not None:
            record.write_bytes(native)
        setup = tmp / "vol/USOS/POSR"
        setup.mkdir(parents=True)
        funcs = function_text(TARGET, "usos_posr_display_stage")
        pre = ('fail() { echo "$*" >&2; exit 1; }; log() { echo "LOG $*" >&2; }; '
               "LIB=" + quote(lib) + " USOS_DISPLAY_NATIVE_FILE=" + quote(record) + "; "
               + ("USOS_DISPLAY_KEEP=" + keep + "; " if keep else ""))
        r = shell(pre + funcs + "\nusos_posr_display_stage " + quote(setup))
        self.assertEqual(r.returncode, 0, r.stderr)
        return setup, r, record

    def test_auto_request_and_staged_helper(self) -> None:
        setup, r, _ = self.stage(b"1920x1080\r\n")
        self.assertEqual((setup / "USOSRES.EXE").read_bytes(), b"own helper fixture")
        self.assertEqual((setup / "DISPLAY.TXT").read_bytes(),
                         b"autoxauto\r\nnative=1920x1080\r\n")
        self.assertIn(b"DISPLAY request=autoxauto native=1920x1080 apply=first-logon", r.stderr)

    def test_unknown_or_absent_native_record(self) -> None:
        for native in (None, b"100x100\r\n", b"2560x1440;x\r\n"):
            setup, r, _ = self.stage(native)
            self.assertEqual((setup / "DISPLAY.TXT").read_bytes(), b"autoxauto\r\n", native)
            self.assertIn(b"native=unknown", r.stderr, native)

    def test_missing_helper_changes_nothing(self) -> None:
        # A build without USOSRES.EXE: logged, preparation continues.
        setup, r, _ = self.stage(b"1920x1080\r\n", helper=False)
        self.assertFalse((setup / "USOSRES.EXE").exists())
        self.assertFalse((setup / "DISPLAY.TXT").exists())
        self.assertIn(b"USOSRES.EXE missing in this build; display unchanged", r.stderr)

    def test_display_keep_flag_stages_nothing(self) -> None:
        # DATA's display-keep.txt (USOS_DISPLAY_KEEP=1 from w9x_csmwrap_prepare.sh).
        setup, r, _ = self.stage(b"1920x1080\r\n", keep="1")
        self.assertFalse((setup / "USOSRES.EXE").exists())
        self.assertFalse((setup / "DISPLAY.TXT").exists())
        self.assertIn(b"DISPLAY keep (display-keep.txt): USOSRES not staged", r.stderr)
        setup, _, _ = self.stage(b"1920x1080\r\n", keep="0")
        self.assertTrue((setup / "DISPLAY.TXT").exists())

    def test_same_contract_as_the_nt52_path(self) -> None:
        # The same shared helper as usos_nt52_display_stage: identical bytes.
        setup, _, record = self.stage(b"1280x1024")
        tmp = Path(tempfile.mkdtemp(prefix="nt52-display-"))
        self.addCleanup(shutil.rmtree, tmp)
        exe = tmp / "USOSRES.EXE"
        exe.write_bytes(b"own helper fixture")
        nt52 = tmp / "XP"
        nt52.mkdir()
        r = shell('. ' + quote(ROOT / "tools/display_profile.sh") + "; USOS_DISPLAY_NATIVE_FILE="
                  + quote(record) + " usos_display_stage " + quote(nt52) + " " + quote(exe)
                  + " autoxauto")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((setup / "DISPLAY.TXT").read_bytes(), (nt52 / "DISPLAY.TXT").read_bytes())


class Wiring(unittest.TestCase):
    def test_target_stages_and_reads_back(self) -> None:
        text = TARGET.read_text(encoding="utf-8")
        self.assertIn('usos_posr_display_stage "$work/pe/USOS/POSR"', text)
        self.assertIn('usos_display_stage "$1" "$LIB/USOSRES.EXE" autoxauto', text)
        self.assertIn(". \"$LIB/display_profile.sh\"", text)
        self.assertIn("::/USOS/POSR/DISPLAY.TXT", text)
        # The read-back only when something was staged (keep, missing helper).
        self.assertIn('[ "$posr_display_staged" = 0 ] || mdir -i "$pe_loop" ::/USOS/POSR/DISPLAY.TXT', text)
        # \\USOS\\POSR is what posready_after_setup copies to C:.
        self.assertLess(text.index('mkdir -p "$work/pe/USOS/POSR/DRV"'),
                        text.index('usos_posr_display_stage "$work/pe/USOS/POSR"'))

    def test_after_setup_reads_display_back(self) -> None:
        text = (ROOT / "tools/posready_qemu_install.sh").read_text(encoding="utf-8")
        after = text[text.index("posready_after_setup() {"):text.index("posready_answer_xml() {")]
        self.assertIn('cp -r "$w/pe/USOS/POSR" "$w/win/USOS/POSR"', after)
        self.assertIn('DISPLAY.TXT readback mismatch', after)

    def test_first_logon_registers_the_same_run_value(self) -> None:
        logon = LOGON.read_bytes()
        self.assertIn(RUN_LINE, logon)
        # Before the shutdown of the first logon, after the ACPI check.
        self.assertLess(logon.index(RUN_LINE), logon.index(b"shutdown -s -f -t 0"))
        # Logged only with the helper staged: %ERRORLEVEL% is then reg add's.
        self.assertIn(b'if exist "%S%USOSRES.EXE" echo display registered %ERRORLEVEL% >> "%S%FIRST.LOG"', logon)
        # The XP contract: the same value name and hive (usos-users.cmd path).
        profile = (ROOT / "tools/display_profile.sh").read_text(encoding="utf-8")
        self.assertIn('/v USOSDisplay /t REG_SZ', profile)
        self.assertIn('Microsoft\\\\Windows\\\\CurrentVersion\\\\Run', profile)

    def test_helper_is_in_the_posready_build(self) -> None:
        build = (ROOT / "tools/build_micro_linux.py").read_text(encoding="utf-8")
        # USOSRES.EXE and the shared display helper are on the micro-Linux
        # image the POSReady target script runs from ($LIB = /usr/lib/usos).
        self.assertIn('"usr/lib/usos/USOSRES.EXE"', build)
        self.assertIn('"usr/lib/usos/display_profile.sh"', build)
        self.assertIn("posready_csmwrap_target.sh", build)
        self.assertIn("posready/LOGON.CMD", build)


if __name__ == "__main__":
    unittest.main(verbosity=2)
