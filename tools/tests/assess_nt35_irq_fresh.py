"""Assess the completed, visually reviewed fresh canonical-IRQ NT35 case."""
from pathlib import Path
import hashlib,importlib.util,json,re,struct,subprocess
ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'artifacts/coverage/nt35-irq-fresh01'
CASE=ROOT/'artifacts/coverage/vm/nt35-irq-fresh01'
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-fresh01')
R20=ROOT.parent/'macierz-windows/artifacts/coverage/vm/r20-nt35-network-hid'
DRIVER='d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
def sha(data):return hashlib.sha256(data).hexdigest()
def file_sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def norm(argv,tag):
    return [re.sub(r'port=\d+', 'port=<LOCAL>',re.sub(r'127\.0\.0\.1:\d+', '127.0.0.1:<LOCAL>',arg.replace(tag,'<CASE>'))) for arg in argv]
def main():
    output=HERE/'guest-evaluation.json'
    if output.exists():raise FileExistsError('Preserve completed assessments')
    result=json.loads((CASE/'result.json').read_text(encoding='utf-8'))
    collection=json.loads((CASE/'nt35-own-evidence/collection.json').read_text(encoding='utf-8'))
    readback=json.loads((HERE/'stopped-readback.json').read_text(encoding='utf-8'))
    process=json.loads((HERE/'process-exit.json').read_text(encoding='utf-8'))
    if result['qemu_returncode']!=0 or process['returncode']!=0 or result['error'] is not None or result['product_failure'] is not None:
        raise ValueError('Successful writer completion required')
    if collection['missing'] or not collection['driver_hash_matches'] or collection['driver_readback_sha256']!=DRIVER or readback['driver_sha256']!=DRIVER:
        raise ValueError('Two actual stopped SYS readbacks required')
    native=(HERE/'FRESHNET.LOG').read_text(encoding='utf-8')
    log=(CASE/'nt35-own-evidence/USABILITY.TXT').read_text(encoding='utf-8')
    snapshots=re.findall(r'=== USOSLOG .*?=== end of snapshot #[^\n]+',log,re.S)
    if len(snapshots)!=1:raise ValueError('Exactly one fresh completed explicit logger snapshot required')
    log=snapshots[0]
    if 'Windows 3.50 build 807' not in log or log.count('DNS PASS dns_match=1')!=3:raise ValueError('Exact guest/version/strict DNS evidence absent')
    if len(re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time<10ms TTL=255',native))!=3:raise ValueError('Three native fast replies absent')
    required=('IP address 10.0.2.15 successfully released','DHCP Enabled. . . . . . . . : Yes',
              'DNS Servers . . . . . . . . : 10.0.2.3','Default Gateway . . . . . . : 10.0.2.2',
              '\n   Workstation\n')
    if any(text not in native for text in required):raise ValueError('Native DHCP/services evidence absent')
    icmp=re.search(r'ICMP gateway 10\.0\.2\.2: PASS status=0 replies=1 rtt=(\d+) ms echo_match=1',log)
    dns=re.findall(r'(UDP DNS [^\n]+|TCP DNS [^\n]+)DNS PASS dns_match=1([^\n]*)',log)
    if not icmp or 'status line "HTTP/1.1 200 OK"' not in log:raise ValueError('Strict ICMP/HTTP evidence absent')
    cmd=json.loads((CASE/'command.json').read_text(encoding='utf-8'))
    # R20 supplied USB HID in addition to hardware i8042. This fresh baseline
    # explicitly uses PS/2; do not claim byte-identical outer QEMU argv or USB.
    for option,value in (('-machine','q35'),('-cpu','EPYC-Rome'),('-smp','2'),('-m','2048')):
        if cmd.count(option)!=1 or cmd[cmd.index(option)+1]!=value:raise ValueError('Unexpected fresh topology '+option)
    if cmd.count('igb,netdev=usabilitynet,mac=52:54:00:55:53:01')!=1:raise ValueError('Exact sole igb MAC required')
    # Preserve strict same-XID DORA as false when original NT35 switches XID.
    spec=importlib.util.spec_from_file_location('fresh_capture',HERE/'harness/nt35_capture.py')
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
    if len(renewals)<1 or len(pairs)<4:raise ValueError('Correlated DHCP lease and four ICMP pairs required')
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
    policy_pass=all(services[name].get('start')==4 for name in ('Browser','LanmanServer'))
    native_server_running='\n   Server\n' in native
    sharing_result='PASS' if policy_pass and not native_server_running and '\n   Computer Browser\n' not in native else 'FAIL'
    native_services=re.findall(r'^   (.+)$',native.split('These Windows NT services are started:',1)[1].split('The command completed',1)[0],re.M)
    retained={p.name:dict(bytes=p.stat().st_size,sha256=file_sha(p)) for p in sorted(WORK.glob('*-retained.*'))}
    assessment=dict(case=WORK.name,scope='Exact QEMU NT35 Workstation EN only; no Server SKU/physical/SMP/full release claim',
        fresh_normal_usos_install=True,new_blank_target_at_start=True,standalone_target_no_backing=True,
        fresh_install_desktop='PASS',fresh_corrected_irq_lan='PASS',client_no_sharing_policy=sharing_result,
        native_input_route='Explicit PS/2 baseline; separate d94 USB proof nt35-irq-usb01; no USB replug/MSC retest',
        driver_sha256=DRIVER,driver_bytes=16384,driver_verified_by_independent_readbacks=2,
        initrd_sha256=cache['initrd_sha256'],newc_changed_entries=2,newc_unchanged_entries=835,
        old_frozen_cache_unchanged_after_runtime=True,other_new_cache_files_identical_after_runtime=True,
        input_changed_from_r20='PS/2 enabled; hardware i8042 remains present',
        native_dhcp_release_renew=True,address='10.0.2.15',mask='255.255.255.0',gateway='10.0.2.2',dns='10.0.2.3',
        native_ping_replies=3,native_ping_rtt_upper_bound_ms=10,strict_guest_icmp_rtt_ms=int(icmp[1]),
        strict_guest_dns=dns,native_resolution=True,http_68k='HTTP/1.1 200 OK',http_connect_ms=int(re.search(r'HTTP GET http://68k.news/[^\n]*\n\[NET\]   connected in (\d+) ms',log)[1]),
        strict_same_xid_dora=strict['dora_observed'],correlated_lease_exchanges_two_xids=len(renewals),
        native_running_services=native_services,
        stopped_service_policy=policy,policy_modified_this_case=False,
        retained_failures=[line for line in log.splitlines() if any(token in line for token in ('TIMEOUT','NO REPLY','FAIL'))],historical_r20_first_2_of_3_and_2s_warm_results_unchanged=True,
        desktop_image_sha256=file_sha(CASE/'endpoint.png'),native_ping_image='operator-09.png',native_services_image='operator-10.png',
        native_dhcp_image='operator-11.png',safe_shutdown_image='operator-16.png',native_safe_shutdown=True,qemu_returncode=0,process_returncode=0,
        target_sha256=readback['target_sha256'],retained_images=retained,
        retained_image_bytes=sum(row['bytes'] for row in retained.values()),
        no_ms_binary_or_hive_export=True,no_physical_writes=True,no_progress_polling=True,
        qualification='Fresh normal installation and native fast LAN with d94; unchanged Client/noSharing assessed separately')
    output.write_bytes((json.dumps(assessment,indent=2)+'\n').encode('utf-8'))
    print(json.dumps({k:assessment[k] for k in ('fresh_install_desktop','fresh_corrected_irq_lan','client_no_sharing_policy','driver_sha256','strict_guest_icmp_rtt_ms','strict_same_xid_dora','retained_image_bytes')},indent=2))

if __name__=='__main__':main()
