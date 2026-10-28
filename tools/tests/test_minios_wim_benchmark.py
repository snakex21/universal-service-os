#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import wim_benchmark as bench


class BenchmarkProofTests(unittest.TestCase):
    def test_clean_build_proof_requires_exact_mode_architecture_and_i486(self):
        command=['zig','build-exe','src/prep/wim_bench.zig','-target','x86-windows','-mcpu','i486','-O','ReleaseSmall']
        def log(cmd):return 'HEAD '+'a'*40+'\nWORKTREE_DIRTY 0\nCOMMAND '+json.dumps(cmd)+'\nEXIT 0\nHEAD_AFTER '+'a'*40+'\nWORKTREE_DIRTY_AFTER 0\n'
        bench.build_proof(log(command),'a'*40,'x86')
        for old,new in [('i486','pentium4'),('ReleaseSmall','Debug'),('x86-windows','x86_64-windows')]:
            bad=[new if value==old else value for value in command]
            with self.assertRaises(ValueError):bench.build_proof(log(bad),'a'*40,'x86')
        with self.assertRaises(ValueError):bench.build_proof(log(command).replace('WORKTREE_DIRTY 0','WORKTREE_DIRTY 1'),'a'*40,'x86')

    def test_measurement_keeps_sha_and_decoder_separate_and_checks_real_sample(self):
        row=dict(arch='x86',cpu='i486',optimize='ReleaseSmall',sha1_verified=True,timed_io=False,sha1='a'*40,
                 size=1024**2,stored=500000,lzx_chunks=32,decoder_bytes=16*1024**2,decoder_ns=1_000_000_000,
                 sha_bytes=256*1024**2,sha_ns=2_000_000_000,allocator_peak=2*1024**2)
        def parse(value):return bench.measurement('BENCH_RESULT '+json.dumps(value)+'\n','x86')
        value=parse(row)
        self.assertEqual(value['decoder_mib_per_second'],16)
        self.assertEqual(value['sha_mib_per_second'],128)
        for key,bad in [('timed_io',True),('sha1_verified',False),('decoder_ns',0),('size',5*1024**2),('cpu','pentium4')]:
            changed=copy.deepcopy(row);changed[key]=bad
            with self.assertRaises(ValueError):parse(changed)


if __name__=='__main__':unittest.main()
