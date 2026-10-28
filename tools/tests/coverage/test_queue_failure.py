"""A failed fixture must still notify a dependent lane after cleanup."""
from pathlib import Path
import argparse
import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('plan',Path(__file__).with_name('run_plan.py'))
plan=importlib.util.module_from_spec(spec);spec.loader.exec_module(plan)


class QueueFailureTests(unittest.TestCase):
    def test_manifest_dependency_is_waited_before_cases(self):
        scratch=plan.ROOT/'artifacts/coverage/queue-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            root=Path(temporary);manifest=root/'empty-plan.json'
            manifest.write_text('[]')
            previous=root/'previous-case.json'
            args=argparse.Namespace(plan=manifest,after=None,after_file=previous)
            with patch.object(plan,'after_file') as wait:
                plan.run(args)
            wait.assert_called_once_with(previous)

    def test_prepare_failure_publishes_terminal_cleanup(self):
        scratch=plan.ROOT/'artifacts/coverage/queue-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            root=Path(temporary);source=root/'source.iso';source.write_bytes(b'')
            case=dict(tag='synthetic-failure',source=str(source),system='windows-7',folder='Windows 7')
            manifest=root/'plan.json';manifest.write_text(json.dumps([case]))
            args=argparse.Namespace(plan=manifest,after=None,nested=False,profile=root/'profile',
                assets=root/'assets',qemu=root/'qemu',seven=root/'7z',accel='tcg')
            with patch.object(plan,'ROOT',root),patch.object(plan,'COLLECTION',root),\
                 patch.object(plan.shutil,'disk_usage',return_value=argparse.Namespace(free=1024**4)),\
                 patch.object(plan.subprocess,'run',side_effect=subprocess.CalledProcessError(1,['synthetic'])),\
                 contextlib.redirect_stdout(io.StringIO()):
                plan.run(args)
            out=root/'artifacts/coverage/vm'/case['tag']
            self.assertTrue((out/'cleanup.json').is_file())
            self.assertEqual(json.loads((out/'result.json').read_text())['result'],'RUNNER_ERROR')


if __name__=='__main__':unittest.main()
