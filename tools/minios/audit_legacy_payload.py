#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare tracked SYS/CER blobs to an explicitly pinned integration tree.

Read-only Git operations; no checkout, fetch, merge, payload copies or trust
store operations. Report paths are repository-relative and contain no host
usernames, build paths or machine-specific repository locations.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, check=True).stdout


def tree(repo, ref):
    commit = git(repo, 'rev-parse', '--verify', ref + '^{commit}').decode().strip()
    result = {}
    for row in git(repo, 'ls-tree', '-r', '-z', commit).split(b'\0'):
        if not row:
            continue
        meta, path = row.split(b'\t', 1)
        mode, kind, blob = meta.decode().split()
        name = path.decode('utf-8')
        if name.lower().endswith(('.sys', '.cer')) and kind == 'blob':
            result[name] = dict(blob=blob, mode=mode)
    return commit, result


def audit(repo, ref, master_repo, master_ref):
    branch, ours = tree(repo, ref)
    target, theirs = tree(master_repo, master_ref)
    rows = []
    for path, entry in sorted(ours.items()):
        data = git(repo, 'cat-file', 'blob', entry['blob'])
        other = theirs.get(path)
        rows.append(dict(path=path, blob=entry['blob'], bytes=len(data),
                         sha256=hashlib.sha256(data).hexdigest(), present_in_master=other is not None,
                         same_master_blob=other is not None and other['blob'] == entry['blob'],
                         inherited_media_payload=path.startswith('media/Systems/Windows/')))
    return dict(schema='minios-integration-payload-audit-v2', branch_commit=branch,
                master_commit=target, branch_count=len(ours), master_count=len(theirs),
                branch_only=sum(not x['present_in_master'] for x in rows),
                inherited_media_absent_from_master=sum(x['inherited_media_payload'] and not x['present_in_master'] for x in rows),
                rows=rows, payload_copies_created=False, git_mutated=False)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', type=Path, required=True)
    p.add_argument('--ref', default='HEAD')
    p.add_argument('--master-repo', type=Path, required=True)
    p.add_argument('--master-ref', required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    result = audit(a.repo, a.ref, a.master_repo, a.master_ref)
    with a.out.open('x', encoding='utf-8') as out:
        json.dump(result, out, indent=2); out.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}))


if __name__ == '__main__':
    main()
