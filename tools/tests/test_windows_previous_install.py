"""usos-log --previous-install (tools/windows_setup_logging.c) on fake volumes.

Host only: a folder stands in for a target volume; the check must find an
unfinished install (State.ini not at IMAGE_STATE_COMPLETE, or a leftover
$WINDOWS.~BT), copy the listed diagnostics within the size cap, and leave
every file of the volume byte- and timestamp-identical.
"""
from pathlib import Path
import hashlib, os, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'zig-out/previous-install-tests'
MiB = 1024 * 1024


def tree(folder):
    return {str(p.relative_to(folder)): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
            for p in folder.rglob('*') if p.is_file()}


class PreviousInstall(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        OUT.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, TEMP=str(OUT), TMP=str(OUT), ZIG_LOCAL_CACHE_DIR=str(OUT / 'cache'), ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
        cls.helper = OUT / 'previous.exe'
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-target', 'x86_64-windows-gnu', '-Os',
                        str(ROOT / 'tools/tests/windows_previous_install_harness.c'), '-ladvapi32', '-o', str(cls.helper)], check=True, env=env)

    def volume(self, base, state=None, bt=False, extra=()):
        vol = base / 'vol'
        def put(rel, data):
            path = vol / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        put('Windows/Panther/setupact.log', b'setupact line\r\n')
        put('Windows/Panther/setuperr.log', b'Error [0x08001f] specialize\r\n')
        put('Windows/Panther/UnattendGC/setupact.log', b'gc\r\n')
        put('Windows/System32/winevt/Logs/System.evtx', b'ElfFile\x00' + b'e' * 1000)
        put('Windows/System32/winevt/Logs/Setup.evtx', b'ElfFile\x00' + b's' * 1000)
        put('Windows/Minidump/092526-1.dmp', b'PAGEDU64' + b'd' * 100)
        if state is not None:
            put('Windows/Setup/State/State.ini', state)
        if bt:
            put('$WINDOWS.~BT/Sources/Panther/setupact.log', b'bt setupact\r\n')
        for rel, data in extra:
            put(rel, data)
        return vol

    def scan(self, vol, session):
        session.mkdir()
        return subprocess.run([str(self.helper), str(vol) + chr(92), str(session)], capture_output=True, text=True, timeout=30)

    def test_aborted_specialize_is_found_and_copied_read_only(self):
        with tempfile.TemporaryDirectory(dir=OUT) as t:
            base = Path(t)
            vol = self.volume(base, b'[State]\r\nImageState=IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE\r\n', bt=True)
            before = tree(vol)
            result = self.scan(vol, base / 'session')
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('WARNING: unfinished or aborted Windows installation', result.stdout)
            self.assertIn('$WINDOWS.~BT present', result.stdout)
            out = base / 'session/previous-install/T'
            for name in ('panther-setupact.log', 'panther-setuperr.log', 'State.ini', 'bt-panther-setupact.log',
                         'unattendgc-setupact.log', 'System.evtx', 'Setup.evtx', 'minidump-092526-1.dmp', 'summary.txt'):
                self.assertTrue((out / name).is_file(), name)
            self.assertEqual((out / 'panther-setuperr.log').read_bytes(), b'Error [0x08001f] specialize\r\n')
            self.assertIn(b'not IMAGE_STATE_COMPLETE', (out / 'summary.txt').read_bytes())
            self.assertEqual(before, tree(vol))

    def test_completed_install_is_ignored(self):
        with tempfile.TemporaryDirectory(dir=OUT) as t:
            base = Path(t)
            vol = self.volume(base, b'[State]\r\nImageState=IMAGE_STATE_COMPLETE\r\n')
            result = self.scan(vol, base / 'session')
            self.assertEqual(result.returncode, 1)
            self.assertFalse((base / 'session/previous-install').exists())

    def test_utf16_complete_state_is_recognised(self):
        with tempfile.TemporaryDirectory(dir=OUT) as t:
            base = Path(t)
            vol = self.volume(base, '[State]\r\nImageState=IMAGE_STATE_COMPLETE\r\n'.encode('utf-16'))
            self.assertEqual(self.scan(vol, base / 'session').returncode, 1)

    def test_leftover_bt_alone_is_found(self):
        with tempfile.TemporaryDirectory(dir=OUT) as t:
            base = Path(t)
            vol = self.volume(base, None, bt=True)
            result = self.scan(vol, base / 'session')
            self.assertEqual(result.returncode, 0)
            self.assertIn(b'State.ini: missing', (base / 'session/previous-install/T/summary.txt').read_bytes())

    def test_a_blank_disk_is_ignored(self):
        with tempfile.TemporaryDirectory(dir=OUT) as t:
            base = Path(t)
            (base / 'vol').mkdir()
            self.assertEqual(self.scan(base / 'vol', base / 'session').returncode, 1)

    def test_size_caps(self):
        with tempfile.TemporaryDirectory(dir=OUT) as t:
            base = Path(t)
            big_log = b'old\n' + b'x' * (9 * MiB) + b'newest error\n'
            vol = self.volume(base, b'[State]\r\nImageState=IMAGE_STATE_UNDEPLOYABLE\r\n', extra=[
                ('Windows/Panther/setupact.log', big_log),
                ('Windows/System32/winevt/Logs/System.evtx', b'E' * (9 * MiB)),
            ] + [(f'Windows/Minidump/{i}.dmp', b'D' * (7 * MiB)) for i in range(5)])
            result = self.scan(vol, base / 'session')
            self.assertEqual(result.returncode, 0)
            out = base / 'session/previous-install/T'
            self.assertEqual((out / 'panther-setupact.log.tail').read_bytes(), big_log[-8 * MiB:])
            self.assertFalse((out / 'System.evtx').exists())
            summary = (out / 'summary.txt').read_text()
            self.assertIn('skipped (larger than 8 MiB)', summary)
            self.assertIn('skipped (copy budget used up)', summary)
            total = sum(p.stat().st_size for p in out.iterdir() if p.name != 'summary.txt')
            self.assertLessEqual(total, 32 * MiB)


if __name__ == '__main__':
    unittest.main()
