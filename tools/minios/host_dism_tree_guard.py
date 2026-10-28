#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Require a pinned WIM oracle tree to exclude the temporary root directory."""
import argparse
import json
from pathlib import Path
import re
import wim_oracle as oracle


def assert_absent(rows,name):
    if not re.fullmatch(r'USOS-TEMP-[0-9A-F]{32}',name):raise ValueError('Unique scratch directory name required')
    folded=name.casefold();count=0
    for row in rows:
        path=row.get('path')
        if not isinstance(path,str) or '\\' in path or '\0' in path or path.startswith('/') or any(p in ('.','..') for p in path.split('/')):
            raise ValueError('Invalid WIM tree path')
        if path and path.split('/')[0].casefold()==folded:raise ValueError('Scratch root collides with WIM tree')
        count+=1
        if count>1_000_000:raise ValueError('WIM tree entry bound exceeded')
    if not count:raise ValueError('Empty WIM tree')
    return count


def check(receipt,receipt_sha,tree,tree_sha,name):
    for value in (receipt_sha,tree_sha):
        if not re.fullmatch('[0-9a-f]{64}',value):raise ValueError('Exact SHA required')
    oracle.owned(receipt);oracle.owned(tree)
    with oracle.readonly(receipt) as rf,oracle.readonly(tree) as tf:
        if oracle.digest_stream(rf)!=receipt_sha or oracle.digest_stream(tf)!=tree_sha:raise ValueError('WIM oracle pin differs')
        rf.seek(0);manifest=json.load(rf)
        if (manifest.get('schema')!='usos-wim-oracle-manifest-v1' or manifest.get('wim_sha256')!='de1f5d0d14b9337cb32790d718a84bcfbc94425660b224c705833da5d9e88a51' or
            manifest.get('index')!=2 or manifest.get('tree_sha256')!=tree_sha):raise ValueError('Wrong WIM oracle binding')
        tf.seek(0)
        return assert_absent((json.loads(line) for line in tf),name)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--receipt',type=Path,required=True);p.add_argument('--receipt-sha256',required=True)
    p.add_argument('--tree',type=Path,required=True);p.add_argument('--tree-sha256',required=True);p.add_argument('--name',required=True)
    a=p.parse_args();print(json.dumps({'tree_entries':check(a.receipt,a.receipt_sha256,a.tree,a.tree_sha256,a.name),'scratch_root':a.name}))


if __name__=='__main__':main()
