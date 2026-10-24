# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Local mIRC fixture boundaries; no client, server or QEMU is started."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('irc_fixture_test',Path(__file__).resolve().parents[1]/'legacy_bios/run_win16_irc_stage3.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)


class LocalFixture(unittest.TestCase):
    def plan(self):
        candidates=[fixture.LIBRARY/name for name in ('MIRC.EXE','MIRC.HLP','REGISTER.TXT','MIRC.INI','SERVERS.INI','other.exe')]
        with patch.object(Path,'iterdir',return_value=iter(candidates)),patch.object(Path,'is_file',return_value=True):
            return fixture.client_plan()

    def test_only_original_allowlisted_files_are_staged(self):
        plan=self.plan()
        self.assertEqual({Path(row['source']).name for row in plan['files']},{'MIRC.EXE','MIRC.HLP'})
        self.assertTrue(all(row['target'].startswith('NET/WIN16/MIRC/') for row in plan['files']))

    def test_one_local_ui_connection_and_real_client_join(self):
        text=self.plan()['text']
        self.assertIn('SERVER:172.31.8.2:16667',text['NET/WIN16/MIRC/SERVERS.INI'])
        remote=text['NET/WIN16/MIRC/REMOTE.INI']
        self.assertIn('on 1:CONNECT:',remote)
        self.assertIn('join #usos-test',remote)
        self.assertNotIn('START:',remote)
        self.assertNotIn('server ',remote.lower())


if __name__=='__main__':unittest.main()
