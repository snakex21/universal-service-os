#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Completion wait, bounded CPU, portable cache, clean-tree evidence header."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess


def tree(repo):
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain=v1', '-uall'], cwd=repo, text=True).splitlines()
    return head, len(dirty)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--require-clean', action='store_true')
    parser.add_argument('--affinity-mask',type=int,default=3,help='At most two explicit logical CPUs; inherited by children')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.affinity_mask<=0 or args.affinity_mask.bit_count()>2 or args.affinity_mask >= 1 << (os.cpu_count() or 1):
        raise ValueError('Choose at most two existing logical CPUs')
    if args.command[:1] == ['--']:
        args.command.pop(0)
    if not args.command:
        raise ValueError('Command required')
    repo = args.repo.resolve(strict=True)
    head, dirty = tree(repo)
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open('x', encoding='utf-8', newline='\n') as log:
        log.write(f'HEAD {head}\nWORKTREE_DIRTY {dirty}\n')
        log.write(f'AFFINITY_MASK {args.affinity_mask}\n')
        log.write('COMMAND ' + json.dumps(args.command) + '\n')
        log.flush()
        if args.require_clean and dirty:
            raise ValueError('Final evidence requires a clean tree')
        runtime = repo / 'runtime' / 'logged-run' / args.log.stem
        runtime.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env.update(TEMP=str(runtime), TMP=str(runtime), APPDATA=str(runtime), LOCALAPPDATA=str(runtime),
                   ZIG_GLOBAL_CACHE_DIR=str(repo / 'runtime' / 'zig-global-cache'))
        if os.name == 'nt':
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.GetCurrentProcess.restype = ctypes.c_void_p
            kernel.SetProcessAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
            if not kernel.SetProcessAffinityMask(kernel.GetCurrentProcess(), args.affinity_mask):
                raise ctypes.WinError(ctypes.get_last_error())
            flags = subprocess.BELOW_NORMAL_PRIORITY_CLASS
        else:
            os.nice(5)
            if hasattr(os, 'sched_setaffinity'):
                os.sched_setaffinity(0, {i for i in range(args.affinity_mask.bit_length()) if args.affinity_mask & (1<<i)})
            flags = 0
        result = subprocess.run(args.command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT,
                                creationflags=flags)
        log.write(f'EXIT {result.returncode}\n')
        after = tree(repo)
        log.write(f'HEAD_AFTER {after[0]}\nWORKTREE_DIRTY_AFTER {after[1]}\n')
        if args.require_clean and after != (head, 0):
            raise ValueError('Tree changed during final verification')
    print(json.dumps(dict(log=str(args.log), head=head, dirty=dirty, exit=result.returncode)))
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
