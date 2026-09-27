"""tools/nt5_user_drivers.sh (DATA\\Drivers\\<system> for Server 2003 x86 and
XP x64): package discovery, architecture filter, copy + readback, and the
WINNT.SIF OemPnPDriversPath key. Host-only; synthetic INFs, no drivers."""
from pathlib import Path
import os, shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
# Git's sh first: its coreutils include cmp (like BusyBox in the initramfs).
SH = next((p for p in (r'C:\Program Files\Git\usr\bin\sh.exe', r'C:\msys64\usr\bin\sh.exe', shutil.which('sh') or '') if p and Path(p).exists()), None)
if SH:
    os.environ['PATH'] = str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', '')


def posix(path: Path) -> str:
    s = str(path.resolve()).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if s[1:2] == ':' else s


def inf(models: str) -> bytes:
    return ('[Version]\r\nSignature="$Windows NT$"\r\n[Manufacturer]\r\n%V% = Models' + models + '\r\n').encode()


@unittest.skipIf(SH is None, 'sh not found')
class Nt5UserDrivers(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        d = self.tmp / 'Drivers'
        for rel, data in {
            'USB/xhci64/usb3.inf': inf(', NTamd64'), 'USB/xhci64/amd64/usb3.sys': b'x64',
            'USB/xhci32/usb3.inf': inf(', NTx86'), 'USB/xhci32/usb3.sys': b'x86',
            'Storage/ahci/ahci.inf': inf(''), 'Storage/ahci/ahci.sys': b'plain',
            'Other/nic/nic.inf': inf(', NTx86, NTamd64'), 'Other/nic/nic.sys': b'nic',
            'Loose/pkg/gpu.inf': inf(', NTamd64'),
        }.items():
            p = d / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
        (d / 'Other' / 'stray.inf').write_bytes(inf(', NTamd64'))
        self.drivers = d
        self.target = self.tmp / 'target'; self.target.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_stage(self, arch):
        lib = posix(ROOT / 'tools' / 'nt5_user_drivers.sh')
        return subprocess.run([SH, '-c', f". '{lib}'; usos_nt5_user_drivers_stage '{posix(self.drivers)}' '{posix(self.target)}' {arch}"], capture_output=True)

    def test_amd64(self):
        r = self.run_stage('amd64')
        self.assertEqual(r.returncode, 0, r.stderr)
        value = r.stdout.decode()
        self.assertEqual(value, 'USOS\\Drivers\\User\\USB-01;USOS\\Drivers\\User\\Other-02;USOS\\Drivers\\User\\Other-03')
        user = self.target / 'USOS' / 'Drivers' / 'User'
        self.assertEqual((user / 'USB-01' / 'amd64' / 'usb3.sys').read_bytes(), b'x64')
        self.assertEqual(sorted(p.name for p in user.iterdir()), ['Other-02', 'Other-03', 'USB-01'])
        log = r.stderr.decode()
        self.assertIn('skipped USB/xhci32: no INF for amd64', log)
        self.assertIn('skipped Storage/ahci: no INF for amd64', log)
        self.assertIn('loose INF', log)

    def test_x86(self):
        r = self.run_stage('x86')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.decode(), 'USOS\\Drivers\\User\\Storage-01;USOS\\Drivers\\User\\USB-02;USOS\\Drivers\\User\\Other-03')

    def test_empty_and_missing(self):
        shutil.rmtree(self.drivers)
        r = self.run_stage('amd64')
        self.assertEqual((r.returncode, r.stdout), (0, b''))

    def test_sif_key(self):
        lib = posix(ROOT / 'tools' / 'nt5_user_drivers.sh')
        base = b'[Data]\r\nx=1\r\n[Unattended]\r\nOemPnPDriversPath="old"\r\nOemSkipEula=Yes\r\n'
        r = subprocess.run([SH, '-c', f". '{lib}'; usos_nt5_user_drivers_sif 'USOS\\Drivers\\User\\USB-01'"], input=base, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = [l.rstrip('\r') for l in r.stdout.decode().split('\n')]
        self.assertEqual(lines[lines.index('[Unattended]') + 1], 'OemPnPDriversPath="USOS\\Drivers\\User\\USB-01"')
        self.assertNotIn('OemPnPDriversPath="old"', lines)
        self.assertEqual(subprocess.run([SH, '-c', f". '{lib}'; usos_nt5_user_drivers_sif x"], input=b'[Data]\r\n', capture_output=True).returncode, 3)


if __name__ == '__main__':
    unittest.main()
