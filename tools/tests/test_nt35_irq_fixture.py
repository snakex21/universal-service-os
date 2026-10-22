"""Host-only guards for the installed NT35 IRQ qualification fixture."""
from pathlib import Path
import importlib.util
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools/tests/coverage' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


boot = load('nt35_irq_fixture_boot', 'boot_nt35_irq_fixed.py')
prepare = load('nt35_irq_fixture_prepare', 'prepare_nt35_irq_fixed.py')


class HardwareGuard(unittest.TestCase):
    def baseline(self):
        return [str(boot.QEMU), '-machine', 'q35', '-cpu', 'EPYC-Rome', '-smp', '2',
            '-m', '2048', '-accel', 'tcg,thread=multi', '-qmp', 'old-qmp',
            '-device', 'igb,netdev=usabilitynet,mac=52:54:00:55:53:01',
            '-drive', 'if=pflash,format=raw,readonly=on,file=' + (boot.QEMU.parent / 'share/edk2-x86_64-code.fd').as_posix(),
            '-drive', 'if=pflash,format=raw,file=' + boot.BASE.as_posix() + '/vars.fd',
            '-drive', 'if=none,id=stick,format=qcow2,file=' + boot.BASE.as_posix() + '/stick.qcow2',
            '-drive', 'if=none,id=target,format=qcow2,file=' + boot.BASE.as_posix() + '/target.qcow2',
            '-chardev', 'socket,id=nt351mirror,host=127.0.0.1,port=123,server=off']

    def test_only_images_and_loopback_ports_change(self):
        before = self.baseline()
        after = boot.command(before, 234, 345)
        self.assertEqual(before, self.baseline())
        for old, new in zip(before, after):
            if old == 'old-qmp':
                self.assertEqual(new, 'tcp:127.0.0.1:234,server=off')
            elif old.startswith('socket,id=nt351mirror,'):
                self.assertEqual(new, 'socket,id=nt351mirror,host=127.0.0.1,port=345,server=off')
            elif 'file=' + boot.BASE.as_posix() + '/' in old:
                self.assertEqual(new, old.replace(boot.BASE.as_posix(), boot.WORK.as_posix()))
            else:
                self.assertEqual(new, old)

    def test_refuse_hardware_or_unexpected_disk(self):
        for old, new in [('EPYC-Rome', 'host'), ('2048', '4096'), ('q35', 'pc'),
                         ('igb,netdev=usabilitynet,mac=52:54:00:55:53:01', 'e1000')]:
            data = [new if item == old else item for item in self.baseline()]
            with self.assertRaises(ValueError):
                boot.command(data, 234, 345)
        data = self.baseline() + ['-drive', 'file=' + boot.BASE.as_posix() + '/other.qcow2']
        with self.assertRaises(ValueError):
            boot.command(data, 234, 345)
        data = self.baseline() + ['-drive', 'file=\\\\.\\PhysicalDrive0']
        with self.assertRaises(ValueError):
            boot.command(data, 234, 345)


class WholeDiskWhitelist(unittest.TestCase):
    def test_byte_outside_owned_file_is_detected(self):
        scratch = ROOT / 'artifacts/nt35-irq/host-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory) / 'own-synthetic-disk.bin'
            original = bytes(range(256)) * 8
            path.write_bytes(original)
            baseline = prepare.outside_digest(path, [(64, 32), (512, 32)])
            changed = bytearray(original)
            changed[64:96] = b'X' * 32
            changed[512:544] = b'Y' * 32
            path.write_bytes(changed)
            self.assertEqual(prepare.outside_digest(path, [(64, 32), (512, 32)]), baseline)
            changed[1024] ^= 1
            path.write_bytes(changed)
            self.assertNotEqual(prepare.outside_digest(path, [(64, 32), (512, 32)]), baseline)

    def test_overlapping_or_negative_ranges_refused(self):
        scratch = ROOT / 'artifacts/nt35-irq/host-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory) / 'own-synthetic-disk.bin'
            path.write_bytes(b'A' * 64)
            for ranges in ([(-1, 1)], [(4, 8), (5, 1)], [(3, -1)]):
                with self.assertRaises(ValueError):
                    prepare.outside_digest(path, ranges)


if __name__ == '__main__':
    unittest.main()
