"""Wait on an owned completion-file event without periodic status checks."""
from pathlib import Path
import importlib.util
import os
import tempfile
import threading
import time
import unittest

spec=importlib.util.spec_from_file_location('plan',Path(__file__).with_name('run_plan.py'))
plan=importlib.util.module_from_spec(spec);spec.loader.exec_module(plan)


@unittest.skipUnless(os.name=='nt','Windows completion notification API')
class CompletionTests(unittest.TestCase):
    def test_already_complete_and_future_creation(self):
        scratch=plan.ROOT/'artifacts/coverage/vm/event-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            directory=Path(temporary)
            def complete():
                (directory/'unrelated.log').write_text('unrelated event')
                time.sleep(.1)
                (directory/'cleanup.json').write_text('{}')
            worker=threading.Thread(target=complete)
            worker.start()
            plan.after_cleanup(directory)
            worker.join()
            self.assertTrue((directory/'cleanup.json').is_file())
            plan.after_cleanup(directory)

    def test_future_case_directory(self):
        scratch=plan.ROOT/'artifacts/coverage/vm/event-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            directory=Path(temporary)/'future-case'
            def complete():
                time.sleep(.1)
                directory.mkdir()
                (directory/'unrelated.log').write_text('not completion')
                time.sleep(.1)
                (directory/'cleanup.json').write_text('{}')
            worker=threading.Thread(target=complete)
            worker.start()
            plan.after_cleanup(directory)
            worker.join()
            self.assertTrue((directory/'cleanup.json').is_file())

    def test_failure_completion_alternative(self):
        scratch=plan.ROOT/'artifacts/coverage/vm/event-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            directory=Path(temporary)
            def complete():
                time.sleep(.1)
                (directory/'cleanup.json').write_text('{}')
            worker=threading.Thread(target=complete)
            worker.start()
            ready=plan.after_file(directory/'endpoint.png',('cleanup.json',))
            worker.join()
            self.assertEqual(ready,directory/'cleanup.json')


if __name__=='__main__':unittest.main()
