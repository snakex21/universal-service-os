# SPDX-License-Identifier: GPL-3.0-or-later
"""Separate boot-client output guard; no compiler, VM or image is launched."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/minios'))
spec=importlib.util.spec_from_file_location('bios_boot_builder',REPO/'tools/minios/build_bios_boot.py')
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)


class BiosBootBuildGuards(unittest.TestCase):
    def test_output_outside_isolated_zig_out_refuses_before_any_compiler_or_directory_creation(self):
        temporary=REPO/'runtime/bios-boot-unit';temporary.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            outside=Path(directory)/'forbidden.img'
            work=REPO/'zig-out/bios-boot-guard-never-created'
            argv=['build_bios_boot.py','--zig','unavailable-zig','--output',str(outside),'--work-dir',str(work)]
            with (patch.object(sys,'argv',argv),patch.object(builder.subprocess,'run') as compiler,
                  patch.object(builder.build_bios_bootcode,'build') as code):
                with self.assertRaisesRegex(ValueError,'Isolated zig-out'):builder.main()
                compiler.assert_not_called();code.assert_not_called()
            self.assertFalse(outside.exists());self.assertFalse(work.exists())


if __name__=='__main__':unittest.main()
