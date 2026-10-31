#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read the one authorized host-DISM image within its scoped capacity budget."""
import argparse
import json
import re
from pathlib import Path
import host_dism_capacity as cap
import tag4_collector as collector
import tag4_diff as diff

GIB=1024**3
CASE='host-dism-538d709d-91fb-4e74-a43b-8a123e253760'
RESUME='resume-7489b026-f807-4100-a120-06d1c2c2d836'
IMAGE_SHA='14df385f5d353064499608837e1b1d83fc6b170045eeca67a72ce09b112cd5fe'
GUID='87c4f69b-6413-4c94-9c91-ce38d027d22e'

def check_budget(report):
    # At most 384 MiB metadata + 32 MiB map + overhead; keep room for
    # the subsequent comparison as well as the separately reserved overlay.
    if max(report['other_logical_bytes'],report['other_allocated_bytes']) > GIB-640*1024**2:
        raise ValueError('Insufficient scoped evidence budget')

def check_image_plan(p,case):
    if (p.get('virtual_bytes')!=32*GIB or p.get('chain')!=[{'path':str(case/'install.vhdx'),'sha256':IMAGE_SHA}]
        or p.get('partition_guid')!=GUID or p.get('partition_offset')!=289406976 or p.get('partition_bytes')!=34069282816):
        raise ValueError('Scoped DISM image or partition differs')

def run(plan,plan_sha,qemu,qemu_sha,out,volume,capacity_plan,capacity_sha):
    root=collector.oracle.RUNTIME;case=root/'1c7'/CASE
    if out.parent != case/RESUME or not re.fullmatch('tag4-dism-capture[0-9]{2}',out.name) or plan.parent!=root/'1c7':
        raise ValueError('Exact scoped capture paths required')
    if not diff.SHA.fullmatch(plan_sha):raise ValueError('Capture plan SHA required')
    with diff.locked(diff.checked_path(root,str(plan))) as f:
        if diff.digest(f)!=plan_sha:raise ValueError('Capture plan differs')
        f.seek(0);p=json.load(f)
    check_image_plan(p,case)
    def scoped_guard(requested):
        if requested!=GIB:raise ValueError('Unexpected collector budget')
        report=cap.preflight(root,capacity_plan,capacity_sha,case,image_exists=True,growth_bytes=requested)
        check_budget(report)
    collector.oracle.storage_guard=scoped_guard
    collector.MAX_EVIDENCE=384*1024**2
    return collector.capture_plan(plan,plan_sha,qemu,qemu_sha,out,volume,allow_windows_mbr_sentinel=True)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for n in ('plan','plan-sha256','qemu-img','qemu-sha256','out','volume-guid','capacity-plan','capacity-sha256'):
        p.add_argument('--'+n,required=True)
    a=p.parse_args()
    print(json.dumps(run(Path(a.plan),a.plan_sha256,Path(a.qemu_img),a.qemu_sha256,Path(a.out),a.volume_guid,Path(a.capacity_plan),a.capacity_sha256),indent=2))
if __name__=='__main__':main()
