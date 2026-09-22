"""Short local-file checks; no WinPE, Windows Setup, USB writes or VM."""
from pathlib import Path
import os, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'zig-out/setup-logging-tests'
class Logging(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        OUT.mkdir(parents=True,exist_ok=True)
        env=dict(os.environ,TEMP=str(OUT),TMP=str(OUT),ZIG_LOCAL_CACHE_DIR=str(OUT/'cache'),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'))
        cls.helper=OUT/'snapshot.exe'
        subprocess.run([str(ROOT/'tools/zig/zig.exe'),'cc','-target','x86_64-windows-gnu','-Os',str(ROOT/'tools/tests/windows_setup_logging_harness.c'),'-ladvapi32','-o',str(cls.helper)],check=True,env=env)
    def check_copy(self,payload,tail=False):
        with tempfile.TemporaryDirectory(dir=OUT) as temp:
            folder=Path(temp);source=folder/'live.log';destination=folder/'usb-session';destination.mkdir()
            source.write_bytes(payload)
            result=subprocess.run([str(self.helper),str(source),str(destination)],capture_output=True,timeout=10)
            self.assertEqual(0,result.returncode,result.stderr)
            saved=destination/('snapshot.log.tail' if tail else 'snapshot.log')
            self.assertEqual(payload[-16*1024*1024:] if tail else payload,saved.read_bytes())
            self.assertEqual(payload,source.read_bytes())
    def test_log_can_be_copied_while_writer_keeps_it_open(self):
        self.check_copy(b'Error ProductKey\r\nphase=launch-setup\r\n')
    def test_empty_log_is_preserved(self):self.check_copy(b'')
    def test_large_log_keeps_latest_sixteen_megabytes(self):
        self.check_copy(b'old\n'+b'x'*(16*1024*1024)+b'latest error\n',True)
if __name__=='__main__':unittest.main()
