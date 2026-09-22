import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from wimboot_kexec import make_kexec_wimboot, WIMBOOT_SHA256


class HandoffImageTest(unittest.TestCase):
    def setUp(self):
        self.original = (ROOT / 'tools/vendor/wimboot/2.9.0/wimboot').read_bytes()

    def test_preserves_windows_payload_and_linux_memory_contract(self):
        image = make_kexec_wimboot(self.original)
        self.assertEqual(len(image), len(self.original))
        payload = (self.original[0x1f1] + 1) * 512
        self.assertEqual(image[payload:], self.original[payload:])
        self.assertEqual(image[0x1f1:0x202], self.original[0x1f1:0x202])
        self.assertEqual(image[0x210:0x230], self.original[0x210:0x230])
        entry = 0x202 + self.original[0x201]
        allowed = {entry + 2, entry + 3} | set(range(0x400, 0x580))
        self.assertTrue(all(i in allowed for i, (a, b) in enumerate(zip(image, self.original)) if a != b))
        self.assertEqual(hashlib.sha256(self.original).hexdigest(), WIMBOOT_SHA256)

    def test_entry_returns_to_original_code_after_bios_restore(self):
        image = make_kexec_wimboot(self.original)
        entry = 0x202 + self.original[0x201]
        self.assertEqual(struct.unpack_from('<H', image, entry + 2)[0], 0x400)
        self.assertEqual(image[0x400:0x408], bytes.fromhex('fa fc 2e 0f 01 1e 80 04'))
        resume = self.original[entry + 2:entry + 4]
        self.assertIn(b'\x0e\x68' + resume + b'\xcb', image[0x400:0x480])
        self.assertEqual(struct.unpack_from('<HI', image, 0x480), (0x3ff, 0))

    def test_refuses_changed_vendor_binary(self):
        bad = bytearray(self.original)
        bad[-1] ^= 1
        with self.assertRaises(ValueError):
            make_kexec_wimboot(bytes(bad))

    def test_restores_text_display_after_firmware_interrupt_setup(self):
        image = make_kexec_wimboot(self.original)
        reset = bytes.fromhex('66 60 1e 06 0f a0 0f a8 b8 03 00 cd 10 0f a9 0f a1 07 1f 66 61 fa fc')
        at = image.index(reset, 0x400, 0x480)
        self.assertGreater(at, image.index(bytes.fromhex('b0 36 e6 43'), 0x400, 0x480))
        self.assertEqual(image[at + len(reset):at + len(reset) + 2], b'\x0e\x68')

    def test_geometry_hook_lives_in_reserved_runtime_prefix(self):
        image = make_kexec_wimboot(self.original)
        self.assertIn(bytes.fromhex('b8 00 20 8e c0'), image[0x520:0x580])
        self.assertIn(bytes.fromhex('c7 06 4c 00 a0 04 c7 06 4e 00 00 20'), image[0x520:0x580])
        # The original disk count and numbering must not be overwritten.
        self.assertNotIn(bytes.fromhex('c6 06 75 04'), image[0x400:0x580])
        self.assertIn(bytes.fromhex('8a 1e 75 04'), image[0x4a0:0x4f0])
        self.assertEqual(struct.unpack_from('<H', image, 0x536)[0], 512)
        # Pinned prefix.S clears bss16 starting at 0x20a00; our complete
        # runtime workspace must end before that and be inside _prefix.
        self.assertEqual(self.original[0x276], 0xbf)
        bss16 = struct.unpack_from('<I', self.original, 0x277)[0]
        prefix_size = (self.original[0x1f1] + 1) * 512
        self.assertEqual(bss16 - prefix_size, 0x20000)
        self.assertLessEqual(0x204a0 + 512, bss16)

    def test_geometry_return_preserves_callers_interrupt_flag(self):
        image = make_kexec_wimboot(self.original)
        # Clear only the carry bit through the outer FLAGS frame, keeping
        # the caller's interrupt enable state.
        self.assertIn(bytes.fromhex('36 83 66 06 fe'), image[0x4a0:0x4f0])
        self.assertNotIn(bytes.fromhex('36 89 46 06'), image[0x4a0:0x4f0])


if __name__ == '__main__':
    unittest.main()
