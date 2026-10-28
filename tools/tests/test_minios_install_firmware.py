# SPDX-License-Identifier: GPL-3.0-or-later
"""Firmware receipt requires genuine completion and memory evidence."""
import importlib.util
from pathlib import Path
import sys, tempfile, unittest
from types import SimpleNamespace
from unittest.mock import patch,Mock,mock_open
HERE=Path(__file__).resolve().parents[1]/'minios'
sys.path.insert(0,str(HERE))
import install_firmware_case as c
import install_native as native

class TestFirmwareAcceptance(unittest.TestCase):
    log='USOSPREP WIM PASS\nINSTALL layout_mode=uefi\nSTACK canary_ok=true reserved_bytes=1048576 high_water_bytes=123456\nUSOSPREP PLATFORM stack_bytes=1048576 alloc_current=0 alloc_peak=9999999\n'
    def test_fat_fixture_binds_approved_root_without_opening_an_image(self):
        root=Path(__file__).resolve().parents[2]/'runtime'/'approved-fixture-root'
        tool=Path(__file__).resolve().parents[2]/'runtime'/'explicit-tools'
        oldroot,oldqemu=c.firmware.api.ROOT,c.firmware.api.QEMU
        self.addCleanup(setattr,c.firmware.api,'ROOT',oldroot)
        self.addCleanup(setattr,c.firmware.api,'QEMU',oldqemu)
        with patch.object(c.oracle,'RUNTIME',root):
            expected=root/'case'/'boot-base.raw'
            self.assertEqual(c.configure_fixture_tools(root/'case',tool),expected)
            self.assertEqual(c.firmware.api.ROOT,root)
            with self.assertRaises(ValueError):c.firmware.api.checked(root.parent/'outside.raw')
        self.assertFalse(root.exists())

    def test_marker_uses_qemu_parser_safe_basename_and_explicit_cwd(self):
        out=Path(__file__).resolve().parents[2]/'runtime'/'case with spaces'
        qemu=out.parent/'qemu tools'
        with patch.object(c,'execute') as execute:
            c.write_target_marker(qemu,out/'target-base.qcow2',out,{})
            args,kwargs=execute.call_args
            self.assertEqual(args[0][4],'write -s marker.bin 0 512')
            self.assertEqual(kwargs['cwd'],out)
            with self.assertRaises(ValueError):c.write_target_marker(qemu,out/'other.qcow2',out,{})
            self.assertEqual(execute.call_count,1)

    def test_source_device_keeps_backend_readonly_without_ide_write_permission(self):
        source=Path(__file__).resolve().parents[2]/'runtime'/'source file.raw'
        args=c.readonly_source_args(source)
        self.assertEqual(args[0],'-drive')
        self.assertEqual(args[1],f'if=none,id=source,format=raw,readonly=on,file={source}')
        self.assertEqual(args[2:],['-device','virtio-blk-pci,drive=source'])
        self.assertNotIn('snapshot',','.join(args))
        self.assertNotIn('ide-hd',','.join(args))

    def test_preparation_target_is_writable_explicit_qcow2_virtio(self):
        target=Path(__file__).resolve().parents[2]/'runtime'/'new target.qcow2'
        args=c.preparation_target_args(target)
        self.assertEqual(args,['-drive',f'if=none,id=target,format=qcow2,file={target}',
                               '-device','virtio-blk-pci,drive=target'])
        self.assertNotIn('snapshot',','.join(args))
        self.assertNotIn('readonly=on',','.join(args))

    def test_whpx_uses_64bit_qemu_exact_cpu_but_keeps_selected_uefi_firmware(self):
        out=Path('owned case');tools=Path('qemu tools');source=Path('readonly source.raw')
        for arch in ('x86_64','ia32'):
            with self.subTest(arch=arch):
                args=list(map(str,c.guest_command(tools,out,arch,128,source,'whpx')))
                self.assertEqual(args[0],str(tools/'qemu-system-x86_64.exe'))
                self.assertEqual(args[args.index('-accel')+1],'whpx')
                self.assertEqual(args[args.index('-cpu')+1],'qemu64,-xsave')
                self.assertEqual(args[args.index('-machine')+1],'q35')
                fw=tools/('share/edk2-i386-code.fd' if arch=='ia32' else 'share/edk2-x86_64-code.fd')
                self.assertIn(f'if=pflash,format=raw,readonly=on,file={fw}',args)
                self.assertIn(f'if=none,id=source,format=raw,readonly=on,file={source}',args)
                self.assertIn(f'if=none,id=target,format=qcow2,file={out/"target.qcow2"}',args)
                self.assertNotIn('-snapshot',args)

    def test_tcg_keeps_architecture_specific_emulator_cpu_and_defaults(self):
        for arch,exe,cpu in (('x86_64','qemu-system-x86_64.exe','qemu64'),('ia32','qemu-system-i386.exe','qemu32')):
            args=list(map(str,c.guest_command(Path('tools'),Path('owned'),arch,128,Path('source.raw'))))
            self.assertEqual(Path(args[0]).name,exe)
            self.assertEqual(args[args.index('-accel')+1],'tcg,thread=multi')
            self.assertEqual(args[args.index('-cpu')+1],cpu)
        self.assertEqual(c.preparation_settings(SimpleNamespace()),('tcg','selected',3600,128))
        self.assertEqual(c.preparation_settings(SimpleNamespace(accel='whpx')),('whpx','selected',1800,128))

    def test_accelerator_time_and_memory_bounds_and_scope_are_explicit(self):
        self.assertEqual(c.preparation_settings(SimpleNamespace(accel='whpx',verify_scope='all',timeout=1800,memory=64)),('whpx','all',1800,64))
        self.assertEqual(c.preparation_settings(SimpleNamespace(accel='tcg',timeout=3600,memory=512))[2:],(3600,512))
        for values in ({'accel':'whpx','timeout':1801},{'accel':'whpx','memory':256},
                       {'accel':'whpx','memory':32},{'accel':'tcg','timeout':3601},
                       {'timeout':True},{'memory':True},{'accel':'kvm'},{'verify_scope':'selected\nmode=bios'}):
            with self.subTest(values=values),self.assertRaises(ValueError):c.preparation_settings(SimpleNamespace(**values))

    def test_uefi_config_emits_scope_once_without_altering_source_bindings(self):
        proof=dict(target_bytes=6*c.GiB,partition_start=1024**2,partition_bytes=6*c.GiB-2*1024**2)
        for scope in ('selected','all'):
            fields=c.encode_config(proof,2,16*c.GiB,'a'*64,0x123456789abcdef0,scope).decode('ascii').splitlines()
            self.assertEqual([s for s in fields if s.startswith('verify_scope=')],['verify_scope='+scope])
            self.assertIn('wim_index=2',fields);self.assertIn('target_sectors=33554432',fields)
            self.assertIn('source_serial=123456789abcdef0',fields);self.assertIn('source_iso=INSTALL.ISO',fields)
        self.assertIn(b'verify_scope=selected\n',c.encode_config(proof,2,16*c.GiB,'a'*64,1))
        with self.assertRaises(ValueError):c.encode_config(proof,2,16*c.GiB,'a'*64,1,'unknown')

    def test_probes_are_explicit_and_profiling_is_off_by_default(self):
        proof=dict(target_bytes=6*c.GiB,partition_start=1024**2,partition_bytes=6*c.GiB-2*1024**2)
        default=c.encode_config(proof,2,32*c.GiB,'a'*64,1)
        self.assertIn(b'timing=off\ncombine=on\n',default)
        self.assertNotIn(b'probe_items=',default)
        cfg=c.encode_config(proof,2,32*c.GiB,'a'*64,1,timing=True,combine=False,probe_items=12613)
        self.assertIn(b'timing=on\ncombine=off\nprobe_items=12613\n',cfg)
        for value in (True,0,1000001):
            with self.assertRaises(ValueError):c.encode_config(proof,2,32*c.GiB,'a'*64,1,probe_items=value)
        self.assertFalse(c.guest_acceptance(73,False,'DIAGNOSTIC_STOP',True))

    def test_live_vhd_is_refused_before_any_io(self):
        out=Path('owned');tools=Path('tools')
        with patch.object(c,'execute') as execute,patch.object(Path,'open') as opened:
            for call in (
                lambda:c.selected_target_format(SimpleNamespace(target_format='vpc')),
                lambda:c.preparation_target_args(out/'target.vhd','vpc'),
                lambda:c.write_target_marker(tools,out/'target.vhd',out,{},'vpc'),
                lambda:c.create_preparation_target(tools,out,16*c.GiB,{},'vpc'),
                lambda:c.seal_prepared_target(tools,out,16*c.GiB,{},'vpc'),
                lambda:c.guest_command(tools,out,'ia32',64,Path('source.raw'),'whpx','vpc'),
            ):
                with self.assertRaises(ValueError):call()
            execute.assert_not_called();opened.assert_not_called()
        self.assertEqual(c.selected_target_format(SimpleNamespace()),'qcow2')
        with self.assertRaises(ValueError):c.selected_target_format(SimpleNamespace(target_format='raw'))

    def test_default_qcow_target_keeps_blank_snapshot_overlay_and_prepared_snapshot(self):
        out=Path('owned');tools=Path('tools')
        with patch.object(c,'execute') as execute,patch.object(Path,'chmod'):
            target,base=c.create_preparation_target(tools,out,16*c.GiB,{})
            self.assertEqual((target,base),(out/'target.qcow2',out/'target-base.qcow2'))
            self.assertEqual(execute.call_args_list[2].args[0],
                             [tools/'qemu-img.exe','snapshot','-c','blank',base])
            self.assertEqual(execute.call_args_list[3].args[0],
                             [tools/'qemu-img.exe','create','-f','qcow2','-F','qcow2','-b',base,target])
            self.assertEqual(c.seal_prepared_target(tools,out,16*c.GiB,{}),{})
            self.assertEqual(execute.call_args_list[4].args[0],
                             [tools/'qemu-img.exe','snapshot','-c','prepared',target])

    def test_exit_and_required_markers(self):
        self.assertTrue(c.guest_acceptance(33,False,self.log,True))
        for code in (0,35,None,True):self.assertFalse(c.guest_acceptance(code,False,self.log,True))
        for bad in ('USOSPREP WIM PASS','INSTALL layout_mode=uefi','STACK canary_ok=true'):
            self.assertFalse(c.guest_acceptance(33,False,self.log.replace(bad,''),True))
    def test_timeout_mutation_terminal_failure(self):
        self.assertFalse(c.guest_acceptance(33,True,self.log,True))
        self.assertFalse(c.guest_acceptance(33,False,self.log,False))
        self.assertFalse(c.guest_acceptance(33,False,self.log+'TERMINAL FAIL',True))
    def test_stack_and_heap_measurements(self):
        result=c.memory_evidence(self.log)
        self.assertEqual(result['stack_high_water'],123456)
        self.assertEqual(result['allocator_peak_including_stack'],9999999)
        for text in (self.log.replace('alloc_current=0','alloc_current=1'),self.log.replace('123456','1048576'),self.log.replace('reserved_bytes=1048576','reserved_bytes=2048')):
            with self.assertRaises(ValueError):c.memory_evidence(text)

    def test_completed_capture_keeps_all_guest_bytes_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'debug.log';payload=b'guest\0bytes\xff\r\n'
            path.write_bytes(payload);head='a'*40
            c.seal_capture(path,head);first=path.read_bytes()
            self.assertTrue(first.startswith(c.capture_header(head)))
            self.assertTrue(first.endswith(payload))
            c.seal_capture(path,head)
            self.assertEqual(path.read_bytes(),first)
            with self.assertRaises(ValueError):c.seal_capture(path,'unknown')

    def test_missing_capture_is_labelled_empty_without_guest_success(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'missing.log';c.seal_capture(path,'b'*40)
            self.assertIn(b'guest_did_not_create_file=true',path.read_bytes())
            self.assertFalse(c.guest_acceptance(1,False,path.read_text(),True))

if __name__=='__main__':unittest.main()
