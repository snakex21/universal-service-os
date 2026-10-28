# SPDX-License-Identifier: GPL-3.0-or-later
"""7-Zip listing/stream framing is independent of the optical implementation."""
import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/minios'))
spec=importlib.util.spec_from_file_location('optical_oracle',REPO/'tools/minios/optical_oracle.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
TMP=REPO/'runtime/optical-unit-tmp'
TMP.mkdir(parents=True,exist_ok=True)


class FakeProcess:
    def __init__(self,stdout=None,code=0):
        self.stdout=None if stdout is None else io.BytesIO(stdout)
        self.returncode=None
        self.code=code
        self.killed=False
    def wait(self):
        self.returncode=self.code
        return self.code
    def kill(self):
        self.killed=True


class FakeChildren:
    """Two passes, with stderr written directly to the supplied regular file."""
    def __init__(self,data,log,first_code=0,second_code=0,second_log=None):
        self.data=data;self.log=log;self.codes=[first_code,second_code]
        self.second_log=log if second_log is None else second_log
        self.calls=[]
    def __call__(self,command,*,stdout,stderr):
        index=len(self.calls);self.calls.append(stdout)
        stderr.write(self.log if index==0 else self.second_log)
        self.assert_not_pipe(stderr)
        return FakeProcess(None if stdout==m.subprocess.DEVNULL else self.data,self.codes[index])
    @staticmethod
    def assert_not_pipe(stderr):
        if not hasattr(stderr,'fileno'):raise AssertionError('stderr must be a regular log file')


class OracleTests(unittest.TestCase):
    def test_listing_preserves_unicode_directories_empty_and_large_files(self):
        rows=m.listing('archive\n----------\nPath = Sources\nFolder = +\nSize = \n\n'
                       'Path = Sources\\Long Żółć.txt\nFolder = -\nSize = 4294967301\n\n'
                       'Path = Sources\\empty\nFolder = -\nSize = 0\n\n')
        self.assertEqual(rows,[dict(path='Sources',directory=True,size=0),
                               dict(path='Sources/Long Żółć.txt',directory=False,size=4294967301),
                               dict(path='Sources/empty',directory=False,size=0)])

    def test_listing_excludes_7zip_synthetic_boot_view_only_expected_tree_is_compared(self):
        rows=m.listing(
            '\n----------\nPath = [BOOT]\nFolder = +\n\n'
            'Path = [BOOT]\\0-Boot-NoEmul.img\nFolder = -\nSize = 2048\n\n'
            'Path = BOOT\\real\nFolder = -\nSize = 7\n\n')
        self.assertEqual(rows,[dict(path='BOOT/real',directory=False,size=7)])

    def test_listing_rejects_parent_absolute_missing_separator_or_size(self):
        for name in ('../file','a/../file','/root'):
            with self.assertRaises(ValueError):
                m.listing('\n----------\nPath = '+name+'\nFolder = -\nSize = 3\n\n')
        with self.assertRaises(ValueError):m.listing('not an item listing')
        with self.assertRaises(KeyError):m.listing('\n----------\nPath = file\nFolder = -\n\n')

    def test_stream_order_uses_extraction_log_instead_of_listing(self):
        entries=[dict(path='dir',directory=True,size=0),dict(path='dir/a',directory=False,size=3),
                 dict(path='dir/zero',directory=False,size=0),dict(path='dir/β',directory=False,size=5)]
        children=FakeChildren(b'12345own','banner\n- dir\n- dir\\β\n- dir\\zero\n- dir\\a\nEverything is Ok\n'.encode())
        with tempfile.TemporaryDirectory(dir=TMP) as directory,patch.object(m.subprocess,'Popen',side_effect=children):
            path=Path(directory)/'stream.log'
            code,order=m.stream_files(Path('source.iso'),Path('7z'),Path('files'),entries,path,'HEAD own\nWORKTREE_DIRTY 1\n')
            self.assertEqual(code,0)
            self.assertEqual(order,['dir/β','dir/zero','dir/a'])
            self.assertEqual(entries[1]['sha256'],hashlib.sha256(b'own').hexdigest())
            self.assertEqual(entries[2]['sha256'],hashlib.sha256(b'').hexdigest())
            self.assertEqual(entries[3]['sha256'],hashlib.sha256(b'12345').hexdigest())
            self.assertTrue(path.read_text(encoding='utf8').startswith('HEAD own\nWORKTREE_DIRTY 1\n'))
            self.assertTrue(path.with_name('stream-order.log').read_text(encoding='utf8').startswith('HEAD own\nWORKTREE_DIRTY 1\n'))
            self.assertEqual(children.calls,[m.subprocess.DEVNULL,m.subprocess.PIPE])

    def test_stream_refuses_omitted_extra_duplicate_unknown_and_truncated_payload(self):
        cases=[(b'',b'', 'omitted'),(b'abcd',b'- a\n','Extra'),
               (b'abcabc',b'- a\n- a\n','Duplicate'),(b'abc',b'- unknown\n','Unexpected'),
               (b'ab',b'- a\n','Truncated')]
        for data,log,message in cases:
            children=FakeChildren(data,log)
            entries=[dict(path='a',directory=False,size=3)]
            with self.subTest(message=message),tempfile.TemporaryDirectory(dir=TMP) as directory,patch.object(m.subprocess,'Popen',side_effect=children):
                with self.assertRaisesRegex(ValueError,message):
                    m.stream_files(Path('source.iso'),Path('7z'),Path('files'),entries,Path(directory)/'stream.log','HEAD own\nWORKTREE_DIRTY 1\n')

    def test_stream_refuses_nonzero_tool_exit(self):
        for first,second in ((2,0),(0,2)):
            children=FakeChildren(b'abc',b'- a\n',first,second)
            with self.subTest(first=first,second=second),tempfile.TemporaryDirectory(dir=TMP) as directory,patch.object(m.subprocess,'Popen',side_effect=children):
                with self.assertRaisesRegex(ValueError,'failed: 2'):
                    m.stream_files(Path('source.iso'),Path('7z'),Path('files'),[dict(path='a',directory=False,size=3)],Path(directory)/'stream.log','')

    def test_stream_refuses_changed_order_in_second_completed_log(self):
        children=FakeChildren(b'abcdef',b'- a\n- b\n',second_log=b'- b\n- a\n')
        entries=[dict(path='a',directory=False,size=3),dict(path='b',directory=False,size=3)]
        with tempfile.TemporaryDirectory(dir=TMP) as directory,patch.object(m.subprocess,'Popen',side_effect=children):
            with self.assertRaisesRegex(ValueError,'order changed'):
                m.stream_files(Path('source.iso'),Path('7z'),Path('files'),entries,Path(directory)/'stream.log','')

    def test_payload_larger_than_pipe_with_deferred_stderr_cannot_deadlock(self):
        # Actual OS pipes and child processes: write4MiB BEFORE any stderr log.
        # The former event-queue implementation blocked until its kill deadline.
        script=('import sys\n'
                'data=b"own deferred stderr\\n"*2048\n'
                'for _ in range(100):sys.stdout.buffer.write(data)\n'
                'sys.stdout.buffer.flush()\n'
                'sys.stderr.write("- a\\n")\n')
        data=b'own deferred stderr\n'*2048*100
        real_popen=subprocess.Popen
        children=[]
        def shim(command,**kwargs):
            self.assertNotEqual(kwargs['stderr'],subprocess.PIPE)
            child=real_popen([sys.executable,'-I','-B','-c',script],**kwargs)
            children.append(child)
            return child
        entries=[dict(path='a',directory=False,size=len(data))]
        with tempfile.TemporaryDirectory(dir=TMP) as directory,patch.object(m.subprocess,'Popen',side_effect=shim):
            code,order=m.stream_files(Path('source.iso'),Path('7z'),Path('files'),entries,
                                      Path(directory)/'stream.log','HEAD own\nWORKTREE_DIRTY 1\n',timeout=5)
            self.assertEqual((code,order),(0,['a']))
            self.assertEqual(entries[0]['sha256'],hashlib.sha256(data).hexdigest())
            self.assertEqual(len(children),2)
            self.assertTrue(all(child.returncode==0 for child in children))

    def test_deadline_kills_and_reaps_child_in_either_pass(self):
        real_popen=subprocess.Popen
        complete='import sys;sys.stdout.buffer.write(b"abc");sys.stdout.buffer.flush();sys.stderr.write("- a\\n")'
        stalled='import time;time.sleep(60)'
        for stalled_pass in (0,1):
            children=[]
            def shim(command,**kwargs):
                script=stalled if len(children)==stalled_pass else complete
                child=real_popen([sys.executable,'-I','-B','-c',script],**kwargs)
                children.append(child)
                return child
            with self.subTest(stalled_pass=stalled_pass),tempfile.TemporaryDirectory(dir=TMP) as directory,patch.object(m.subprocess,'Popen',side_effect=shim):
                with self.assertRaisesRegex(TimeoutError,'deadline'):
                    m.stream_files(Path('source.iso'),Path('7z'),Path('files'),[dict(path='a',directory=False,size=3)],
                                   Path(directory)/'stream.log','HEAD own\nWORKTREE_DIRTY 1\n',timeout=5)
                self.assertTrue(all(child.returncode is not None for child in children))
                self.assertEqual(len(children),stalled_pass+1)

    def test_windows_reap_waits_for_handles_even_with_a_cached_exit_code(self):
        if m.os.name!='nt':self.skipTest('Windows redirected-handle lifetime')
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            path=Path(directory)/'child.log'
            with path.open('xb') as log:
                child=subprocess.Popen([sys.executable,'-I','-B','-c','import time;time.sleep(0.2)'],
                                       stdout=subprocess.DEVNULL,stderr=log)
                # Models Popen.terminate caching GetExitCodeProcess before its
                # process object is signaled; wait() alone would return now.
                child.returncode=0
                try:
                    m.reap(child)
                finally:
                    # Complete ownership even if an assertion above changes.
                    m.reap(child)
            # Windows denies this rename until the child's stderr is closed.
            # No sleeps, retries, deletion-error suppression or ignore_errors.
            renamed=path.with_name('closed.log')
            path.rename(renamed)
            self.assertTrue(renamed.is_file())

    def test_final_header_refuses_dirty_tree_and_development_records_it(self):
        with patch.object(m.logged_run,'tree',return_value=('abc',2)):
            with self.assertRaisesRegex(ValueError,'clean tree'):m.header(REPO)
            self.assertEqual(m.header(REPO,False),('abc',2,'HEAD abc\nWORKTREE_DIRTY 2\n'))


if __name__=='__main__':unittest.main()
