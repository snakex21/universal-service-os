"""Execute the NT4 guest privacy filter, archive policy and first-logon DHCP gate."""
from pathlib import Path
import asyncio
import base64
import importlib.util
import io
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
def load(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
own=load('collect_nt4_success');cap=load('nt4_capture');transport=load('collect_guest_logs');fixture=load('prepare_stick')
TMP=ROOT/'artifacts/coverage/nt4-success-host';TMP.mkdir(parents=True,exist_ok=True)
SHELL=r'C:\Program Files\Git\bin\sh.exe'
GOOD_ICMP='[NET] ICMP gateway 10.0.2.2: PASS status=0 replies=1 rtt=123 ms echo_match=1'
GOOD_DNS='[NET] UDP DNS 10.0.2.3 (configured): reply after 123 ms from 10.0.2.3:53: 123 bytes DNS PASS dns_match=1 id=ABCD question=frogfind.com A=123.123.123.123'
GOOD_RESOLVE='[NET] gethostbyname(frogfind.com): 123.123.123.123 after 123 ms'


def archive(items):
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as out:
        for name,data,kind in items:
            item=tarfile.TarInfo(name);item.type=kind;item.size=len(data)
            out.addfile(item,io.BytesIO(data))
    return stream.getvalue()


def items(lines='',driver='matched'):
    state=own.HEADER+'\n'+own.LOGS[0]+'='+('exported' if lines else 'empty')+'\n'+own.LOGS[1]+'=unavailable\ndriver='+driver+'\nobserver=exported\n'
    value=[('collection-state.txt',state.encode(),tarfile.REGTYPE),(own.LOGS[0],lines.encode(),tarfile.REGTYPE)]
    value.append(('observer-status.txt',b'NT4_OBSERVER_STATUS=TESTNET_DONE\n',tarfile.REGTYPE))
    if driver=='matched':value.append(('driver-sha256.txt',(own.DRIVER_SHA256+'\n').encode(),tarfile.REGTYPE))
    return value


def packet(kind,xid=123):
    mac=bytes.fromhex(cap.MAC.replace(':',''));server=b'\x0a\0\x02\x02';address=b'\x0a\0\x02\x0f'
    client=kind in (1,3);other=b'\x52\x55\x0a\0\x02\x02'
    eth=(b'\xff'*6 if client else mac)+(mac if client else other)+b'\x08\x00'
    body=bytearray(240);body[:3]=bytes((1 if client else 2,1,6));struct.pack_into('!I',body,4,xid);body[28:34]=mac
    if not client:body[16:20]=address
    body[236:240]=b'\x63\x82\x53\x63';opts=bytes((53,1,kind))
    if kind!=1:opts+=bytes((54,4))+server
    if kind==3:opts+=bytes((50,4))+address
    if kind==5:opts+=bytes((51,4))+struct.pack('!I',3600)+bytes((3,4))+server+bytes((6,4))+b'\x0a\0\x02\x03'
    body+=opts+b'\xff';udp=struct.pack('!HHHH',68 if client else 67,67 if client else 68,8+len(body),0)+body
    ip=bytearray(struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(udp),1,0,64,17,0,b'\0'*4 if client else server,b'\xff'*4));struct.pack_into('!H',ip,10,cap.base.checksum(ip))
    return eth+ip+udp


class PrivacyPolicy(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=TMP);self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def test_private_nt4_exact_logger_and_actual_logon_required(self):
        collection=self.root/'collection';work=collection/'_vm/test';work.mkdir(parents=True);(work/'target.qcow2').write_bytes(b'own')
        assets=collection/'_assets/test';assets.mkdir(parents=True);out=self.root/'artifacts/coverage/one'
        meta=dict(private_profile=True,folder='Windows NT 4.0',usability_logger_sha256=own.LOGGER_SHA256,observer_kind='nt4-test-run',observer_token='USOS_COVERAGE_FIRST_LOGON_'+'a'*32,nt4_network_evidence=True,nt4_observer_helper_sha256=own.OBSERVER_HELPER_SHA256)
        def check(m=meta,first=True,**kw):own.validate(m,work,assets,out,collection,self.root,first_logon=first,**kw)
        check();check(first=False,preflight=True)
        for bad in (False,0,1,None,'true'):
            with self.assertRaises(ValueError):check(first=bad)
        for field,value in (('private_profile',False),('private_profile',1),('folder','Windows NT 3.51'),('observer_token','a'),('usability_logger_sha256','a'*64),('nt4_network_evidence',False)):
            with self.assertRaises(ValueError):check(dict(meta,**{field:value}))
        with self.assertRaises(ValueError):own.validate(meta,self.root,assets,out,collection,self.root,first_logon=True)
    def test_guest_filter_preserves_ip_and_rejects_registry_keys_control_and_unknown_net(self):
        source=('HKLM\\Software\\Secret = '+('X'*5+'-')*4+'X'*5+'\r\n'+
            '[NET] registry secret 12345-OEM-1234567-12345\r\n[NET] unknown 123-1234567\r\n'+
            GOOD_ICMP+'\r\n'+GOOD_DNS+'\r\n'+GOOD_RESOLVE+'\r\n'+GOOD_DNS.replace('PASS','P\x80ASS')+'\r\n'+
            GOOD_DNS+'\tprivate\r\n')
        result=subprocess.run([SHELL,'-c',own.guest_filter()],input=source.encode('latin1'),capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        self.assertEqual(result.stdout.decode(),GOOD_ICMP+'\n'+GOOD_DNS+'\n'+GOOD_RESOLVE+'\n')
        for line in result.stdout.decode().splitlines():self.assertTrue(own.valid_line(line))
        for line in (GOOD_DNS.replace('123.123.123.123','999.123.123.123'),GOOD_DNS.replace('from 10.0.2.3','from 1.1.1.1'),GOOD_ICMP.replace('status=0','status=5'),GOOD_ICMP.replace('echo_match=1','echo_match=0')):
            self.assertFalse(own.valid_line(line))
    def test_host_rejects_all_non_grammar_archives_before_any_write(self):
        bad=[('../network-coverage.txt',b'x',tarfile.REGTYPE),('././network-coverage.txt',b'x',tarfile.REGTYPE),
            ('SYSTEM',b'x',tarfile.REGTYPE),('network-coverage.txt',b'',tarfile.SYMTYPE),
            ('network-coverage.txt',b'\0',tarfile.REGTYPE),('network-coverage.txt',b'\xff',tarfile.REGTYPE),
            ('network-coverage.txt',b'x'*(own.MAX_FILE+1),tarfile.REGTYPE)]
        for value in bad:
            with self.assertRaises((ValueError,UnicodeError)):own.export_evidence(archive([value]),self.root/'out')
            self.assertFalse((self.root/'out').exists())
        for lines in ('HKLM private\n','[NET] unknown text\n',GOOD_DNS.replace('id=ABCD','id=12345-OEM-1234567-12345')+'\n'):
            with self.assertRaises(ValueError):own.export_evidence(archive(items(lines)),self.root/'out')
        with self.assertRaises(ValueError):own.export_evidence(archive(items(GOOD_ICMP+'\n')+[items()[0]]),self.root/'out')
        with self.assertRaises(ValueError):own.export_evidence(archive(items())+archive(items()),self.root/'out')
        self.assertFalse((self.root/'out').exists())
    def test_empty_status_and_registry_configuration_are_never_lan_proof(self):
        result=own.export_evidence(archive(items()),self.root/'out')
        self.assertEqual(result['own_network_lines'],0);self.assertFalse(result['installed_runtime_pass'])
        proof=own.correlate(result,self.root/'out',dict(analysis=dict(dora_observed=False)))
        self.assertFalse(any(proof.values()))
    def test_actual_guest_shell_reads_only_allowlist_filters_before_transport_and_hashes_own_driver(self):
        source=self.root/'source';source.mkdir();(source/'USABILITY.TXT').write_text(GOOD_ICMP+'\n'+GOOD_DNS+'\nHKLM secret\n',encoding='ascii')
        driver=ROOT/'tools/nt/usosnet/bin/i386/usosnet4.sys';shutil.copy2(driver,source/'usosnet4.sys')
        runtime=self.root/'runtime';runtime.mkdir();(runtime/'raw').mkdir();(runtime/'export/nt4').mkdir(parents=True)
        runtime_shell='/'+runtime.drive[0].lower()+runtime.as_posix()[2:] if runtime.drive else runtime.as_posix()
        code=own.commands();code=code[code.index('disk=/dev/vda'):code.index('cd /\necho LOWRAM')];code=code.replace('/tmp/',runtime_shell+'/')
        stub='mtype() { case "$3" in ::/USOS/Coverage/USABILITY.TXT) cat "'+(source/'USABILITY.TXT').as_posix()+'";; ::/USOS/NT4/USABILITY.TXT) return 1;; ::/USOS/Coverage/OBSERVER.STATUS) printf \'NT4_OBSERVER_STATUS=TESTNET_DONE\\r\\n\';; ::/WINNT/SYSTEM32/DRIVERS/usosnet4.sys) cat "'+(source/'usosnet4.sys').as_posix()+'";; *) return 1;; esac; }\n'
        script=self.root/'run.sh';script.write_text('set -e\nset -o pipefail\n'+stub+code,encoding='utf-8',newline='\n')
        result=subprocess.run([SHELL,str(script)],capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        self.assertNotIn(b'HKLM secret',result.stdout)
        proof=own.export_evidence(transport.decode_transport(result.stdout.decode()),self.root/'out')
        self.assertTrue(proof['driver_hash_matches']);self.assertEqual(proof['own_network_lines'],2)
        self.assertEqual(proof['status'][own.LOGS[1]],'unavailable')
        self.assertFalse(proof['dhcp_pass']);self.assertFalse(proof['dns_pass'])
        command=own.commands()
        for forbidden in ('SYSTEM32/CONFIG','WINNT.SIF','screen.ppm','mcopy','/POST.LOG'):self.assertNotIn(forbidden,command)
    def test_dora_peer_router_and_dns_match_must_agree_with_own_guest_lines(self):
        evidence=own.export_evidence(archive(items(GOOD_ICMP+'\n'+GOOD_DNS+'\n')),self.root/'out')
        proof=dict(policy=cap.POLICY,first_logon_observed=True,connected=True,mac=cap.MAC,netdev=cap.NETDEV,error=None,
            analysis=dict(dora_observed=True,exchanges=[dict(address='10.0.2.15',server='10.0.2.2',routers=['10.0.2.2'],dns=['10.0.2.3'])]))
        result=own.correlate(evidence,self.root/'out',proof)
        self.assertTrue(result['dhcp_pass'] and result['gateway_pass'] and result['dns_pass'] and result['lan_traffic_matches_lease'])
        for change in (dict(first_logon_observed=False),dict(policy='NT351'),dict(connected=False),dict(error='bad')):
            self.assertFalse(own.correlate(evidence,self.root/'out',dict(proof,**change))['dhcp_pass'])
        proof['analysis']['exchanges'][0]['dns']=['1.1.1.1']
        self.assertFalse(own.correlate(evidence,self.root/'out',proof)['dns_pass'])
        evidence['driver_hash_matches']=False
        self.assertFalse(own.correlate(evidence,self.root/'out',proof)['dhcp_pass'])
    def test_nt4_policy_uses_target_local_gui_hook_and_preserves_default_cd(self):
        source=(HERE/'prepare_stick.py').read_text(encoding='utf-8')
        self.assertIn("observer_kind='nt4-test-run'",source)
        self.assertIn('if args.first_logon_observer and not nt4_network:make_observer_iso',source)
        boot=(HERE/'boot_menu.py').read_text(encoding='utf-8')
        self.assertIn("not in ('9x-runonce','nt4-test-run')",boot)
        self.assertEqual(fixture.NT4_NETWORK_LOGGER_SHA256,own.LOGGER_SHA256)
        self.assertEqual(fixture.NT4_OBSERVER_HELPER_SHA256,own.OBSERVER_HELPER_SHA256)


class FirstLogonCapture(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):self.temp=tempfile.TemporaryDirectory(dir=TMP);self.path=Path(self.temp.name)/'nt4.pcap'
    async def asyncTearDown(self):self.temp.cleanup()
    async def test_pre_logon_and_non_dhcp_are_never_stored_then_real_dora_is_correlated(self):
        receiver=cap.Capture(self.path);port=await receiver.start();reader,writer=await asyncio.open_connection('127.0.0.1',port);await receiver.connected.wait()
        def wire(frames):return b''.join(struct.pack('!I',len(f))+f for f in frames)
        with self.assertRaises(ValueError):receiver.mark_prepared_target()
        writer.write(wire([packet(n) for n in (1,2,3,5)]));await writer.drain()
        # Yield once to the concrete frames' receiver, not VM progress polling.
        await asyncio.sleep(.05)
        receiver.mark_first_logon()
        with self.assertRaises(ValueError):receiver.mark_first_logon()
        writer.write(wire([b'\0'*60]+[packet(n) for n in (1,2,3,5)]));await writer.drain();writer.close();await writer.wait_closed()
        result=await receiver.finish()
        self.assertEqual(result['before_logon_frames'],4);self.assertEqual(result['non_dhcp_frames'],1);self.assertEqual(result['stored_frames'],4)
        self.assertEqual(result['policy'],cap.POLICY);self.assertTrue(result['analysis']['dora_observed']);self.assertNotIn('prepared_target_start_record',result['analysis'])
    async def test_no_actual_logon_and_corrupt_wire_never_prove_dhcp(self):
        receiver=cap.Capture(self.path);port=await receiver.start();reader,writer=await asyncio.open_connection('127.0.0.1',port);await receiver.connected.wait()
        writer.write(struct.pack('!I',2**32-1));await writer.drain();writer.close();await writer.wait_closed();result=await receiver.finish()
        self.assertFalse(result['first_logon_observed']);self.assertFalse(result['analysis']['dora_observed']);self.assertIsNotNone(result['error'])
    async def test_after_cap_receiver_still_drains_but_cannot_fabricate_dora(self):
        receiver=cap.Capture(self.path,max_bytes=24);port=await receiver.start();reader,writer=await asyncio.open_connection('127.0.0.1',port);await receiver.connected.wait();receiver.mark_first_logon()
        for kind in (1,2,3,5):
            frame=packet(kind);writer.write(struct.pack('!I',len(frame))+frame)
        await writer.drain();writer.close();await writer.wait_closed();result=await receiver.finish()
        self.assertEqual(result['received_frames'],4);self.assertEqual(result['discarded_frames'],4);self.assertEqual(result['stored_bytes'],24);self.assertFalse(result['analysis']['dora_observed'])


class Integration(unittest.TestCase):
    def test_runner_collects_after_vm_before_cleanup_and_boundary_is_first_logon(self):
        boot=(HERE/'boot_menu.py').read_text(encoding='utf-8');plan=(HERE/'run_plan.py').read_text(encoding='utf-8')
        self.assertLess(boot.index('network_capture_result=await network_capture.finish('),boot.index('await nt4_own.main('))
        self.assertLess(boot.index('await nt4_own.main('),boot.index('path.unlink()  # These exact per-test files only'))
        self.assertIn('if not first_logon.is_set():',boot);self.assertIn('preflight=True',boot)
        self.assertIn('if capture_nt4:network_capture.mark_first_logon()',boot)
        self.assertIn("if 'start the prepared disk' in line and network_capture and not capture_nt4:",boot)
        for name in ('--nt4-network-evidence','--collect-nt4-success','--capture-nt4-network'):self.assertIn(name,plan)
        for name in ('boot_menu.py','prepare_stick.py','run_plan.py'):compile((HERE/name).read_text(encoding='utf-8'),name,'exec')


if __name__=='__main__':unittest.main()
