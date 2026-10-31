#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Combine closed QCOW2/QCOW2/VHDX mappings; no images are opened here."""
def materialize(rows,base,virtual):
    if not isinstance(rows,list) or not rows or len(rows)>131072 or not isinstance(base,list) or not base:
        raise ValueError('Bounded QEMU map and validated BAT required')
    result=[];cursor=0;step=base[0]['length']
    for row in rows:
        if not isinstance(row,dict):raise ValueError('Invalid map row')
        start,n,depth=row.get('start'),row.get('length'),row.get('depth')
        if (type(start) is not int or type(n) is not int or type(depth) is not int or start!=cursor or
            not 0<n<=virtual-start or depth not in (0,1,2) or type(row.get('zero')) is not bool or
            type(row.get('data')) is not bool or row.get('compressed',False) is not False):
            raise ValueError('Invalid map geometry or flags')
        if row['zero'] or not row['data']:
            if not row['zero']:raise ValueError('Unmapped nonzero region')
            result.append({'start':start,'length':n,'depth':depth,'zero':True,'data':False});cursor+=n;continue
        end=start+n;at=start
        while at<end:
            if depth==2:
                index=at//step
                if not 0<=index<len(base):raise ValueError('BAT entry missing')
                entry=base[index]
                if entry['start']>at or at>=entry['start']+entry['length'] or not entry['data'] or entry['zero']:
                    raise ValueError('Validated BAT geometry differs')
                take=min(end-at,entry['start']+entry['length']-at);off=entry['offset']+at-entry['start']
                if 'offset' in row and row['offset']+(at-start)!=off:raise ValueError('QEMU/BAT offset mismatch')
            else:
                if type(row.get('offset')) is not int or row['offset']<0:raise ValueError('QCOW physical offset missing')
                take=end-at;off=row['offset']+at-start
            result.append({'start':at,'length':take,'depth':depth,'zero':False,'data':True,'offset':off})
            if len(result)>262144:raise ValueError('Expanded map too large')
            at+=take
        cursor=end
    if cursor!=virtual:raise ValueError('Map incomplete')
    return result
