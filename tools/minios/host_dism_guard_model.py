#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure synthetic specification of host-DISM identity checks.

This is NOT a Windows device identity probe or a disk executor. It performs
no I/O and no mutation. Real observations require separately reviewed Win32
handles and Storage API calls immediately before every individual mutation.
"""
from dataclasses import dataclass
import ntpath


@dataclass(frozen=True)
class ImageIdentity:
    canonical_path: str
    volume_serial: int
    file_id: bytes
    link_count: int
    reparse: bool
    ancestors_reparse: bool


@dataclass(frozen=True)
class DiskIdentity:
    image_path: str
    attached: bool
    device_path: str
    disk_number: int
    stable_path: str
    bus_type: str
    bytes: int
    sector_bytes: int
    is_boot: bool
    is_system: bool
    is_read_only: bool


@dataclass(frozen=True)
class Extent:
    disk_number: int
    offset: int
    bytes: int


@dataclass(frozen=True)
class VolumeIdentity:
    volume_guid: str
    alias_target: str
    filesystem: str
    extents: tuple



def _same_path(a, b):
    return (isinstance(a, str) and isinstance(b, str) and
            ntpath.normcase(ntpath.normpath(a)) == ntpath.normcase(ntpath.normpath(b)))


def assert_image(expected, observed):
    if (not isinstance(expected, ImageIdentity) or not isinstance(observed, ImageIdentity)
            or not ntpath.isabs(expected.canonical_path)
            or expected.canonical_path.startswith('\\\\')
            or ntpath.splitext(expected.canonical_path)[1].lower() != '.vhdx'
            or not expected.file_id or expected.volume_serial <= 0
            or expected.link_count != 1 or expected.reparse or expected.ancestors_reparse
            or not _same_path(expected.canonical_path, observed.canonical_path)
            or observed.volume_serial != expected.volume_serial
            or observed.file_id != expected.file_id or observed.link_count != 1
            or observed.reparse or observed.ancestors_reparse):
        raise ValueError('Image identity or ordinary single-link path differs')


def assert_disk(expected, observed, image):
    if (not isinstance(expected, DiskIdentity) or not isinstance(observed, DiskIdentity)
            or not _same_path(expected.image_path, image.canonical_path)
            or not _same_path(observed.image_path, image.canonical_path)
            or not observed.attached or observed.disk_number != expected.disk_number
            or observed.disk_number < 0
            or observed.device_path.lower() != ('\\\\.\\physicaldrive' + str(observed.disk_number))
            or not expected.stable_path or not _same_path(observed.stable_path, expected.stable_path)
            or observed.bus_type.replace(' ', '').lower() != 'filebackedvirtual'
            or observed.bytes != expected.bytes or observed.bytes <= 0
            or observed.sector_bytes != 512 or observed.is_boot or observed.is_system
            or observed.is_read_only):
        raise ValueError('Attachment is not the pinned writable non-system virtual disk')


def assert_volume(expected, observed, disk, filesystem):
    if (not isinstance(expected, VolumeIdentity) or not isinstance(observed, VolumeIdentity)
            or not expected.volume_guid or not _same_path(expected.volume_guid, observed.volume_guid)
            or not _same_path(expected.volume_guid, observed.alias_target)
            or observed.filesystem.lower() != filesystem.lower()
            or observed.extents != expected.extents or len(observed.extents) != 1):
        raise ValueError('Volume alias or extent differs')
    extent = observed.extents[0]
    if (not isinstance(extent, Extent) or extent.disk_number != disk.disk_number
            or extent.offset < 1048576 or extent.offset % 1048576
            or extent.bytes <= 0 or extent.offset > disk.bytes
            or extent.bytes > disk.bytes - extent.offset):
        raise ValueError('Volume extent is not inside the pinned disk')


def assert_mutation(expected_image, observed_image, expected_disk, observed_disk,
                    *, expected_volume=None, observed_volume=None, filesystem=None):
    """Model one fresh observation; callers must never reuse an earlier result."""
    assert_image(expected_image, observed_image)
    assert_disk(expected_disk, observed_disk, observed_image)
    if filesystem is not None:
        assert_volume(expected_volume, observed_volume, observed_disk, filesystem)


def assert_capacity(free_bytes, existing_pool_charge, growth_bytes):
    """Ordinary policy, independently charged existing files plus new growth."""
    if (any(type(x) is not int or x<0 for x in (free_bytes,existing_pool_charge,growth_bytes))
            or free_bytes<100*1024**3+growth_bytes
            or existing_pool_charge>150*1024**3-growth_bytes):
        raise ValueError('Normal capacity is insufficient')
