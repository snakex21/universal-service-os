# SPDX-License-Identifier: GPL-3.0-or-later
"""Private thunk patch contracts and ELF diagnostic bounds; no firmware IO."""
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/minios'))


def module(name):
    spec=importlib.util.spec_from_file_location(name,REPO/'tools/minios'/(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


builder=module('build_bios_install')
evidence=module('bios_object_evidence')


class IsolatedBiosTests(unittest.TestCase):
    def test_private_core_keeps_bootstrap_abi_and_adds_explicit_sector_count(self):
        source=(REPO/'src/platform/bios/core.S').read_text()
        result=builder.patched_core(source)
        self.assertIn('bios_read_sector_drive:\n',result)
        self.assertIn('bios_read_sectors:\n',result)
        self.assertIn('bios_install_read_blocks:\n',result)
        self.assertIn('bios_install_write_blocks:\n',result)
        self.assertIn('cmp eax, 4096',result)
        self.assertIn('cmp eax, 65535',result)
        self.assertIn('mov ecx, dword ptr [THUNK_INSTALL_BYTES]',result)
        self.assertIn('mov dword ptr [bios_install_stack_top], esp',result)
        self.assertEqual((REPO/'src/platform/bios/core.S').read_text(),source)

    def test_changed_thunk_anchor_refuses_instead_of_silent_patch(self):
        source=(REPO/'src/platform/bios/core.S').read_text()
        with self.assertRaisesRegex(ValueError,'Legacy thunk anchor changed'):
            builder.patched_core(source.replace('core_start:\n    cld\n','core_start:\n'))

    def test_elf_section_evidence_rejects_truncation_and_wrong_class(self):
        for data in (b'',b'\x7fELF\x02\x01'+bytes(100),b'\x7fELF\x01\x01'+bytes(46)):
            with self.assertRaises(ValueError):evidence.analyze(data)


if __name__=='__main__':unittest.main()
