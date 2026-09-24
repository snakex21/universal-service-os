#!/usr/bin/env python3
"""Windows 7 stock-PE7 path without an answer file: the user's Drivers\\Windows 7
packages reach the installed system through SetupComplete.cmd (pnputil),
never through a forced /unattend (which would make Setup ask for a product
key). Static checks of tools/windows7_native_startup.cmd and the template.

    python tools/tests/test_windows7_user_drivers_setupcomplete.py
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SetupCompletePath(unittest.TestCase):
    def setUp(self):
        self.script = (ROOT / "tools/windows7_native_startup.cmd").read_text(encoding="utf-8")
        self.template = (ROOT / "tools/windows7_setupcomplete.cmd").read_text(encoding="utf-8")

    def test_only_without_an_answer_file_and_after_setup_applied_the_image(self):
        call = 'if "%USOS_NEED_UNATTEND%"=="0" call :user_drivers_setupcomplete'
        self.assertIn(call, self.script)
        self.assertLess(self.script.index("run /noreboot"), self.script.index(call))
        self.assertLess(self.script.index(call), self.script.index('"%~dp0usos-win7-finalize.exe" after'))
        # The manual path still never forces an answer file for user drivers.
        self.assertIn('set "USOS_NEED_UNATTEND=0"', self.script)
        self.assertNotIn("usos-win7-drivers\\user\" set \"USOS_NEED_UNATTEND=1", self.script)

    def test_target_is_the_single_new_windows_installation(self):
        before = self.script.index('echo %%D>>"%~dp0usos-old-windows.txt"')
        self.assertLess(before, self.script.index("run /noreboot"))
        body = self.script[self.script.index(":user_drivers_setupcomplete"):]
        self.assertIn('if not "%USOS_TARGET_COUNT%"=="1"', body)
        self.assertIn('find /i "%~1" "%~dp0usos-old-windows.txt"', body)
        self.assertNotIn("findstr", self.script)  # not in every WinPE
        self.assertIn("Windows\\Panther\\setupact.log", body)
        # Letters: never X: (the WinPE RAM disk).
        self.assertIn("for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z)", body)
        self.assertNotIn(" X Y Z)", body)

    def test_never_overwrites_the_image_setupcomplete_and_is_never_fatal(self):
        body = self.script[self.script.index("\n:user_drivers_setupcomplete"):self.script.index("\n:user_drivers_candidate")]
        self.assertLess(body.index('if exist "%USOS_TARGET%:\\Windows\\Setup\\Scripts\\SetupComplete.cmd"'), body.index("copy /y"))
        self.assertNotIn("exit /b 1", body)

    def test_template_installs_every_class_with_pnputil(self):
        self.assertIn("for %%C in (Storage USB Other)", self.template)
        self.assertIn('pnputil.exe" -i -a "%%I"', self.template)
        self.assertIn("%SystemDrive%\\USOS\\Drivers", self.template)
        self.assertIn("exit /b 0", self.template)
        support = (ROOT / "tools/build_windows_native_support.py").read_text(encoding="utf-8")
        self.assertIn("'usos-win7-setupcomplete.cmd', (root / 'tools/windows7_setupcomplete.cmd')", support)


if __name__ == "__main__":
    unittest.main()
