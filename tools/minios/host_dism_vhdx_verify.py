#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspect fixed VHDX allocation before host-DISM, without mounting or writing.

BAT indexing follows the local doors/LiberNT-main-nt10/modules/rosv/include/
rosv/vhdx.h and modules/rosv/device/vhdx_parser.c. A fully allocated input is
evidence about its initial layout, not a guarantee of later VHDMP behavior.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import struct
import uuid
import tag4_collector as vhdx
import tag4_diff as diff

MIB=1024*1024
_SECTOR=uuid.UUID('8141bf1d-a96f-4709-ba47-f233a8faab5f').bytes_le


def check_layout(file, virtual_bytes, allocated_bytes, cap_bytes, *, include_map=False):
    """Read only; caller separately verifies file identity and actual allocation."""
    identity=vhdx.validate_vhdx(file,virtual_bytes)
    file.seek(0,2);length=file.tell()
    if (type(allocated_bytes) is not int or type(cap_bytes) is not int or
        allocated_bytes<length or length>cap_bytes or allocated_bytes>cap_bytes or not identity['fixed_flag']):
        raise ValueError('VHDX is not fully allocated fixed or exceeds budget')
    def read_at(off,n):
        if off<0 or n<0 or off>length or n>length-off:raise ValueError('VHDX extent outside file')
        file.seek(off);data=file.read(n)
        if len(data)!=n:raise ValueError('Short VHDX read')
        return data
    logs=[]
    for hoff in (65536,131072):
        head=read_at(hoff,4096);loglen,logoff=struct.unpack_from('<IQ',head,68)
        logs.append((logoff,logoff+loglen))
    table=read_at(196608,65536);count=struct.unpack_from('<I',table,8)[0]
    regions={}
    for i in range(count):
        pos=16+i*32;guid=table[pos:pos+16];off,n,_=struct.unpack_from('<QII',table,pos+16)
        regions[guid]=(off,n)
    metaoff,_=regions[vhdx._VHDX_META];metatable=read_at(metaoff,65536)
    entries=struct.unpack_from('<H',metatable,10)[0];logical=None
    for i in range(entries):
        pos=32+i*32
        if metatable[pos:pos+16]==_SECTOR:
            itemoff,n=struct.unpack_from('<II',metatable,pos+16)
            if n!=4:raise ValueError('Invalid VHDX logical sector metadata')
            logical=struct.unpack('<I',read_at(metaoff+itemoff,n))[0]
    if logical not in (512,4096):raise ValueError('Invalid VHDX logical sector size')
    block=identity['block_size'];blocks=(virtual_bytes+block-1)//block
    ratio=((1<<23)*logical)//block
    if not 1<=blocks<=131072 or ratio<1:raise ValueError('VHDX BAT geometry exceeds supported bound')
    bat_count=blocks+(blocks-1)//ratio
    batoff,batlen=regions[vhdx._VHDX_BAT]
    if bat_count*8>batlen:raise ValueError('VHDX BAT too short')
    bat=read_at(batoff,bat_count*8);protected=[(0,MIB),*logs]
    protected.extend((off,off+n) for off,n in regions.values())
    payload=[];mapping=[]
    for index in range(bat_count):
        value=struct.unpack_from('<Q',bat,index*8)[0]
        if index%(ratio+1)==ratio:
            if value:raise ValueError('Unexpected VHDX sector bitmap')
            continue
        offset=value&~((1<<20)-1)
        if value&((1<<20)-1)!=6 or offset%MIB or offset>length or block>length-offset:
            raise ValueError('VHDX payload block not fully present inside file')
        if any(offset<end and begin<offset+block for begin,end in protected):
            raise ValueError('VHDX payload overlaps metadata')
        start=len(payload)*block
        mapping.append({'start':start,'length':min(block,virtual_bytes-start),
                        'zero':False,'data':True,'depth':0,'offset':offset})
        payload.append((offset,offset+block))
    if len(payload)!=blocks:raise ValueError('VHDX payload count differs')
    payload.sort()
    if any(a[1]>b[0] for a,b in zip(payload,payload[1:])):raise ValueError('Overlapping VHDX payload blocks')
    result={'virtual_bytes':virtual_bytes,'file_bytes':length,'allocated_bytes':allocated_bytes,
            'payload_blocks':blocks,'block_bytes':block,'bat_entries':bat_count,
            'logical_sector_bytes':logical,'fixed':True,
            'future_vhdmp_growth_guaranteed':False}
    if include_map:result['map']=mapping
    return result


def check_qemu_map(rows,virtual,mapping):
    """Cross-check full allocation, without trusting optional physical offsets."""
    if not isinstance(rows,list) or not 1<=len(rows)<=131072:raise ValueError('Invalid VHDX qemu map')
    cursor=0
    for row in rows:
        if not isinstance(row,dict):raise ValueError('Invalid VHDX qemu map entry')
        start,n=row.get('start'),row.get('length')
        if (type(start) is not int or type(n) is not int or start!=cursor or not 0<n<=virtual-start or
            row.get('depth')!=0 or type(row.get('depth')) is not int or row.get('data') is not True or
            row.get('zero') is not False or row.get('compressed',False) is not False or
            row.get('present',True) is not True):raise ValueError('VHDX qemu map is not full standalone data')
        if 'offset' in row:
            off=row['offset']
            if type(off) is not int or off<0:raise ValueError('Invalid VHDX qemu offset')
            end=start+n;current=start
            while current<end:
                index=current//mapping[0]['length'];entry=mapping[index]
                within=current-entry['start']
                if off+(current-start)!=entry['offset']+within:raise ValueError('VHDX QEMU and BAT offsets differ')
                current=min(end,entry['start']+entry['length'])
        cursor+=n
    if cursor!=virtual:raise ValueError('Incomplete VHDX qemu map')


def real_allocation(path):
    if os.name!='nt':raise ValueError('Windows allocation API required')
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    fn=kernel.GetCompressedFileSizeW
    fn.argtypes=[ctypes.c_wchar_p,ctypes.POINTER(ctypes.c_uint32)]
    fn.restype=ctypes.c_uint32
    high=ctypes.c_uint32();ctypes.set_last_error(0)
    low=fn(str(path),ctypes.byref(high));error=ctypes.get_last_error()
    if low==0xffffffff and error:raise ctypes.WinError(error)
    return (high.value<<32)|low


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image',type=Path,required=True)
    parser.add_argument('--virtual',type=int,required=True)
    parser.add_argument('--cap',type=int,required=True)
    args=parser.parse_args()
    if not args.image.is_absolute() or args.image.suffix.lower()!='.vhdx':raise ValueError('Explicit absolute VHDX required')
    # The outer executor must also pin file ID and ancestry; this lock prevents
    # writes/deletes during this particular inspection, before attachment.
    with diff.locked(args.image) as file:
        result=check_layout(file,args.virtual,real_allocation(args.image),args.cap)
    print(json.dumps(result,sort_keys=True))


if __name__=='__main__':main()
