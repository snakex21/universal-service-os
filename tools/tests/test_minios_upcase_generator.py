# SPDX-License-Identifier: GPL-3.0-or-later
"""The generator must retain the compact runtime used by the BIOS build."""
import contextlib
import importlib.util
import io
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'tools' / 'minios' / 'generate_upcase.py'


class UpcaseGeneratorTests(unittest.TestCase):
    def test_regeneration_preserves_compact_runtime_and_golden_hash(self):
        spec = importlib.util.spec_from_file_location('minios_generate_upcase', MODULE)
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        source = (ROOT / 'src/prep/unicode_upper.zig').read_text(encoding='utf-8')
        pairs_text = source.split('const pairs = [_]u32{', 1)[1].split('};', 1)[0]
        table = list(range(65536))
        for raw in re.findall(r'0x[0-9a-fA-F]{8}', pairs_text):
            pair = int(raw, 16)
            table[pair >> 16] = pair & 0xffff
        root = ROOT / 'runtime'
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            input_file = Path(directory) / 'input'
            output_file = Path(directory) / 'generated.zig'
            input_file.write_bytes(b'synthetic input: parser is mocked')
            with mock.patch.object(generator, 'table_from_source', return_value=table), \
                 mock.patch.object(sys, 'argv', [str(MODULE), str(input_file), str(output_file)]), \
                 contextlib.redirect_stdout(io.StringIO()):
                generator.main()
            generated = output_file.read_text(encoding='utf-8')
        template = MODULE.with_name('unicode_upper_runtime.zig.inc').read_text(encoding='utf-8').rstrip()
        self.assertIn(template, generated)
        self.assertIn(re.search(r'pub const table_sha256 = "[0-9a-f]+";', source).group(), generated)
        self.assertIn('pub fn upperUnit(unit: u16)', generated)
        self.assertIn('packed mappings preserve every UTF16 unit', generated)


if __name__ == '__main__':
    unittest.main()
