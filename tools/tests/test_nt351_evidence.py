"""Host evidence-policy, framed-socket and DHCP correlation tests; no VM."""
from pathlib import Path
import asyncio
import base64
import importlib.util
import io
import json
import os
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from test_w9x_phase1_qemu import shell

ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'tools/tests/coverage'
def load(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
own=load('collect_nt351_success');cap=load('nt351_capture')
TMP=ROOT/'artifacts/nt351-evidence-host';TMP.mkdir(parents=True,exist_ok=True)


def archive(items):
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as output:
        for name,data,kind in items:
            item=tarfile.TarInfo(name);item.type=kind;item.size=len(data)
            output.addfile(item,io.BytesIO(data))
    return stream.getvalue()


def packet(kind,xid=123,mac=None,address=b'\x0a\0\x02\x0f',server=b'\x0a\0\x02\x02'):
    mac=mac or bytes.fromhex(cap.MAC.replace(':',''))
    client=kind in (1,3);other=b'\x52\x55\x0a\0\x02\x02'
    eth=(b'\xff'*6 if client else mac)+(mac if client else other)+b'\x08\x00'
    body=bytearray(240);body[:3]=bytes((1 if client else 2,1,6))
    struct.pack_into('!I',body,4,xid);body[28:34]=mac
    if not client:body[16:20]=address
    body[236:240]=b'\x63\x82\x53\x63'
    opts=bytes((53,1,kind))
    if kind!=1:opts+=bytes((54,4))+server
    if kind==3:opts+=bytes((50,4))+address
    if kind==5:opts+=bytes((51,4))+struct.pack('!I',3600)+bytes((3,4))+server+bytes((6,4))+b'\x0a\0\x02\x03'
    body+=opts+b'\xff'
    udp=struct.pack('!HHHH',68 if client else 67,67 if client else 68,8+len(body),0)+body
    ip=bytearray(struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(udp),1,0,64,17,0,
        b'\0'*4 if client else server,b'\xff'*4))
    struct.pack_into('!H',ip,10,cap.checksum(ip))
    return eth+ip+udp


def pcap(frames):
    return cap.PCAP_HEADER+b''.join(struct.pack('<IIII',1,0,len(f),len(f))+f for f in frames)


class EvidencePolicy(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=TMP);self.root=Path(self.temp.name)
        self.collection=self.root/'collection';self.work=self.collection/'_vm/one'
        self.work.mkdir(parents=True);(self.work/'target.qcow2').write_bytes(b'owned test fixture')
        self.assets=self.collection/'_assets/frozen';self.assets.mkdir(parents=True)
        self.out=self.root/'artifacts/coverage/result'
        self.metadata=dict(private_profile=False,folder='Windows NT 3.51')
    def tearDown(self):self.temp.cleanup()
    def check(self,metadata):own.validate(metadata,self.work,self.assets,self.out,self.collection,self.root)
    def test_only_explicit_keyless_nt351_and_owned_paths(self):
        self.check(self.metadata)
        for value in (None,0,'false',True):
            with self.subTest(value=value),self.assertRaises(ValueError):self.check(dict(self.metadata,private_profile=value))
        for folder in ('Windows NT 3.5','Windows NT 4.0',None,'Windows NT 3.51 '):
            with self.assertRaises(ValueError):self.check(dict(self.metadata,folder=folder))
        with self.assertRaises(ValueError):own.validate(self.metadata,self.root,self.assets,self.out,self.collection,self.root)
        with self.assertRaises(ValueError):own.validate(self.metadata,self.work,self.root,self.out,self.collection,self.root)
    def test_five_exact_paths_hash_and_no_pass(self):
        items=[('./'+n,(n+' own log\n').encode(),tarfile.REGTYPE) for n in own.FILES]
        items.append(('./DRIVER-READBACK.SHA256',(own.DRIVER_SHA256+'\n').encode(),tarfile.REGTYPE))
        result=own.export_evidence(archive(items),self.out)
        self.assertTrue(result['driver_hash_matches']);self.assertFalse(result['installed_runtime_pass'])
        self.assertEqual(result['files'],sorted(own.FILES));self.assertEqual(result['missing'],[])
        self.assertEqual(sorted(p.name for p in self.out.iterdir()),sorted(own.FILES))
    def test_missing_driver_and_status_never_become_runtime_pass(self):
        result=own.export_evidence(archive([('NET351.STATUS',b'installed_runtime_pass=true\n',tarfile.REGTYPE)]),self.out)
        self.assertFalse(result['installed_runtime_pass']);self.assertFalse(result['driver_hash_matches'])
    def test_archive_rejects_before_writing(self):
        cases=[('../NET351.STATUS',b'x',tarfile.REGTYPE),('else/POST.LOG',b'x',tarfile.REGTYPE),
            ('POST.LOG',b'x\0',tarfile.REGTYPE),('POST.LOG',b'\xff',tarfile.REGTYPE),
            ('POST.LOG',b'',tarfile.SYMTYPE),('POST.LOG',b'x'*(own.MAX_FILE+1),tarfile.REGTYPE),
            ('DRIVER-READBACK.SHA256',b'no hash',tarfile.REGTYPE)]
        for bad in cases:
            with self.subTest(name=bad[0],size=len(bad[1])),self.assertRaises((ValueError,UnicodeDecodeError)):
                own.export_evidence(archive([bad]),self.out)
            self.assertFalse(self.out.exists())
        with self.assertRaises(ValueError):own.export_evidence(archive([cases[0],cases[0]]),self.out)
        with self.assertRaises(ValueError):own.export_evidence(archive([('POST.LOG',b'x',tarfile.REGTYPE)]*2),self.out)
    def test_transport_exact_boundaries_and_strict_base64(self):
        payload=archive([]);text='NT351_OWN_EVIDENCE_BEGIN\n'+base64.b64encode(payload).decode()+'\nNT351_OWN_EVIDENCE_END\n'
        self.assertEqual(own.decode_transport(text),payload)
        for bad in (text+text,text.replace('END','NOEND'),text.replace('\nH','\n!H'), 'x'*(own.MAX_TRANSPORT+1)):
            with self.assertRaises((ValueError,base64.binascii.Error)):own.decode_transport(bad)
        self.assertIn('readonly=on',(HERE/'collect_nt351_success.py').read_text())
        self.assertNotIn('SYSTEM32/CONFIG',own.commands())
    def test_real_busybox_interleaved_end_prefix_and_strict_rejections(self):
        # Same framing as R18c completed serial: a queued END prefix interrupts
        # one76-character base64 line; the full echoed command follows payload.
        payload=archive([('POST.LOG',bytes(range(1,128))*5,tarfile.REGTYPE)])
        value=base64.b64encode(payload).decode();chunks=[value[i:i+76] for i in range(0,len(value),76)]
        self.assertGreater(len(chunks),2)
        chunks[1]+='NT351_OW'
        text='NT351_OWN_EVIDENCE_BEGIN\n/tmp/export # base64 /tmp/evidence.tgz\n'+\
            '\n\n'.join(chunks)+'\n/tmp/export # echo NT351_OWN_EVIDENCE_END\nNT351_OWN_EVIDENCE_END\n'
        self.assertEqual(own.decode_transport(text),payload)
        mutations=(text.replace('NT351_OW\n','NT351_OX\n'),
            text.replace('/tmp/export # echo NT351_OWN_EVIDENCE_END\n',''),
            text.replace('/tmp/export # base64 /tmp/evidence.tgz','/tmp/export # rm /tmp/evidence.tgz'),
            text.replace('NT351_OW\n','NT351_OWNT351_OW\n'),
            text.replace('NT351_OWN_EVIDENCE_END\n','AAAA\nNT351_OWN_EVIDENCE_END\n',1))
        for bad in mutations:
            with self.subTest(bad=bad[-120:]),self.assertRaises((ValueError,base64.binascii.Error)):
                own.decode_transport(bad)
        simple='NT351_OWN_EVIDENCE_BEGIN\n'+value+'AAAA\nNT351_OWN_EVIDENCE_END\n'
        with self.assertRaises((ValueError,base64.binascii.Error)):own.decode_transport(simple)

    def test_actual_shell_tar_base64_and_driver_hash_transport(self):
        source=self.root/'source';source.mkdir()
        for name in own.FILES:(source/name).write_text(name+' own text\n',encoding='utf-8')
        driver=Path(os.environ.get('USOSNET351_TEST_DRIVER',ROOT/'tools/nt/usosnet/bin/i386/usosnet351.sys'))
        shutil.copy(driver,source/'usosnet351.sys')
        runtime=self.root/'runtime';runtime.mkdir()
        runtime_shell=runtime.as_posix()
        if runtime.drive:runtime_shell='/'+runtime_shell[0].lower()+runtime_shell[2:]
        code=own.commands();code=code[code.index('disk=/dev/vda'):code.index('cd /\necho LOWRAM')]
        code=code.replace('/tmp/',runtime_shell+'/')
        script=self.root/'transport.sh'
        script.write_text('set -e\nset -o pipefail\n'+f'mkdir -p "{runtime.as_posix()}/export"\n'+
            'mdir() { case "$3" in ::/USOS/NT3/*|::/WINNT/SYSTEM32/DRIVERS/usosnet351.sys) '+
            f'[ -f "{source.as_posix()}/${{3##*/}}" ];; *) return 1;; esac; }}\n'+
            f'mtype() {{ cat "{source.as_posix()}/${{3##*/}}"; }}\n'+code,encoding='utf-8',newline='\n')
        result=subprocess.run([shell(),str(script)],capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        proof=own.export_evidence(own.decode_transport(result.stdout.decode()),self.out)
        self.assertTrue(proof['driver_hash_matches']);self.assertFalse(proof['installed_runtime_pass'])
        self.assertEqual(sorted(proof['files']),sorted(own.FILES))


class DHCPProof(unittest.TestCase):
    def test_ordered_dora_pinned_to_client_and_phase(self):
        data=pcap([packet(n) for n in (1,2,3,5)])
        result=cap.analyze_pcap(data,1)
        self.assertTrue(result['dora_observed']);proof=result['exchanges'][0]
        self.assertEqual(proof['records'],[1,2,3,4]);self.assertEqual(proof['address'],'10.0.2.15')
        self.assertEqual(proof['dns'],['10.0.2.3']);self.assertFalse(result['icmp_pass']);self.assertFalse(result['dns_pass'])
        self.assertFalse(cap.analyze_pcap(data,None)['dora_observed'])
        self.assertFalse(cap.analyze_pcap(data,2)['dora_observed'])
    def test_bad_mac_xid_order_request_and_corruption_rejected(self):
        cases=[[packet(n,mac=b'\0'*6) for n in (1,2,3,5)],
            [packet(1),packet(2,xid=999),packet(3),packet(5)],
            [packet(n) for n in (1,3,2,5)],
            [packet(1),packet(2),packet(3,address=b'\x01\x02\x03\x04'),packet(5)],
            [packet(1),packet(2),packet(3),packet(5,server=b'\x01\x02\x03\x04')],
            [packet(n)[:-1] for n in (1,2,3,5)]]
        for frames in cases:self.assertFalse(cap.analyze_pcap(pcap(frames),1)['dora_observed'])
        bad=bytearray(packet(1));bad[24]^=1;self.assertIsNone(cap.dhcp(bad))
        for data in (pcap([])+b'x',pcap([packet(1)])[:-1]):
            with self.assertRaises(ValueError):cap.analyze_pcap(data,1)
    def test_retransmit_is_bounded_and_does_not_reset_valid_exchange(self):
        result=cap.analyze_pcap(pcap([packet(n) for n in (1,1,2,2,3,3,5,5)]),1)
        self.assertEqual(len(result['exchanges']),1)


class PassiveReceiver(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=TMP);self.path=Path(self.temp.name)/'vm.pcap'
    async def asyncTearDown(self):self.temp.cleanup()
    async def connect(self,receiver):
        port=await receiver.start();reader,writer=await asyncio.open_connection('127.0.0.1',port)
        await receiver.connected.wait();return writer
    async def test_fragmented_wire_stream_and_dora(self):
        receiver=cap.Capture(self.path);writer=await self.connect(receiver);receiver.mark_prepared_target()
        wire=b''.join(struct.pack('!I',len(f))+f for f in [packet(n) for n in (1,2,3,5)])
        for pos in range(0,len(wire),13):writer.write(wire[pos:pos+13]);await writer.drain()
        writer.close();await writer.wait_closed();result=await receiver.finish()
        self.assertEqual(result['stored_frames'],4);self.assertTrue(result['analysis']['dora_observed'])
        self.assertIsNone(result['error']);self.assertEqual(self.path.stat().st_size,result['stored_bytes'])
    async def test_cap_includes_headers_and_drains_after_full(self):
        receiver=cap.Capture(self.path,max_bytes=100);writer=await self.connect(receiver)
        frame=b'\0'*60
        writer.write((struct.pack('!I',len(frame))+frame)*100);await writer.drain()
        writer.close();await writer.wait_closed();result=await receiver.finish()
        self.assertEqual(result['stored_bytes'],100);self.assertEqual(result['received_frames'],100)
        self.assertEqual(result['discarded_frames'],99);self.assertTrue(result['capped'])
    async def test_bad_length_and_truncated_frame_fail_evidence(self):
        for wire in (struct.pack('!I',2**32-1),struct.pack('!I',60)+b'truncated'):
            path=self.path.with_name(str(len(wire))+'.pcap');receiver=cap.Capture(path);writer=await self.connect(receiver)
            writer.write(wire);await writer.drain();writer.close();await writer.wait_closed()
            result=await receiver.finish();self.assertIsNotNone(result['error']);self.assertFalse(result['analysis']['dora_observed'])
    async def test_no_connection_is_not_proof(self):
        receiver=cap.Capture(self.path);await receiver.start();result=await receiver.finish()
        self.assertFalse(result['connected']);self.assertFalse(result['analysis']['dora_observed'])
    async def test_open_localhost_client_cannot_block_finish_indefinitely(self):
        receiver=cap.Capture(self.path);writer=await self.connect(receiver)
        # Deliberately retain the connection: Python3.13 server.wait_closed
        # would otherwise wait forever before reaching the client timeout.
        result=await asyncio.wait_for(receiver.finish(),8)
        self.assertIn('did not close',result['error']);self.assertFalse(result['analysis']['dora_observed'])
        writer.close();await writer.wait_closed()


class IntegrationPatch(unittest.TestCase):
    def test_patch_applies_to_pinned_runner_and_collects_before_cleanup(self):
        matrix=ROOT.parent/'macierz-windows'
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            directory=Path(temporary)
            for name in ('boot_menu.py','run_plan.py'):
                relative='tools/tests/coverage/'+name
                source=subprocess.check_output(['git','-C',str(matrix),'show','e0fac76d:'+relative])
                path=directory/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(source)
            patch=HERE/'nt351-runner-e0fac76d.patch'
            subprocess.run(['git','apply','--check','--unsafe-paths',str(patch)],cwd=directory,check=True,capture_output=True)
            subprocess.run(['git','apply','--unsafe-paths',str(patch)],cwd=directory,check=True,capture_output=True)
            boot=(directory/'tools/tests/coverage/boot_menu.py').read_text();compile(boot,'patched boot_menu.py','exec')
            plan=(directory/'tools/tests/coverage/run_plan.py').read_text();compile(plan,'patched run_plan.py','exec')
            self.assertLess(boot.index('await nt351_own.main('),boot.index('path.unlink()  # These exact per-test files only'))
            self.assertLess(boot.index('await network_capture.finish()\n        except Exception'),boot.index('await nt351_own.main('))
            self.assertIn('require_target=False',boot);self.assertIn("'--collect-nt351-success'",plan)
            self.assertIn("'--capture-nt351-network'",plan)
            self.assertGreater(boot.index('await network_capture.start()'),boot.index('usb_disks=aux.create_sticks'))
            self.assertLess(boot.index('await network_capture.start()'),boot.index('process = await asyncio.create_subprocess_exec'))


if __name__=='__main__':unittest.main()
