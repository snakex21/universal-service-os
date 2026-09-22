"""Check boot environment compatibility independently of the installed OS name."""
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SH = shutil.which('sh') or r'C:\Program Files\Git\bin\sh.exe'


class CpuCheckTests(unittest.TestCase):
    def check(self, major=10, minor=0, arch=9, flags='sse2 nx lm', boot_index=2,
              xml_override=None, truncate=False):
        xml = xml_override or ('<WIM><IMAGE INDEX="1"><WINDOWS><ARCH>0</ARCH>'
            '<VERSION><MAJOR>6</MAJOR><MINOR>1</MINOR></VERSION></WINDOWS></IMAGE>'
            f'<IMAGE INDEX="2"><NAME>Windows 7 updated</NAME><WINDOWS><ARCH>{arch}</ARCH>'
            f'<VERSION><MAJOR>{major}</MAJOR><MINOR>{minor}</MINOR></VERSION>'
            '</WINDOWS></IMAGE></WIM>')
        data = ('\ufeff' + xml).encode('utf-16le')
        header = bytearray(208)
        header[:8] = b'MSWIM\0\0\0'
        struct.pack_into('<I', header, 8, 208)
        struct.pack_into('<QQQ', header, 72, len(data) | (2 << 56), 208, len(data))
        struct.pack_into('<I', header, 120, boot_index)
        with tempfile.TemporaryDirectory(dir=ROOT / 'zig-out') as tmp:
            folder = Path(tmp)
            wim = folder / 'boot.wim'
            wim.write_bytes(header + (b'' if truncate else data))
            cpu = folder / 'cpuinfo'
            cpu.write_text(f'processor : 0\nflags : {flags}\n', encoding='ascii')
            return subprocess.run([SH, (ROOT / 'tools/windows_bios_cpu_check.sh').as_posix(),
                wim.as_posix(), cpu.as_posix()], text=True, capture_output=True,
                env={**os.environ, 'LC_ALL': 'C'})

    def test_new_pe_on_old_cpu_is_rejected_even_when_named_windows7(self):
        result = self.check()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('This ISO needs CMPXCHG16B', result.stdout)

    def test_new_pe_on_capable_cpu_passes(self):
        result = self.check(flags='sse2 nx lm cx16')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CPU CHECK PASS', result.stdout)

    def test_older_x64_and_x86_pe_do_not_require_cx16(self):
        for major, minor, arch in [(6, 1, 9), (6, 2, 9), (10, 0, 0)]:
            with self.subTest(version=(major, minor, arch)):
                result = self.check(major, minor, arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('CPU CHECK PASS', result.stdout)

    def test_uses_boot_image_index(self):
        result = self.check(boot_index=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('architecture=0 Windows=6.1', result.stdout)

    def test_truncated_metadata_does_not_claim_compatibility(self):
        result = self.check(truncate=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CPU CHECK UNKNOWN', result.stdout)
        self.assertNotIn('CPU CHECK PASS', result.stdout)

    def test_flag_match_is_exact(self):
        result = self.check(flags='sse2 nx lm nocx16 cx160')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
