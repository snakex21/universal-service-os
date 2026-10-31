# SPDX-License-Identifier: GPL-3.0-or-later
"""BIOS configuration and acceptance policy; no VM, image or disk access."""
from pathlib import Path
import struct,sys,unittest,zlib
from types import SimpleNamespace

HERE=Path(__file__).resolve().parents[1]/'minios'
sys.path.insert(0,str(HERE))
import bios_install_case as c


class BiosPreparationCase(unittest.TestCase):
    log=('USOSPREP WIM PASS\nINSTALL_LAYOUT mode=bios\nINSTALL_APPLY PASS mode=bios\n'
         'STACK BIOS reserved=253952 high_water=40000 guard=4096 guard_intact=true real_mode_stack_separate=true\n'
         'HEAP physical_current=0 physical_peak=8000000 extent_peak=9000000 reserved=12582912\n'
         'IO source_reads=100 source_bytes=123456 source_writes=0 target_reads=50 target_writes=80 target_written_bytes=987654\n'
         'USOSPREP INSTALL FINAL current=0 peak=7000000\n')

    def test_config_exact_installer_wire_roles_crc_and_64_bit_source_fields(self):
        proof=dict(target_bytes=6*c.GiB,partition_start=1024**2,partition_bytes=6*c.GiB-2*1024**2,iso_bytes=5*c.GiB)
        data=c.encode_config(proof,2,16*c.GiB,'a'*64,0x123456789abcdef0)
        self.assertEqual(len(data),512);self.assertEqual(data[:16],b'USOSPREP BIOS I1')
        self.assertEqual(struct.unpack_from('<IIQ',data,16),(1,512,16*c.GiB))
        self.assertEqual(struct.unpack_from('<QQQQ',data,96),(proof['target_bytes'],proof['partition_start'],proof['partition_bytes'],0x123456789abcdef0))
        self.assertEqual(data[128:132],b'\x80\x81\x82\0')
        self.assertEqual(struct.unpack_from('<IIIQ',data,132),(2,512,512,5*c.GiB))
        self.assertFalse(any(data[152:508]))
        self.assertEqual(struct.unpack_from('<I',data,508)[0],zlib.crc32(data[:508])&0xffffffff)
        for bad in (0,True,-1):
            with self.subTest(index=bad),self.assertRaises(ValueError):c.encode_config(proof,bad,16*c.GiB,'a'*64,1)
        for key,value in (('partition_start',512),('partition_bytes',7*c.GiB),('iso_bytes',0)):
            changed={**proof,key:value}
            with self.subTest(key=key),self.assertRaises(ValueError):c.encode_config(changed,1,16*c.GiB,'a'*64,1)

    def test_completion_requires_bios_apply_source_write_zero_and_healthy_stack(self):
        self.assertTrue(c.guest_acceptance(33,False,self.log,True))
        for code in (0,35,None,True):self.assertFalse(c.guest_acceptance(code,False,self.log,True))
        for marker in ('USOSPREP WIM PASS','INSTALL_LAYOUT mode=bios','INSTALL_APPLY PASS mode=bios','USOSPREP INSTALL FINAL current=0 '):
            self.assertFalse(c.guest_acceptance(33,False,self.log.replace(marker,''),True))
        for altered in (self.log.replace('source_writes=0','source_writes=1'),self.log.replace('target_writes=80','target_writes=0'),self.log+'TERMINAL FAIL'):
            self.assertFalse(c.guest_acceptance(33,False,altered,True))
        self.assertFalse(c.guest_acceptance(33,True,self.log,True));self.assertFalse(c.guest_acceptance(33,False,self.log,False))

    def test_verification_scope_wire_byte_is_covered_by_crc(self):
        proof=dict(target_bytes=6*c.GiB,partition_start=1024**2,partition_bytes=6*c.GiB-2*1024**2,iso_bytes=5*c.GiB)
        selected=c.encode_config(proof,2,16*c.GiB,'b'*64,1,'selected')
        all_blobs=c.encode_config(proof,2,16*c.GiB,'b'*64,1,'all')
        self.assertEqual(selected[152],0);self.assertEqual(all_blobs[152],1)
        self.assertEqual(selected[:152],all_blobs[:152]);self.assertFalse(any(all_blobs[153:508]))
        self.assertNotEqual(selected[508:],all_blobs[508:])
        for data in (selected,all_blobs):
            self.assertEqual(struct.unpack_from('<I',data,508)[0],zlib.crc32(data[:508])&0xffffffff)
        measured=c.encode_config(proof,2,16*c.GiB,'b'*64,1,timing=True)
        self.assertEqual(measured[153],1)
        self.assertEqual(struct.unpack_from('<I',measured,508)[0],zlib.crc32(measured[:508])&0xffffffff)
        with self.assertRaises(ValueError):c.encode_config(proof,2,16*c.GiB,'b'*64,1,'unknown')

    def test_whpx_preparation_uses_pc_64bit_emulator_and_exact_cpu(self):
        out=Path('owned case');tools=Path('qemu tools')
        args=list(map(str,c.guest_command(tools,out,'486',64,'whpx')))
        self.assertEqual(args[0],str(tools/'qemu-system-x86_64.exe'))
        self.assertEqual(args[args.index('-machine')+1],'pc')
        self.assertEqual(args[args.index('-accel')+1],'whpx')
        self.assertEqual(args[args.index('-cpu')+1],'qemu64,-xsave')
        self.assertEqual(args[args.index('-m')+1],'64')
        drives=[args[i+1] for i,s in enumerate(args) if s=='-drive']
        self.assertEqual(len(drives),3)
        self.assertTrue(all('format=qcow2' in s and '.qcow2' in s for s in drives))
        self.assertNotIn('-snapshot',args)
        self.assertEqual(c.common.preparation_settings(SimpleNamespace(),bios=True),('tcg','selected',3600,32))
        self.assertEqual(c.common.preparation_settings(SimpleNamespace(accel='whpx'),bios=True),('whpx','selected',1800,64))
        for values in ({'accel':'whpx','timeout':1801},{'accel':'whpx','memory':32},{'accel':'whpx','memory':256}):
            with self.subTest(values=values),self.assertRaises(ValueError):c.common.preparation_settings(SimpleNamespace(**values),bios=True)

    def test_memory_measurements_are_bounded_and_physical_usage_is_not_hidden(self):
        evidence=c.memory_evidence(self.log)
        self.assertEqual(evidence['physical_heap_peak'],8000000);self.assertEqual(evidence['stack_high_water'],40000)
        for changed in (self.log.replace('high_water=40000','high_water=253952'),self.log.replace('physical_current=0','physical_current=1'),self.log.replace('peak=7000000','peak=13000000'),self.log.replace('extent_peak=9000000','extent_peak=13000000')):
            with self.assertRaises(ValueError):c.memory_evidence(changed)

    def test_drive_order_is_explicit_and_every_ide_backend_uses_a_retained_overlay(self):
        out=Path('owned case with spaces');args=list(map(str,c.guest_command(Path('tools'),out,'486',32)))
        devices=[args[i+1] for i,s in enumerate(args) if s=='-device']
        self.assertIn('ide-hd,drive=boot,bus=ide.0,unit=0,bootindex=1',devices)
        self.assertIn('ide-hd,drive=source,bus=ide.0,unit=1,bootindex=2',devices)
        self.assertIn('ide-hd,drive=target,bus=ide.1,unit=0,bootindex=3',devices)
        drives=[args[i+1] for i,s in enumerate(args) if s=='-drive']
        self.assertEqual(len(drives),3)
        self.assertTrue(all('format=qcow2' in s and '.qcow2' in s for s in drives))
        self.assertFalse(any('readonly=on' in s for s in drives))
        self.assertEqual(args[args.index('-cpu')+1],'486');self.assertEqual(args[args.index('-m')+1],'32')

    def test_live_vhd_is_refused(self):
        with self.assertRaises(ValueError):
            c.guest_command(Path('tools'),Path('owned'),'486',64,'whpx','vpc')


if __name__=='__main__':unittest.main()
