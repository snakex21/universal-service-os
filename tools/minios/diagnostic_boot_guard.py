#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only identity/budget guard for the one DISM boot diagnostic.

No host disk, guest image or output is opened here. The caller must pin the
closed VHDX and use bounded QCOW containers before any future writes.
"""
import struct
import uuid
import tag4_collector as collector

MIB=1024**2
BOOT_BOUND=384*MIB
FIRSTBOOT_BOUND=1408*MIB
AUX_BOUND=256*MIB
IMAGE_SHA='14df385f5d353064499608837e1b1d83fc6b170045eeca67a72ce09b112cd5fe'
DISK='d82f1b66-1271-4683-867c-55b5f7070868'
WINDOWS='87c4f69b-6413-4c94-9c91-ce38d027d22e'
ESP='f8f81433-5702-4694-acfb-ffe9586ad29f'
MSR='e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10'
ENTRIES=(('e3c9e316-0b5c-4db8-817d-f92df00215ae',MSR,34,32767,0),
         ('c12a7328-f81f-11d2-ba4b-00a0c93ec93b',ESP,32768,565247,1<<63),
         ('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7',WINDOWS,565248,67106815,1<<63))

def check_budget(boot,first,aux):
    if (type(boot) is not int or type(first) is not int or type(aux) is not int or
        (boot,first,aux)!=(BOOT_BOUND,FIRSTBOOT_BOUND,AUX_BOUND) or boot+first+aux!=2*1024**3):
        raise ValueError('Disjoint diagnostic limits must total 2 GiB')

def validate(reader,image_sha):
    if image_sha!=IMAGE_SHA or reader.size!=32*1024**3:raise ValueError('Diagnostic image identity differs')
    selected=collector.gpt_partition(reader,WINDOWS,allow_windows_mbr_sentinel=True)
    if selected['disk_guid']!=DISK or selected['start']!=289406976 or selected['bytes']!=34069282816:
        raise ValueError('Diagnostic Windows partition identity differs')
    h=collector.read_at(reader,512,512)
    table_lba,count,width=struct.unpack_from('<QII',h,72)
    if (table_lba,count,width)!=(2,128,128):raise ValueError('Diagnostic GPT array geometry differs')
    table=collector.read_at(reader,table_lba*512,count*width)
    for index,expected in enumerate(ENTRIES):
        entry=table[index*width:(index+1)*width]
        actual=(str(uuid.UUID(bytes_le=entry[:16])),str(uuid.UUID(bytes_le=entry[16:32])),*struct.unpack_from('<QQQ',entry,32))
        if actual!=expected:raise ValueError('Diagnostic partition table differs')
    if any(table[3*width:]):raise ValueError('Unexpected diagnostic GPT entry')
    boot=collector.read_at(reader,selected['start'],512)
    if boot[3:11]!=b'NTFS    ' or struct.unpack_from('<H',boot,11)[0]!=512 or struct.unpack_from('<Q',boot,72)[0]!=0xe46231e86231c05a:
        raise ValueError('Diagnostic NTFS boot identity differs')
    check_budget(BOOT_BOUND,FIRSTBOOT_BOUND,AUX_BOUND)
    return {'disk_guid':DISK,'esp_guid':ESP,'windows_guid':WINDOWS,'msr_guid':MSR,
            'esp_offset':32768*512,'esp_bytes':(565248-32768)*512,
            'windows_offset':selected['start'],'windows_bytes':selected['bytes'],
            'boot_bound':BOOT_BOUND,'firstboot_bound':FIRSTBOOT_BOUND,'aux_bound':AUX_BOUND}
