# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Safety contracts for the separate stage3 VM fixture; no QEMU launched."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1]/'legacy_bios/run_win16_stage3_qemu.py'
spec = importlib.util.spec_from_file_location('stage3_fixture',path)
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)


class FixtureSafety(unittest.TestCase):
    def test_only_new_stage3_named_output(self):
        for value in (Path('C:/target.qcow2'),fixture.RUNTIME,Path(r'K:\USOS-VM\winsock-etap2-20261024\vm')):
            with self.assertRaises(ValueError): fixture.guarded(value)
        self.assertEqual(fixture.guarded(fixture.RUNTIME/'vm/win31'),fixture.RUNTIME/'vm/win31')

    def test_qemu_path_delimiters_are_rejected(self):
        for value in ('comma,bad','line\nbad','line\rbad','nul\x00bad'):
            with self.assertRaises(ValueError): fixture.guarded(fixture.RUNTIME/value)

    def test_reparse_component_is_rejected(self):
        with patch.object(Path,'stat',return_value=SimpleNamespace(st_file_attributes=0x400)):
            with self.assertRaises(ValueError): fixture.guarded(fixture.RUNTIME/'vm/win31')

    def test_overlay_tag_cannot_inject_shell_or_path(self):
        with patch.object(fixture.flow.ws,'command') as launch:
            for tag in ('../base','x/y','x\\y','x y','x;bad',''):
                with self.assertRaises(ValueError):
                    fixture.make_overlay(fixture.RUNTIME/'vm/win31',fixture.RUNTIME/'vm/win31/base.qcow2',tag,Path('qemu.exe'))
            launch.assert_not_called()

    def test_base_is_required_before_overlay(self):
        with patch.object(fixture.flow.ws,'command') as launch, patch.object(Path,'is_file',return_value=False):
            with self.assertRaises(ValueError):
                fixture.make_overlay(fixture.RUNTIME/'vm/win31',fixture.RUNTIME/'vm/win31/base.qcow2','app-01',Path('qemu.exe'))
            launch.assert_not_called()

    def test_real_catalog_identifiers(self):
        self.assertEqual(fixture.SYSTEMS,{'win31':'windows-3-1','wfw311':'windows-wfw-3-11'})

    def test_free_space_reserve_is_required(self):
        with patch.object(fixture.shutil,'disk_usage',return_value=SimpleNamespace(free=fixture.FREE_RESERVE)), patch.object(Path,'rglob',return_value=[]):
            with self.assertRaises(ValueError): fixture.storage_budget(1)
            self.assertEqual(fixture.storage_budget(0)['free_reserve_bytes'],fixture.FREE_RESERVE)

    def test_generated_image_cap_is_required(self):
        item=SimpleNamespace(suffix='.qcow2',is_file=lambda:True,stat=lambda:SimpleNamespace(st_size=fixture.IMAGE_LIMIT))
        with patch.object(fixture.shutil,'disk_usage',return_value=SimpleNamespace(free=1024**4)), patch.object(Path,'rglob',return_value=[item]):
            with self.assertRaises(ValueError): fixture.storage_budget(1)


if __name__=='__main__': unittest.main()
