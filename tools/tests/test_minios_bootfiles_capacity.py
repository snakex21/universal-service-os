# SPDX-License-Identifier: GPL-3.0-or-later
"""The historical one-case capacity override cannot enter a release."""
import ast
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/minios'))
import wim_pool as pool

class GuardTest(unittest.TestCase):
    def test_override_module_and_cli_have_been_removed(self):
        self.assertFalse((ROOT/'tools/minios/bootfiles_capacity.py').exists())
        source=(ROOT/'tools/minios/boot_provision_case.py').read_text()
        self.assertNotIn('review_capacity',source)
        self.assertNotIn('bootfiles_capacity',source)
        self.assertNotIn("parser.add_argument('--approval'",source)
        self.assertNotIn("parser.add_argument('--firstboot-receipt'",source)
        self.assertEqual(pool.MAX_CAP,150*1024**3)
        for node in ast.walk(ast.parse(source)):
            if isinstance(node,ast.Assign):
                for target in node.targets:
                    if isinstance(target,ast.Attribute):
                        self.assertNotIn(target.attr,('MAX_CAP','storage_guard'))

if __name__=='__main__':unittest.main()
