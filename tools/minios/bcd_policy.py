#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit user-authorized 1c6 reference deferral, never a fake bcdboot PASS.

Native filesystem/layout gates and independent REGF route checks remain
mandatory. Only the external comparison is deferred to the actual boot gate.
"""
import argparse
import json
from pathlib import Path
import re

import bcd_compare
import bcdboot_reference as reference
import logged_run
import wim_oracle as oracle
import wim_pool as pool

SCHEMA='minios-bcd-reference-deferred-1c6-v1'
AUTHORIZATION='User 2026-10-26 MiniOS1c6: skip costly external BCD comparison; first Windows boot is the gate.'


def deferred(record):
    return record.get('schema')==SCHEMA


def validate(ref, own, native_sha, ours_sha, mode):
    if (not deferred(ref) or ref.get('authorization')!=AUTHORIZATION
        or ref.get('external_comparison_skipped') is not True or ref.get('bcdboot_passed') is not False
        or ref.get('head')!=own.get('head') or ref.get('dirty')!=0 or own.get('dirty')!=0
        or not re.fullmatch('[0-9a-f]{40}',ref.get('head',''))
        or own.get('schema')!='minios-bcd-independent-route-v1' or own.get('status')!='OFFLINE_ROUTE_PASS'
        or own.get('external_comparison_passed') is not False or own.get('reference_route') is not None
        or ref.get('native_receipt_sha256')!=native_sha or own.get('native_receipt_sha256')!=native_sha
        or ref.get('ours_sha256')!=ours_sha or own.get('source_sha256')!=ours_sha
        or ref.get('mode')!=mode or own.get('mode')!=mode
        or ref.get('route_receipt_sha256')!=own.get('_actual_sha256')):
        raise ValueError('Explicit reference deferral plus genuine independent own-BCD route required')


def validate_files(ref, own, native_sha, ours_sha, mode, own_path):
    # The caller already locks these bounded receipts; bind to actual bytes.
    own=dict(own);own['_actual_sha256']=oracle.digest(own_path)
    validate(ref,own,native_sha,ours_sha,mode)


def run(args):
    head,dirty=logged_run.tree(reference.REPO)
    if dirty:raise ValueError('Clean frozen reference-policy tree required')
    out=oracle.owned(args.out)
    if out.exists() or not out.is_relative_to(oracle.RUNTIME/'1c23/hive-bcd'):
        raise ValueError('Fresh reserved independent-route scope required')
    native_sha=oracle.digest(args.native_receipt)
    proof,layout,_=reference.accepted(args.native_receipt,native_sha)
    ours=oracle.owned(args.ours)
    source_sha=oracle.digest(ours)
    route=bcd_compare.route(bcd_compare.oracle.independent_read(ours))
    from windows_firstboot_case import route_layout
    route_layout(route,layout)
    pool.enforce_incremental(args.plan,out,1024**2,closed_scope=True)
    out.mkdir(parents=True)
    own=dict(schema='minios-bcd-independent-route-v1',head=head,dirty=0,status='OFFLINE_ROUTE_PASS',
        native_receipt_sha256=native_sha,source_sha256=source_sha,mode=proof['mode'],ours_route=route,
        reference_route=None,external_comparison_passed=False,independent_parser='python-registry',
        physical_disks_opened=False,host_registry_modified=False)
    oracle.save(out/'route.json',own)
    ref=dict(schema=SCHEMA,head=head,dirty=0,authorization=AUTHORIZATION,mode=proof['mode'],
        external_comparison_skipped=True,bcdboot_passed=False,ours_sha256=source_sha,
        native_receipt_sha256=native_sha,route_receipt_sha256=oracle.digest(out/'route.json'),
        firstboot_required=True,physical_disks_opened=False,host_registry_modified=False)
    oracle.save(out/'policy.json',ref)
    validate_files(ref,own,native_sha,source_sha,proof['mode'],out/'route.json')
    if logged_run.tree(reference.REPO)!=(head,0):raise ValueError('Tree changed')
    return ref


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('native-receipt','ours','out','plan'):p.add_argument('--'+name,type=Path,required=True)
    print(json.dumps(run(p.parse_args())))
