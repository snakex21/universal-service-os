#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Firstboot refusal and event-driven endpoint tests; no Windows/QEMU VM."""
import asyncio
import contextlib
import copy
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import windows_firstboot_case as c
import firstboot_qmp


class FirstbootTests(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parents[2]/'runtime';root.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(prefix='firstboot-gate-unit-',dir=root)
        self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.boot=dict(schema='minios-uefi-boot-provision-v1',passed=True,arch='x86_64',mode='uefi',dirty=0,
                       head='a'*40,returncode=33,timed_out=False,completion_wait=True,source_base_unchanged=True,
                       overlays_bounded=True,first_windows_boot_attempted=False,physical_disks_opened=False,
                       host_firmware_entries_changed=False,immutable_inputs=[dict(path=str(self.root/'input'),sha256='f'*64)])
        for name in ('target','source','native_receipt','reference_receipt','compare_receipt','boot_files_manifest'):
            self.boot[name+'_sha256']='f'*64

    def test_provision_pass_cannot_be_a_truthy_incomplete_or_wrong_architecture_flag(self):
        c.boot_fields(self.boot,'x86_64')
        for field,value in [('passed',1),('returncode',True),('dirty',1),('head',''),('timed_out',True),
                            ('source_base_unchanged',False),('first_windows_boot_attempted',True),
                            ('native_receipt_sha256',''),('immutable_inputs',[])]:
            bad=copy.deepcopy(self.boot);bad[field]=value
            with self.subTest(field=field):
                with self.assertRaises(ValueError):c.boot_fields(bad,'x86_64')
        with self.assertRaises(ValueError):c.boot_fields(self.boot,'bios')

    def test_reserved_output_cannot_escape_reuse_or_cross_architecture(self):
        with patch.object(c.oracle,'RUNTIME',self.root):
            good=self.root/'1c23/qemu-x64/firstboot-case'
            self.assertEqual(c.output_guard(good,'x86_64'),good)
            for bad in (self.root/'1c23/qemu-bios/firstboot-case',self.root/'else/firstboot-case',good.parent):
                with self.assertRaises(ValueError):c.output_guard(bad,'x86_64')
            good.mkdir(parents=True)
            with self.assertRaises(ValueError):c.output_guard(good,'x86_64')

    def test_only_pinned_build_artifact_can_be_read_outside_pool(self):
        build=self.root/'checkout/zig-out/test-assets';build.mkdir(parents=True)
        artifact=build/'usosprep-boot-x86_64.efi';artifact.write_bytes(b'firmware')
        pool=self.root/'pool';pool.mkdir()
        disk=pool/'target.qcow2';disk.write_bytes(b'image')
        with patch.object(c,'REPO',self.root/'checkout'),patch.object(c.oracle,'RUNTIME',pool):
            proof={'program_sha256':'a'*64}
            self.assertEqual(c.immutable_input(artifact,'a'*64,proof),artifact)
            self.assertEqual(c.immutable_input(disk,'b'*64),disk)
            for path,sha,receipt in ((artifact,'b'*64,proof),(artifact,'a'*64,None),
                                     (self.root/'host.qcow2','a'*64,proof)):
                with self.subTest(path=path,sha=sha,receipt=receipt):
                    with self.assertRaises(ValueError):c.immutable_input(path,sha,receipt)
            image=build/'host.qcow2';image.write_bytes(b'not firmware')
            with self.assertRaises(ValueError):c.immutable_input(image,'a'*64,proof)

    def test_resume_accepts_only_closed_bounded_same_boot_checkpoint(self):
        previous=dict(schema='minios-windows-firstboot-v1',status='PENDING_REVIEW',dirty=0,
                      head='a'*40,arch='x86_64',boot_receipt_sha256='b'*64,
                      immutable_base_unchanged=True,within_budget=True,physical_disks_opened=False,
                      target_sha256='c'*64,qmp=dict(returncode=0,endpoint_reason='fixed_deadline'))
        c.resume_fields(previous,'b'*64,'x86_64')
        for field,value in (('status','EVIDENCE_FAILURE'),('dirty',1),('within_budget',False),
                            ('immutable_base_unchanged',False),('boot_receipt_sha256','d'*64)):
            bad=copy.deepcopy(previous);bad[field]=value
            with self.subTest(field=field):
                with self.assertRaises(ValueError):c.resume_fields(bad,'b'*64,'x86_64')
        bad=copy.deepcopy(previous);bad['qmp']['endpoint_reason']='BLOCK_IO_ERROR'
        with self.assertRaises(ValueError):c.resume_fields(bad,'b'*64,'x86_64')
        with self.assertRaises(ValueError):c.resume_fields(previous,'b'*64,'bios')

    def test_missing_or_forged_real_provision_receipt_refuses_before_image_io(self):
        args=SimpleNamespace(arch='x86_64',out=self.root/'1c23/qemu-x64/firstboot-case',
                             boot_receipt=self.root/'missing.json',boot_sha256='0'*64,
                             qemu_dir=Path(__file__).resolve().parent,endpoint_seconds=600)
        @contextlib.contextmanager
        def own_read(path):
            with path.open('rb') as source:yield source
        for create in (False,True):
            if create:args.boot_receipt.write_text(json.dumps(self.boot),encoding='utf-8')
            with patch.object(c.oracle,'RUNTIME',self.root),patch.object(c.oracle,'readonly',side_effect=own_read), \
                 patch.object(c.logged_run,'tree',return_value=('a'*40,0)),patch.object(c.pool,'enforce_incremental') as pool, \
                 patch.object(c.commands,'execute') as command,patch.object(c.firstboot_qmp,'endpoint') as endpoint:
                with self.assertRaises((ValueError,FileNotFoundError)):c.run(args)
                pool.assert_not_called();command.assert_not_called();endpoint.assert_not_called()
                self.assertFalse(args.out.exists())

    def test_interrupted_recovery_is_explicit_and_never_accepts_disk_errors(self):
        previous=dict(schema='minios-windows-firstboot-v1',status='EVIDENCE_FAILURE',dirty=0,
                      head='a'*40,arch='x86_64',boot_receipt_sha256='b'*64,
                      immutable_base_unchanged=True,within_budget=True,physical_disks_opened=False,
                      target_sha256='c'*64,qmp=dict(returncode=4294967295,transport_error='QMP closed: EOF'))
        with self.assertRaises(ValueError):c.resume_fields(previous,'b'*64,'x86_64')
        c.resume_fields(previous,'b'*64,'x86_64',interrupted=True)
        for field,value in (('block_io_error',{}),('unexpected_stop',{}),('returncode',0),('transport_error','other')):
            bad=copy.deepcopy(previous);bad['qmp'][field]=value
            with self.assertRaises(ValueError):c.resume_fields(bad,'b'*64,'x86_64',interrupted=True)

    def test_recovery_consistency_check_is_readonly_and_refuses_damage(self):
        image=self.root/'windows.qcow2'
        check=dict(format='qcow2',filename=str(image),**{'check-errors':0})
        result=SimpleNamespace(returncode=0,stdout=json.dumps(check).encode(),stderr=b'')
        with patch.object(c.subprocess,'run',return_value=result) as run:
            self.assertTrue(c.check_interrupted_checkpoint(self.root/'qemu-img',image)['read_only'])
            self.assertEqual(run.call_args.args[0][1:5],['check','--output=json','-f','qcow2'])
            self.assertNotIn('-r',run.call_args.args[0])
            for bad in ({},{**check,'leaks':1},{**check,'check-errors':True},{**check,'format':'raw'}):
                result.stdout=json.dumps(bad).encode()
                with self.assertRaises(ValueError):c.check_interrupted_checkpoint(self.root/'qemu-img',image)
            result.stdout=json.dumps(check).encode();result.returncode=2
            with self.assertRaises(ValueError):c.check_interrupted_checkpoint(self.root/'qemu-img',image)

    def test_ahci_cpu_ram_and_reboots_for_each_architecture(self):
        (self.root/'vars.fd').write_bytes(bytes(540672))
        for arch,cpu,memory in [('x86_64','max','4096'),('ia32','qemu32','2048'),('bios','qemu32','2048')]:
            args=SimpleNamespace(arch=arch,qemu_dir=self.root)
            command=list(map(str,c.command_for(args,self.root)))
            self.assertEqual(command[command.index('-cpu')+1],cpu)
            self.assertEqual(command[command.index('-m')+1],memory)
            self.assertIn('ich9-ahci,id=win-ahci',command)
            self.assertIn('ide-hd,drive=windows,bus=win-ahci.0,bootindex=1,werror=stop,rerror=stop',command)
            self.assertNotIn('-no-reboot',command)
            self.assertEqual(any('pflash' in value for value in command),arch!='bios')

    def test_bios_bcd_partition_offset_and_loader_identity_checked(self):
        layout=dict(mode='bios',mbr_signature=0x12345678,system_number=1,windows_number=2,
                    partitions=[dict(number=1,start=1024**2),dict(number=2,start=101*1024**2)])
        route=dict(system=dict(style='MBR',signature=0x12345678,byte_offset=1024**2),
                   windows=dict(style='MBR',signature=0x12345678,byte_offset=101*1024**2),
                   manager_path='\\bootmgr',loader_path='\\windows\\system32\\winload.exe',systemroot='\\windows',
                   winpe=False,manager_locale='pl-pl',loader_locale='pl-pl')
        route['osdevice']=copy.deepcopy(route['windows'])
        c.route_layout(route,layout)
        route['windows']['byte_offset']+=512
        with self.assertRaises(ValueError):c.route_layout(route,layout)

    def test_isolated_nic_is_explicit_and_has_no_forwarding(self):
        (self.root/'vars.fd').write_bytes(bytes(540672))
        args=SimpleNamespace(arch='x86_64',qemu_dir=self.root)
        default=list(map(str,c.command_for(args,self.root)))
        self.assertNotIn('-netdev',default)
        args.isolated_nic=True
        isolated=list(map(str,c.command_for(args,self.root)))
        self.assertEqual(isolated[isolated.index('-netdev')+1],'user,id=isolated,restrict=on')
        self.assertIn('e1000e,netdev=isolated',isolated)
        self.assertFalse(any('hostfwd' in value or 'guestfwd' in value for value in isolated))
        args.isolated_nic='yes'
        with self.assertRaises(ValueError):c.command_for(args,self.root)

    def test_whpx_is_explicit_and_preserves_baseline_devices(self):
        (self.root/'vars.fd').write_bytes(bytes(540672))
        args=SimpleNamespace(arch='x86_64',qemu_dir=self.root)
        baseline=list(map(str,c.command_for(args,self.root)))
        self.assertEqual(baseline[baseline.index('-accel')+1],'tcg,thread=multi')
        args.accelerator='whpx'
        whpx=list(map(str,c.command_for(args,self.root)))
        self.assertEqual(whpx[whpx.index('-accel')+1],'whpx')
        self.assertEqual(whpx[whpx.index('-cpu')+1],'qemu64,-xsave')
        for option in ('-m','-smp','-machine','-nic'):
            self.assertEqual(whpx[whpx.index(option)+1],baseline[baseline.index(option)+1])
        args.arch='ia32'
        with self.assertRaises(ValueError):c.command_for(args,self.root)

    def test_whpx_candidates_do_not_accept_arbitrary_flags(self):
        (self.root/'vars.fd').write_bytes(bytes(540672))
        args=SimpleNamespace(arch='x86_64',qemu_dir=self.root,accelerator='whpx',whpx_irqchip='off',whpx_cpu='qemu64')
        command=list(map(str,c.command_for(args,self.root)))
        self.assertEqual(command[command.index('-accel')+1],'whpx,kernel-irqchip=off')
        self.assertEqual(command[command.index('-cpu')+1],'qemu64')
        args.whpx_cpu='max-no-xsave-avx-avx2-avx512f'
        command=c.command_for(args,self.root)
        self.assertEqual(command[command.index('-cpu')+1],'max,-xsave,-avx,-avx2,-avx512f')
        args.whpx_cpu='unreviewed,-flag'
        with self.assertRaises(ValueError):c.command_for(args,self.root)
        args.arch='x86_64';args.accelerator='unknown'
        with self.assertRaises(ValueError):c.command_for(args,self.root)


class EndpointTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        root=Path(__file__).resolve().parents[2]/'runtime';root.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(prefix='firstboot-qmp-unit-',dir=root)
        self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)

    async def own_qmp_peer(self,shutdown,late_io=None,unexpected_stop=False):
        commands=[];peers=[];tasks=[]
        class Process:
            def __init__(self):
                self.done=asyncio.get_running_loop().create_future()
                self.stdout=asyncio.StreamReader();self.stderr=asyncio.StreamReader()
            async def wait(self):return await self.done
            def kill(self):
                if not self.done.done():self.done.set_result(-9)
                self.stdout.feed_eof();self.stderr.feed_eof()
        process=Process()
        async def peer(port):
            reader,writer=await asyncio.open_connection('127.0.0.1',port)
            peers.append(writer)
            writer.write(b'{"QMP":{"version":{}}}\n');await writer.drain()
            while line:=await reader.readline():
                value=json.loads(line);command=value['execute'];commands.append(command)
                if shutdown and command=='qmp_capabilities':
                    writer.write(b'{"event":"SHUTDOWN","data":{"guest":true}}\n')
                if unexpected_stop and command=='qmp_capabilities':
                    writer.write(b'{"event":"STOP"}\n')
                if command=='screendump':Path(value['arguments']['filename']).write_bytes(b'P6\n1 1\n255\n\0\0\0')
                if command==late_io:
                    writer.write(b'{"event":"BLOCK_IO_ERROR","data":{"nospace":false,"action":"stop"}}\n')
                writer.write(json.dumps(dict(id=value['id'],**{'return':{}})).encode()+b'\n');await writer.drain()
                if command=='quit':
                    process.done.set_result(0);process.stdout.feed_eof();process.stderr.feed_eof();writer.close();return
        async def create(*command,**kwargs):
            address=command[command.index('-qmp')+1]
            port=int(address.rsplit(':',1)[1]);tasks.append(asyncio.create_task(peer(port)))
            return process
        with patch.object(firstboot_qmp.asyncio,'create_subprocess_exec',side_effect=create):
            result=await asyncio.wait_for(firstboot_qmp.endpoint(['own-no-VM-fixture'],self.root,{},
                                                               10800 if unexpected_stop else 1),3)
        await asyncio.gather(*tasks)
        for writer in peers:writer.close()
        if late_io:
            self.assertIn('BLOCK_IO_ERROR',result.get('transport_error',''),result)
            self.assertIn('block_io_error',result)
        elif unexpected_stop:self.assertIn('Unexpected QMP STOP',result['transport_error'])
        else:self.assertNotIn('transport_error',result,result)
        self.assertEqual(commands,['qmp_capabilities','stop','screendump','quit'])
        self.assertTrue(result['screenshot_created'])
        self.assertFalse(result['windows_gate_passed'])
        self.assertTrue(result['review_required'])
        self.assertFalse(result['progress_polling'])
        return result

    async def test_shutdown_event_before_capabilities_reply_still_runs_one_endpoint(self):
        result=await self.own_qmp_peer(True)
        self.assertEqual(result['endpoint_reason'],'guest_shutdown')

    async def test_single_fixed_deadline_without_progress_queries(self):
        result=await self.own_qmp_peer(False)
        self.assertEqual(result['endpoint_reason'],'fixed_deadline')

    async def test_unexpected_stop_wakes_three_hour_wait_and_retains_endpoint_evidence(self):
        result=await self.own_qmp_peer(False,unexpected_stop=True)
        self.assertEqual(result['endpoint_reason'],'unexpected_stop')
        self.assertEqual(result['unexpected_stop']['event'],'STOP')

    async def test_late_disk_error_after_stop_is_terminal_despite_exit_zero(self):
        await self.own_qmp_peer(True,'stop')

    async def test_late_disk_error_after_screenshot_is_terminal_despite_exit_zero(self):
        await self.own_qmp_peer(True,'screendump')

    async def test_late_disk_error_during_quit_is_terminal_despite_exit_zero(self):
        await self.own_qmp_peer(True,'quit')


if __name__=='__main__':unittest.main()
