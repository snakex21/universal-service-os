"""Check the actual Setup volume identities, including offsets above 4 GiB."""
import shutil
import struct
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AWK = shutil.which('awk') or r'C:\Program Files\Git\usr\bin\awk.exe'


class DriveLettersTests(unittest.TestCase):
    def generate(self, signature='cdab3412', windows='4196352', setup='2048'):
        return subprocess.run([AWK, '-v', 'signature=' + signature,
                               '-v', 'windows_start=' + windows, '-v', 'setup_start=' + setup,
                               '-f', str(ROOT / 'tools/xp_drive_letters.awk')], capture_output=True)

    def test_volume_identity_and_letters(self):
        for start in (4196352, 16777216, 4294967295):
            result = self.generate(windows=str(start))
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.decode().splitlines()
            for line, letter, lba in zip(lines[-1:], ('C',), (start,)):
                self.assertIn('"\\DosDevices\\' + letter + ':"', line)
                data = bytes(int(byte, 16) for byte in line.split(',')[4:])
                self.assertEqual(data, struct.pack('<IQ', 0x1234abcd, lba * 512))
            self.assertNotIn(b'\n', result.stdout.replace(b'\r\n', b''))

    def test_invalid_identity_is_rejected_without_partial_output(self):
        for signature, windows, setup in [('00000000', '4196352', '2048'),
                ('abcdefg1', '4196352', '2048'), ('1234', '4196352', '2048'),
                ('cdab3412', '-1', '2048'),
                ('cdab3412', '4294967296', '2048'), ('cdab3412', '1.5', '2048'),
                ('cdab3412', '0', '2048')]:
            with self.subTest(signature=signature, windows=windows, setup=setup):
                result = self.generate(signature, windows, setup)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')

    def test_generator_does_not_wait_for_terminal_input(self):
        process = subprocess.Popen([AWK, '-v', 'signature=cdab3412', '-v', 'windows_start=2048',
                                    '-f', str(ROOT / 'tools/xp_drive_letters.awk')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.wait(timeout=3), 0)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()


if __name__ == '__main__':
    unittest.main()
