from pathlib import Path
import importlib.util
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
s=importlib.util.spec_from_file_location('own_micro_builder',ROOT/'tools/build_micro_linux.py')
builder=importlib.util.module_from_spec(s);s.loader.exec_module(builder)
BINARY='usr/bin/qemu-system-i386'
KEYMAP='usr/share/qemu/keymaps/en-us'
FILES=[BINARY,'usr/share/qemu/bios-256k.bin','usr/share/qemu/vgabios-stdvga.bin',KEYMAP]

class KeymapPackage(unittest.TestCase):
    def package(self,names):
        entries=[builder.Entry(name,0o100644,b'own synthetic runtime data') for name in names]
        with patch.object(builder,'archive_entries',return_value=entries),patch.object(builder,'elf_needed',return_value=[]):
            return builder.qemu9x_entries({'binary':BINARY},[({'files':FILES},Path('synthetic.apk'))],{})

    def test_runtime_keymap_is_kept(self):
        entries=self.package(FILES)
        self.assertEqual(entries[KEYMAP].data,b'own synthetic runtime data')

    def test_missing_keymap_rejects_incomplete_package(self):
        with self.assertRaisesRegex(RuntimeError,'keymaps/en-us'):
            self.package(FILES[:-1])

if __name__=='__main__':unittest.main()
