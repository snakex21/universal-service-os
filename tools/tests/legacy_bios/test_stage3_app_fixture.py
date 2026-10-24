# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reject application plans that escape the guest or external app library."""
import json
from pathlib import Path
import tempfile
import unittest

import run_win16_stage3_app as app


class AppPlanTests(unittest.TestCase):
    def plan(self, value):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name)/'plan.json'; path.write_text(json.dumps(value))
        return path

    def test_guest_paths(self):
        self.assertEqual(app.guest_path('NET/WIN16/OPERA/OPERA.EXE'), 'NET/WIN16/OPERA/OPERA.EXE')
        self.assertEqual(app.guest_path('WINDOWS/OLE2.DLL'), 'WINDOWS/OLE2.DLL')
        for value in ('NET/WIN16/../../AUTOEXEC.BAT', 'WINDOWS/../CONFIG.SYS',
                      '/NET/WIN16/A.EXE', 'NET\\WIN16\\A.EXE', 'AUTOEXEC.BAT',
                      'NET/WIN16/a\ncommand', 'NET/WIN16/a;command', 'NET/WIN16//A.EXE'):
            with self.subTest(value=value), self.assertRaises(ValueError): app.guest_path(value)

    def test_launch_commands(self):
        for command in ('C:\\WINDOWS\\REGEDIT.EXE', 'C:\\NET\\WIN16\\A.EXE\r\nFORMAT C:', 'x'*231):
            with self.subTest(command=command), self.assertRaises(ValueError):
                app.load_plan(self.plan({'command1':command}))
        command='C:\\NET\\WIN16\\MOSAIC.EXE http://www.68k.news/'
        commands,_,data,_=app.load_plan(self.plan({'command1':command,'text':{'NET/WIN16/A.INI':'one\ntwo\n'}}))
        self.assertEqual(commands,[command,''])
        self.assertEqual(data['NET/WIN16/A.INI'],b'one\r\ntwo\r\n')

    def test_external_application_library(self):
        own=self.plan({'not':'an app'})
        with self.assertRaises(ValueError):
            app.load_plan(self.plan({'command1':'C:\\NET\\WIN16\\A.EXE',
                'files':[{'source':str(own),'target':'NET/WIN16/A.EXE'}]}))

    def test_dialog_actions_are_finite_and_single_line(self):
        plan={'command1':'C:\\NET\\WIN16\\A.EXE'}
        for actions in ([{'dialog':'License','button':'Accept'}]*4,
                        [{'dialog':'License\ncommand1=bad','button':'Accept'}],
                        [{'dialog':'License','button':''}]):
            with self.subTest(actions=actions), self.assertRaises(ValueError):
                app.load_plan(self.plan({**plan,'actions':actions}))


if __name__=='__main__': unittest.main()
