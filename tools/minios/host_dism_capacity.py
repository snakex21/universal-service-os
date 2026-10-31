#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Normal-limit host-DISM capacity check; no device/image mutations or polling."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import stat
import re
import wim_pool as pool
import host_dism_vhdx_verify as vhdx

GIB=1024**3
MIN_FREE_BYTES=100*GIB
POOL_CAP_BYTES=150*GIB
IMAGE_BOUND=33*GIB
AUXILIARY_BOUND=3*GIB


def budget(image_logical,image_allocated,logical,allocated,free,reservation,growth_bytes=0):
    values=(image_logical,image_allocated,logical,allocated,free,reservation,growth_bytes)
    if any(type(x) is not int or x<0 for x in values) or not 0<reservation<=POOL_CAP_BYTES:
        raise ValueError('Invalid capacity measurement or normal reservation')
    if image_logical>IMAGE_BOUND or image_allocated>IMAGE_BOUND or logical>AUXILIARY_BOUND or allocated>AUXILIARY_BOUND:
        raise ValueError('Bounded case budget exceeded')
    if max(image_logical+logical,image_allocated+allocated)+growth_bytes>reservation:
        raise ValueError('Existing case exceeds its explicit reservation')
    remaining=reservation-image_allocated-allocated
    if free<MIN_FREE_BYTES+remaining:
        raise ValueError('Normal free-space reserve would be exceeded')
    return remaining


def verify_runtime_volume(root):
    expected=os.environ.get('USOS_MINIOS_VOLUME_GUID','')
    if not re.fullmatch(r'\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\',expected):raise ValueError('Explicit runtime volume identity required')
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    fn=kernel.GetVolumeNameForVolumeMountPointW
    fn.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint32];fn.restype=ctypes.c_int
    result=ctypes.create_unicode_buffer(64)
    if not fn(str(root.anchor),result,len(result)) or result.value.lower()!=expected.lower():
        raise ValueError('Runtime volume identity differs')


def charge_existing(case,image):
    """Return logical and allocated bytes of the reserved case, without links."""
    logical=allocated=0;count=0
    if not case.exists():return logical,allocated
    pending=[case]
    while pending:
        folder=pending.pop()
        with os.scandir(folder) as entries:
            for entry in entries:
                path=Path(entry.path);info=path.lstat()
                if entry.is_symlink() or getattr(info,'st_file_attributes',0)&0x400:
                    raise ValueError('Reparse point in host DISM reserved case')
                if stat.S_ISDIR(info.st_mode):pending.append(path);continue
                if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:raise ValueError('Non-ordinary case file')
                if path==image:continue
                count+=1
                if count>100000:raise ValueError('Host DISM case file limit exceeded')
                logical+=info.st_size;allocated+=vhdx.real_allocation(path)
    return logical,allocated


def preflight(root,plan_path,plan_sha,case,*,image_exists,growth_bytes=0):
    if os.name!='nt':raise ValueError('Windows host required')
    oracle=pool.oracle;oracle.local(root);oracle.owned(plan_path);oracle.owned(case)
    if root!=oracle.RUNTIME or case.parent!=root/'1c7' or not case.name.startswith('host-dism-'):
        raise ValueError('Explicit host-DISM case directly under 1c7 required')
    if not case.name[10:] or any(c not in '0123456789abcdef-' for c in case.name[10:]):
        raise ValueError('Invalid case identifier')
    verify_runtime_volume(root)
    if not re.fullmatch('[0-9a-f]{64}',plan_sha):raise ValueError('Exact capacity plan SHA required')
    with oracle.readonly(plan_path) as f:
        if oracle.digest_stream(f)!=plan_sha:raise ValueError('Capacity plan SHA differs')
        f.seek(0);plan=json.load(f)
    if plan.get('schema')!='usos-wim-pool-plan-v1' or plan.get('unreserved_files_declared_closed') is not True:
        raise ValueError('Frozen normal capacity plan required')
    limit=pool.plan_limit(plan)
    if limit>POOL_CAP_BYTES:raise ValueError('Normal pool cap exceeded')
    relative=case.relative_to(root).as_posix()
    exact=[row for row in plan['reservations'] if row.get('path')==relative]
    if len(exact)!=1:raise ValueError('Explicit whole-case reservation in the normal plan required')
    report=pool.audit(root,plan['reservations'],limit=limit)
    if not report['passed']:raise ValueError('Normal pool limit exceeded')
    image=case/'install.vhdx'
    if image.exists()!=image_exists:raise ValueError('Expected image state differs')
    if image_exists:
        info=image.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or getattr(info,'st_file_attributes',0)&(0x200|0x400|0x800|0x4000):
            raise ValueError('Image must be ordinary non-sparse and single-link')
        image_logical=info.st_size;image_allocated=vhdx.real_allocation(image)
    else:image_logical=image_allocated=0
    logical,allocated=charge_existing(case,image)
    free=shutil.disk_usage(root.anchor).free
    remaining=budget(image_logical,image_allocated,logical,allocated,free,exact[0]['bytes'],growth_bytes)
    return {'free_bytes':free,'minimum_free_bytes':MIN_FREE_BYTES,'remaining_reserved_bytes':remaining,
            'pool_projected_bytes':report['projected_total_bytes'],'pool_cap_bytes':limit,
            'image_logical_bytes':image_logical,'image_allocated_bytes':image_allocated,
            'other_logical_bytes':logical,'other_allocated_bytes':allocated,'requested_growth_bytes':growth_bytes,
            'note':'normal phase preflight, not a continuous VHDMP growth guarantee'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('root','plan','case'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--plan-sha256',required=True)
    parser.add_argument('--image-exists',choices=('yes','no'),required=True)
    args=parser.parse_args()
    print(json.dumps(preflight(args.root,args.plan,args.plan_sha256,args.case,
                               image_exists=args.image_exists=='yes'),sort_keys=True))


if __name__=='__main__':main()
