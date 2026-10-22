"""Assess the completed, visually reviewed fresh canonical-IRQ NT351 case."""
from pathlib import Path
import hashlib,importlib.util,json,re,struct,subprocess
ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'artifacts/coverage/nt351-irq-fresh01'
CASE=ROOT/'artifacts/coverage/vm/nt351-irq-fresh01'
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt351-irq-fresh01')
R22=ROOT.parent/'macierz-windows/artifacts/coverage/vm/r22-nt351-fresh-network-ps2'
DRIVER='f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf'
def sha(data):return hashlib.sha256(data).hexdigest()
def file_sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def norm(argv,tag):
    return [re.sub(r'port=\d+', 'port=<LOCAL>',re.sub(r'127\.0\.0\.1:\d+', '127.0.0.1:<LOCAL>',arg.replace(tag,'<CASE>'))) for arg in argv]
def main():
    output=HERE/'guest-evaluation.json'
    if output.exists():raise FileExistsError('Preserve completed assessments')
    result=json.loads((CASE/'result.json').read_text(encoding='utf-8'))
    collection=json.loads((CASE/'nt351-own-evidence/collection.json').read_text(encoding='utf-8'))
    readback=json.loads((HERE/'stopped-readback.json').read_text(encoding='utf-8'))
    process=json.loads((HERE/'process-exit.json').read_text(encoding='utf-8'))
    if result['qemu_returncode']!=0 or process['returncode']!=0 or result['error'] is not None or result['product_failure'] is not None:
        raise ValueError('Successful writer completion required')
    if collection['missing'] or not collection['driver_hash_matches'] or collection['driver_readback_sha256']!=DRIVER or readback['driver_sha256']!=DRIVER:
        raise ValueError('Two actual stopped SYS readbacks required')
    native=(HERE/'FRESHNET.LOG').read_text(encoding='utf-8')
    log=(CASE/'nt351-own-evidence/USABILITY.TXT').read_text(encoding='utf-8')
    snapshots=re.findall(r'=== USOSLOG .*?=== end of snapshot #[^\n]+',log,re.S)
    if len(snapshots)!=1:raise ValueError('Exactly one fresh completed explicit logger snapshot required')
    log=snapshots[0]
    if 'Windows 3.51 build 1057' not in log or log.count('DNS PASS dns_match=1')!=3:raise ValueError('Exact guest/version/strict DNS evidence absent')
    if len(re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time<10ms TTL=255',native))!=3:raise ValueError('Three native fast replies absent')
    required=('IP address 10.0.2.15 successfully released','DHCP Enabled. . . . . . . . : Yes',
              'DNS Servers . . . . . . . . : 10.0.2.3','Default Gateway . . . . . . : 10.0.2.2',
              'Computer Browser','\n   Server\n','\n   Workstation\n')
    if any(text not in native for text in required):raise ValueError('Native DHCP/services evidence absent')
    icmp=re.search(r'ICMP gateway 10\.0\.2\.2: PASS status=0 replies=1 rtt=(\d+) ms echo_match=1',log)
    dns=re.findall(r'(UDP DNS [^\n]+|TCP DNS [^\n]+)DNS PASS dns_match=1([^\n]*)',log)
    if not icmp or 'status line "HTTP/1.1 200 OK"' not in log:raise ValueError('Strict ICMP/HTTP evidence absent')
    cmd=json.loads((CASE/'command.json').read_text(encoding='utf-8'))
    old_cmd=json.loads((R22/'command.json').read_text(encoding='utf-8'))
    before=norm(old_cmd,'r22-nt351-fresh-network-ps2');after=norm(cmd,'nt351-irq-fresh01')
    if before!=after:raise ValueError('Functional outer QEMU argv differs from R22')
    (HERE/'command-comparison.json').write_bytes((json.dumps(dict(r22_argv_sha256=file_sha(R22/'command.json'),
        argv_sha256=file_sha(CASE/'command.json'),normalized_argv=after,identical=True,
        normalization='Exact case tag and localhost QMP/mirror ephemeral ports only'),indent=2)+'\n').encode())
    # Preserve strict same-XID DORA as false when original NT351 switches XID.
    spec=importlib.util.spec_from_file_location('fresh_capture',HERE/'harness/nt351_capture.py')
    cap=importlib.util.module_from_spec(spec);spec.loader.exec_module(cap)
    data=(CASE/'network.pcap').read_bytes()
    if sha(data)!=result['network_capture']['sha256'] or result['network_capture']['capped']:raise ValueError('Completed uncapped pinned capture required')
    start=result['network_capture']['analysis']['prepared_target_start_record']
    strict=cap.analyze_pcap(data,start);offset=24;record=0;leases=[];echo=[]
    while offset<len(data):
        sec,usec,size,original=struct.unpack_from('<IIII',data,offset);offset+=16;record+=1
        frame=data[offset:offset+size];offset+=size
        if record<start:continue
        packet=cap.dhcp(frame)
        if packet:leases.append(dict(record=record,decoded=packet))
        if len(frame)<42 or frame[12:14]!=b'\x08\x00':continue
        ip=frame[14:];ihl=(ip[0]&15)*4;length=struct.unpack_from('!H',ip,2)[0]
        if ip[0]>>4!=4 or ihl<20 or length>len(ip) or length<ihl+8 or ip[9]!=1:continue
        if cap.checksum(ip[:ihl]) or struct.unpack_from('!H',ip,6)[0]&0x3fff:continue
        body=ip[ihl:length]
        if body[0] not in (0,8) or body[1]!=0 or cap.checksum(body):continue
        mac=bytes.fromhex(cap.MAC.replace(':',''))
        if (body[0]==8 and frame[6:12]!=mac) or (body[0]==0 and frame[:6]!=mac):continue
        echo.append(dict(record=record,time=sec+usec/1e6,type=body[0],source=ip[12:16].hex(),destination=ip[16:20].hex(),identity=sha(body[4:])))
    pairs=[]
    for request in echo:
        if request['type']!=8:continue
        replies=[row for row in echo if row['type']==0 and row['record']>request['record'] and row['identity']==request['identity'] and row['source']==request['destination'] and row['destination']==request['source']]
        if replies:pairs.append(dict(request_record=request['record'],reply_records=[row['record'] for row in replies],wire_delays_ms=[round((row['time']-request['time'])*1000,3) for row in replies]))
    renewals=[]
    for offer in leases:
        p=offer['decoded']
        if p['kind']!=2:continue
        discover=next((x for x in leases if x['record']<offer['record'] and x['decoded']['kind']==1 and x['decoded']['xid']==p['xid']),None)
        request=next((x for x in leases if x['record']>offer['record'] and x['decoded']['kind']==3 and x['decoded']['requested']==p['yiaddr'] and x['decoded']['server']==p['server']),None)
        ack=next((x for x in leases if request and x['record']>request['record'] and x['decoded']['kind']==5 and x['decoded']['xid']==request['decoded']['xid'] and x['decoded']['yiaddr']==p['yiaddr'] and x['decoded']['server']==p['server']),None)
        if discover and request and ack:renewals.append(dict(records=[discover['record'],offer['record'],request['record'],ack['record']],
            discover_offer_xid=p['xid'],request_ack_xid=request['decoded']['xid'],lease=ack['decoded']))
    if len(renewals)!=2 or len(pairs)!=4:raise ValueError('Fresh plus renewed leases/four ICMP pairs absent')
    (HERE/'pcap-completed-analysis.json').write_bytes((json.dumps(dict(strict_dora=strict,dhcp=leases,
        correlated_exchanges_two_xids=renewals,icmp_pairs=pairs,
        scope='Pinned MAC after prepared-target boundary; native guest supplies OS/timing attribution'),indent=2)+'\n').encode())
    cache=json.loads((HERE/'cache-manifest.json').read_text(encoding='utf-8'))
    for relative,info in cache['source_cache_files'].items():
        if file_sha(Path(cache['base'])/relative)!=info['sha256']:raise ValueError('Old frozen cache changed')
        expected=cache['initrd_sha256'] if relative=='zig-out/micro-linux/initramfs-usos' else info['sha256']
        if file_sha(Path(cache['output'])/relative)!=expected:raise ValueError('New private cache changed')
    qimg=ROOT.parent/'bety-instalacja/tools/qemu/qemu-img.exe'
    image=json.loads(subprocess.check_output([str(qimg),'info','--output=json',str(WORK/'target-retained.qcow2')],text=True))
    if image['virtual-size']!=4*1024**3 or image['format']!='qcow2' or 'backing-filename' in image or image.get('dirty-flag'):
        raise ValueError('Fresh standalone clean 4GiB target required')
    (HERE/'target-info.json').write_bytes((json.dumps(image,indent=2)+'\n').encode())
    policy=readback['policy'];services=policy['services'][str(policy['selected']['current'])]
    if services['Browser']['start']!=2 or services['LanmanServer']['start']!=2:raise ValueError('Preserve observed policy failure precisely')
    retained={p.name:dict(bytes=p.stat().st_size,sha256=file_sha(p)) for p in sorted(WORK.glob('*-retained.*'))}
    assessment=dict(case=WORK.name,scope='Exact QEMU NT351 Workstation EN only; no Server/physical/SMP/full release claim',
        fresh_normal_usos_install=True,new_blank_target_at_start=True,standalone_target_no_backing=True,
        fresh_install_desktop='PASS',fresh_corrected_irq_lan='PASS',client_no_sharing_policy='FAIL',
        native_input_route='PS/2, same R22 allowance; no USB replug/MSC retest',
        driver_sha256=DRIVER,driver_bytes=17024,driver_verified_by_independent_readbacks=2,
        initrd_sha256=cache['initrd_sha256'],newc_changed_entries=2,newc_unchanged_entries=830,
        old_frozen_cache_unchanged_after_runtime=True,other_new_cache_files_identical_after_runtime=True,
        outer_qemu_argv_identical_after_case_path_and_local_port_normalization=True,
        native_dhcp_release_renew=True,address='10.0.2.15',mask='255.255.255.0',gateway='10.0.2.2',dns='10.0.2.3',
        native_ping_replies=3,native_ping_rtt_upper_bound_ms=10,strict_guest_icmp_rtt_ms=int(icmp[1]),
        strict_guest_dns=dns,native_resolution=True,http_68k='HTTP/1.1 200 OK',http_connect_ms=130,
        strict_same_xid_dora=strict['dora_observed'],correlated_lease_exchanges_two_xids=2,
        native_running_services=['Computer Browser','DHCP Client','EventLog','Messenger','OLE','Server','Spooler','TCP/IP NetBIOS Helper','Workstation'],
        stopped_service_policy=policy,policy_modified_this_case=False,
        retained_failures=['Frogfind HTTP connect timeout4005ms','Gateway UDP53 no reply3000ms','Gateway TCP80 connect timeout4006ms',
            'Historical R22 about2s replies and R25 absent canonical IMS/IRQ remain failures'],
        desktop_image_sha256=file_sha(CASE/'endpoint.png'),native_ping_image='operator-09.png',native_services_image='operator-10.png',
        native_dhcp_image='operator-11.png',safe_shutdown_image='operator-16.png',native_safe_shutdown=True,qemu_returncode=0,process_returncode=0,
        target_sha256=readback['target_sha256'],retained_images=retained,
        retained_image_bytes=sum(row['bytes'] for row in retained.values()),
        no_ms_binary_or_hive_export=True,no_physical_writes=True,no_progress_polling=True,
        qualification='Fresh normal installation and native fast LAN with f579; Client/noSharing still fails separately')
    output.write_bytes((json.dumps(assessment,indent=2)+'\n').encode('utf-8'))
    print(json.dumps({k:assessment[k] for k in ('fresh_install_desktop','fresh_corrected_irq_lan','client_no_sharing_policy','driver_sha256','strict_guest_icmp_rtt_ms','strict_same_xid_dora','retained_image_bytes')},indent=2))

if __name__=='__main__':main()
