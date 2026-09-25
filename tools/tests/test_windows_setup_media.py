#!/usr/bin/env python3
"""Windows Setup media on WORK and the user-driver folder (docs/drivers.md).

- tools/windows_setup_media.sh (sourced by extract.sh) recognises Setup media
  with install.wim, install.esd or a split install.swm, case-insensitively,
  and maps catalog system ids to DATA\\Drivers folders;
- extract.sh stages $WinPEDriver$ for every method that leaves Setup media on
  WORK (iso and chainload: Windows 8/8.1/10 on UEFI use chainload), with the
  folder taken from selected_system;
- the boot menu records selected_system (UEFI state writer, BIOS request);
- the UEFI WORK handoff and the BIOS native path accept .wim/.esd/.swm.

Runs the shell helpers with sh (Git for Windows' sh on the dev PC).

    python tools/tests/test_windows_setup_media.py
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tools" / "windows_setup_media.sh"
SH = shutil.which("sh")


def run(script: str) -> str:
    result = subprocess.run([SH, "-c", f". '{HELPER.as_posix()}'; {script}"], capture_output=True, text=True, check=True)
    return result.stdout


@unittest.skipIf(SH is None, "no POSIX sh")
class SetupMediaHelpers(unittest.TestCase):
    def make(self, *files: str) -> Path:
        root = Path(tempfile.mkdtemp(prefix="usos-work-"))
        self.addCleanup(shutil.rmtree, root, True)
        for name in files:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"x")
        return root

    def image(self, root: Path) -> str:
        return run(f"windows_install_image '{root.as_posix()}'").strip()

    def setup(self, root: Path) -> bool:
        return run(f"if windows_setup_exe '{root.as_posix()}'; then echo yes; else echo no; fi").strip() == "yes"

    def test_install_image_formats(self):
        for name in ("sources/install.wim", "sources/install.esd", "sources/install.swm", "SOURCES/Install.ESD"):
            root = self.make("sources/setup.exe" if name.startswith("sources") else "SOURCES/SETUP.EXE", name)
            self.assertTrue(self.image(root).endswith(name), name)
            self.assertTrue(self.setup(root), name)

    def test_not_setup_media(self):
        root = self.make("sources/boot.wim", "sources/install2.swm", "other/sources/install.wim", "EFI/BOOT/BOOTX64.EFI")
        self.assertEqual("", self.image(root))
        self.assertFalse(self.setup(root))
        root = self.make("sources/install.esd")
        self.assertTrue(self.image(root))
        self.assertFalse(self.setup(root), "an install image without setup.exe is not Setup media")

    def test_driver_folder_from_system_id(self):
        cases = {
            ("windows-7", ""): "Windows 7",
            ("windows-8", ""): "Windows 8",
            ("windows-8-1", ""): "Windows 8.1",
            ("windows-10", "Systems/Windows/Windows 11/Images/x.iso"): "Windows 10",
            ("windows-11", ""): "Windows 11",
            ("windows-vista", "Systems/Windows/Windows Vista/Images/v.iso"): "",
            ("ubuntu", "Systems/Windows/Windows 10/Images/x.iso"): "",
            ("", "Systems/Windows/Windows 8.1/Images/x.iso"): "Windows 8.1",
            ("", "Systems/Linux/Ubuntu/Images/x.iso"): "",
            # Windows Server: its own DATA\Drivers folder; 2008 like Vista is not wired.
            ("windows-server-2025", ""): "Windows Server 2025",
            ("windows-server-2022", ""): "Windows Server 2022",
            ("windows-server-2019", ""): "Windows Server 2019",
            ("windows-server-2016", ""): "Windows Server 2016",
            ("windows-server-2012-r2", ""): "Windows Server 2012 R2",
            ("windows-server-2012", "Systems/Windows/Windows Server 2012/Images/s.iso"): "Windows Server 2012",
            ("windows-server-2008-r2", ""): "Windows Server 2008 R2",
            ("windows-server-2008", "Systems/Windows/Windows Server 2008/Images/s.iso"): "",
        }
        for (system, iso), folder in cases.items():
            self.assertEqual(folder, run(f"user_drivers_os '{system}' '{iso}'"), (system, iso))


@unittest.skipIf(SH is None, "no POSIX sh")
class BiosRequestFolder(unittest.TestCase):
    """usos.legacy_folder_hex (Windows Server 2008 R2 / 2008 from the BIOS Core)."""

    def request(self, action: str, folder: str | None) -> tuple[int, str]:
        root = Path(tempfile.mkdtemp(prefix="usos-esp-"))
        self.addCleanup(shutil.rmtree, root, True)
        (root / "EFI/USOS").mkdir(parents=True)
        # The request writes under /mnt/esp: a copy points it at the temp root.
        text = (ROOT / "tools/legacy_windows_request.sh").read_text(encoding="utf-8")
        request = root / "legacy_windows_request.sh"
        request.write_text(text.replace("/mnt/esp", root.as_posix()), encoding="utf-8", newline="\n")
        folder_hex = folder.encode("ascii").hex() if folder is not None else ""
        script = (
            "stop() { printf 'STOP %s\\n' \"$1\"; exit 3; }; "
            f". '{request.as_posix()}'; "
            f"LEGACY_ACTION='{action}'; LEGACY_IMAGE_HEX='{'s.iso'.encode().hex()}'; LEGACY_UNATTENDED_HEX=''; LEGACY_FOLDER_HEX='{folder_hex}'; "
            "legacy_windows_request; "
            f"cat '{root.as_posix()}/EFI/USOS/install-state.ini'"
        )
        result = subprocess.run([SH, "-c", script], capture_output=True, text=True)
        return result.returncode, result.stdout

    def test_server_folders(self):
        code, out = self.request("windows7-iso", "Windows Server 2008 R2")
        self.assertEqual(0, code, out)
        self.assertIn("selected_system=windows-server-2008-r2", out)
        self.assertIn("selected_iso=Systems/Windows/Windows Server 2008 R2/Images/s.iso", out)
        code, out = self.request("windows-vista-iso", "Windows Server 2008")
        self.assertEqual(0, code, out)
        self.assertIn("selected_system=windows-server-2008", out)
        code, out = self.request("windows7-iso", None)
        self.assertEqual(0, code, out)
        self.assertIn("selected_iso=Systems/Windows/Windows 7/Images/s.iso", out)

    def test_other_folders_are_refused(self):
        for action, folder in (("windows7-iso", "Windows Server 2008"), ("windows-vista-iso", "Windows 10"), ("windows7-iso", "../Windows 7")):
            code, out = self.request(action, folder)
            self.assertEqual(3, code, (action, folder, out))
            self.assertIn("STOP", out)


class Wiring(unittest.TestCase):
    def test_extract_stages_for_every_setup_media_method(self):
        extract = (ROOT / "tools/extract.sh").read_text(encoding="utf-8")
        block = extract[extract.index("USER_DRIVERS_STAGED=no"):extract.index("user drivers staged=%s")]
        self.assertNotIn('SELECTED_METHOD" = iso', block)
        self.assertIn('[ "$WINDOWS_SETUP_MEDIA" = yes ]', block)
        self.assertIn('user_drivers_os "${SELECTED_SYSTEM:-}" "${SELECTED_ISO:-}"', block)
        self.assertLess(extract.index('INSTALL_WIM=$(windows_install_image "$WORK_ROOT")'), extract.index('if [ "$SELECTED_METHOD" = chainload ]'))
        self.assertIn('. "$SCRIPT_DIR/windows_setup_media.sh"', extract)
        build = (ROOT / "tools/build_micro_linux.py").read_text(encoding="utf-8")
        self.assertIn('"usr/lib/usos/windows_setup_media.sh"', build)

    def test_selected_system_is_recorded_and_exported(self):
        state = (ROOT / "src/platform/uefi/persistent_state_file.zig").read_text(encoding="utf-8")
        self.assertIn('"selected_system="', state)
        flow = (ROOT / "src/platform/uefi/e2e_flow.zig").read_text(encoding="utf-8")
        self.assertIn("resolved_method.persistedValue(), system.id, try plan.stateKeys(&plan_keys));", flow)
        init = (ROOT / "tools/micro_linux_init.sh").read_text(encoding="utf-8")
        self.assertIn("SELECTED_SYSTEM=$(ini_value selected_system", init)
        self.assertIn("SELECTED_METHOD SELECTED_SYSTEM SELECTED_ISO WIM_FILE WIM_TEMPLATE", init)
        bios = (ROOT / "tools/legacy_windows_request.sh").read_text(encoding="utf-8")
        self.assertIn("printf 'selected_system=%s", bios)

    def test_esd_and_swm_accepted_at_handoff(self):
        work = (ROOT / "src/platform/uefi/work_volume.zig").read_text(encoding="utf-8")
        self.assertIn("windows_detect.firstInstallImage(root, existsCaseInsensitive)", work)
        self.assertNotIn('"sources/install.wim"', work)
        native = (ROOT / "src/platform/bios/windows_native_iso.zig").read_text(encoding="utf-8")
        self.assertIn('"sources/install.wim", "sources/install.esd", "sources/install.swm"', native)
        for script in ("windows_iso_startup.cmd", "windows_bios_startup.cmd"):
            text = (ROOT / "tools" / script).read_text(encoding="utf-8")
            self.assertIn("install.esd", text, script)
            self.assertIn("install.swm", text, script)


if __name__ == "__main__":
    unittest.main()
