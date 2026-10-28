#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic identities only; no disk/device APIs or external executables."""
from dataclasses import replace
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'minios'))
import host_dism_guard_model as model
import host_dism_capacity as capacity
import host_dism_tree_guard as tree


class Tests(unittest.TestCase):
    def setUp(self):
        self.image = model.ImageIdentity(r'K:\pool\fresh.vhdx', 41, b'file-id', 1, False, False)
        self.disk = model.DiskIdentity(self.image.canonical_path, True, r'\\.\PHYSICALDRIVE42',
                                       42, r'\\?\scsi#image-unique', 'File Backed Virtual',
                                       32*1024**3, 512, False, False, False)
        self.volume = model.VolumeIdentity('\\\\?\\Volume{example}\\', '\\\\?\\Volume{example}\\',
                                           'NTFS', (model.Extent(42, 1048576, 10*1024**3),))

    def check(self, image=None, disk=None, volume=None):
        model.assert_mutation(self.image, image or self.image, self.disk, disk or self.disk,
                              expected_volume=self.volume, observed_volume=volume or self.volume,
                              filesystem='NTFS')

    def test_matching_observations(self):
        self.check()

    def test_file_identity_ancestor_and_links(self):
        for bad in (replace(self.image, file_id=b'other'), replace(self.image, volume_serial=42),
                    replace(self.image, link_count=2), replace(self.image, reparse=True),
                    replace(self.image, ancestors_reparse=True),
                    replace(self.image, canonical_path=r'K:\pool\other.vhdx')):
            with self.subTest(bad=bad), self.assertRaises(ValueError): self.check(image=bad)

    def test_disk_is_virtual_and_revalidated(self):
        for bad in (replace(self.disk, attached=False), replace(self.disk, bus_type='NVMe'),
                    replace(self.disk, is_boot=True), replace(self.disk, is_system=True),
                    replace(self.disk, is_read_only=True), replace(self.disk, disk_number=1),
                    replace(self.disk, stable_path=r'\\?\scsi#other'),
                    replace(self.disk, bytes=64*1024**3), replace(self.disk, sector_bytes=4096),
                    replace(self.disk, device_path=r'\\.\PHYSICALDRIVE1')):
            with self.subTest(bad=bad), self.assertRaises(ValueError): self.check(disk=bad)

    def test_single_extent_and_alias_are_exact(self):
        for bad in (replace(self.volume, alias_target='\\\\?\\Volume{other}\\'),
                    replace(self.volume, filesystem='FAT32'),
                    replace(self.volume, extents=()),
                    replace(self.volume, extents=(model.Extent(1,1048576,1024),)),
                    replace(self.volume, extents=(self.volume.extents[0], self.volume.extents[0]))):
            with self.subTest(bad=bad), self.assertRaises(ValueError): self.check(volume=bad)

    def test_extents_must_fit_even_if_pinned_plan_is_bad(self):
        for extent in (model.Extent(42,0,512), model.Extent(42,1048576,32*1024**3),
                       model.Extent(42,1048577,512), model.Extent(42,1048576,0)):
            vol=replace(self.volume,extents=(extent,))
            with self.subTest(extent=extent), self.assertRaises(ValueError):
                model.assert_mutation(self.image,self.image,self.disk,self.disk,
                                      expected_volume=vol,observed_volume=vol,filesystem='NTFS')

    def test_normal_capacity_checks_both_limits(self):
        gib=1024**3
        model.assert_capacity(102*gib,148*gib,2*gib)
        for values in ((102*gib-1,148*gib,2*gib),(102*gib,148*gib+1,2*gib),
                       (True,0,0),(200*gib,-1,0),(200*gib,0,-1)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                model.assert_capacity(*values)

    def test_phase_budget_charges_only_unallocated_remainder(self):
        gib=1024**3
        reservation=capacity.IMAGE_BOUND+capacity.AUXILIARY_BOUND
        self.assertEqual(capacity.budget(0,0,0,0,100*gib+reservation,reservation),reservation)
        self.assertEqual(capacity.budget(32*gib,32*gib,gib,gib,103*gib,reservation),3*gib)
        for values in ((0,0,0,0,100*gib+reservation-1),(34*gib,0,0,0,200*gib),
                       (32*gib,32*gib,4*gib,gib,200*gib),
                       (32*gib,32*gib,gib,gib,103*gib-1)):
            with self.subTest(values=values), self.assertRaises(ValueError):capacity.budget(*values,reservation)

    def test_scratch_name_absent_from_pinned_tree(self):
        name='USOS-TEMP-'+'A'*32
        self.assertEqual(tree.assert_absent([{'path':''},{'path':'Windows/System32'}],name),2)
        for path in (name,name.lower()+'/file','../outside',r'Windows\bad'):
            with self.subTest(path=path), self.assertRaises(ValueError):tree.assert_absent([{'path':path}],name)


if __name__ == '__main__': unittest.main()
