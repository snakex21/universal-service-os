"""Reproduce completed R20 guest/network evidence without changing runner flags."""
from pathlib import Path
import hashlib, importlib.util, json, re, struct

ROOT=Path(__file__).resolve().parents[3]
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
CASE=MATRIX/'artifacts/coverage/vm/r20-nt35-network-hid'
OUT=ROOT/'artifacts/nt35-network/r20-guest-evaluation.json'

def main():
    if OUT.exists():raise FileExistsError('Fresh evaluation required')
    result=json.loads((CASE/'result.json').read_text(encoding='utf-8'))
    collection=json.loads((CASE/'nt35-own-evidence/collection.json').read_text(encoding='utf-8'))
    if result.get('qemu_returncode')!=0 or not (CASE/'cleanup.json').is_file():raise ValueError('R20 writer not stopped')
    if collection.get('driver_hash_matches') is not True:raise ValueError('Exact installed own driver not confirmed')
    post=(CASE/'nt35-own-evidence/POST.LOG').read_text(encoding='utf-8')
    guest=(CASE/'nt35-own-evidence/USABILITY.TXT').read_text(encoding='utf-8')
    if '[SYS] Windows 3.50 build 807 platform 2' not in guest:raise ValueError('Expected native Windows version absent')
    first,warm=post.split('WARM',1)
    first_times=[int(v) for v in re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time=(\d+)ms TTL=255',first)]
    warm_times=[int(v) for v in re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time=(\d+)ms TTL=255',warm)]
    if first_times!=[2003,2003] or first.count('Request timed out.')!=1 or warm_times!=[2614,2003,2003]:raise ValueError('Native ping evidence changed')
    required=('USOS Ethernet (usosnet)','52-54-00-55-53-01','DHCP Enabled. . . . . . . . : Yes','10.0.2.15','255.255.255.0','10.0.2.2','10.0.2.3','successfully released')
    if any(x not in post for x in required):raise ValueError('Guest lease/release evidence absent')
    icmp=next(line for line in guest.splitlines() if 'ICMP gateway 10.0.2.2:' in line)
    if 'PASS status=0 replies=1 rtt=1122 ms echo_match=1' not in icmp:raise ValueError('Guest matching echo absent')
    dns=[line for line in guest.splitlines() if 'DNS PASS dns_match=1' in line]
    if len(dns)!=3 or any(x not in '\n'.join(dns) for x in ('UDP DNS 1.1.1.1','UDP DNS 8.8.8.8','TCP DNS 1.1.1.1','id=063C','id=0718','id=7CEA')):raise ValueError('Guest matched DNS answers absent')
    spec=importlib.util.spec_from_file_location('r20_cap',MATRIX/'tools/tests/coverage/nt351_capture.py')
    cap=importlib.util.module_from_spec(spec);spec.loader.exec_module(cap)
    pcap=(CASE/'network.pcap').read_bytes();net=json.loads((CASE/'network.json').read_text(encoding='utf-8'))
    if hashlib.sha256(pcap).hexdigest()!=net['sha256'] or net['error'] is not None or net['capped']:raise ValueError('Incomplete capture')
    strict=cap.analyze_pcap(pcap,net['analysis']['prepared_target_start_record'])
    if strict!=net['analysis'] or strict['dora_observed']:raise ValueError('Historical strict DORA result changed')
    rows=[];at=24;number=0
    while at<len(pcap):
        sec,usec,size,original=struct.unpack_from('<IIII',pcap,at);at+=16;number+=1
        frame=pcap[at:at+size];at+=size;packet=cap.dhcp(frame)
        if packet is not None:rows.append(dict(record=number,**packet))
    renew=[v for v in rows if 101<=v['record']<=104]
    if len(renew)!=4 or [v['kind'] for v in renew]!=[1,2,3,5]:raise ValueError('Expected native renew packets absent')
    d,o,r,a=renew
    if d['xid']!=o['xid'] or r['xid']!=a['xid'] or o['yiaddr']!=r['requested'] or r['requested']!=a['yiaddr'] or a['yiaddr']!='10.0.2.15':raise ValueError('Legacy pairs/address mismatch')
    if any(v['server']!='10.0.2.2' for v in (o,r,a)) or a['routers']!=['10.0.2.2'] or a['dns']!=['10.0.2.3'] or a['lease_seconds']!=86400:raise ValueError('Lease parameters mismatch')
    evidence=dict(scope='Completed fresh NT3.5 Workstation R20 only; manual desktop observation plus guest matched replies',
        case=str(CASE),driver_sha256=collection['driver_readback_sha256'],desktop_observed=True,desktop_image='operator-12.png',
        desktop_image_sha256=hashlib.sha256((CASE/'operator-12.png').read_bytes()).hexdigest(),
        image_reference_correction='v1 referenced endpoint.png, later overwritten by finalcapture with safe-shutdown; operator12 retains Program Manager/Version3.5 and ping output',
        windows_version='3.50 build807',native_shutdown_safe_image='operator-16.png',qemu_returncode=0,
        lan_functional_pass=True,guest_lease=dict(address='10.0.2.15',mask='255.255.255.0',gateway='10.0.2.2',dhcp='10.0.2.2',dns='10.0.2.3',mac=cap.MAC),
        native_ping_first=dict(replies=2,total=3,timeouts=1,timeout_ms=5000,rtt_ms=first_times),
        native_ping_warm=dict(replies=3,total=3,timeout_ms=5000,rtt_ms=warm_times),
        guest_icmp=icmp,guest_dns=dns,guest_http_200='status line "HTTP/1.1 200 OK"' in guest,
        other_network_failures=[line for line in guest.splitlines() if 'TIMEOUT' in line or 'NO REPLY' in line or 'gethostbyname(68k.news): error' in line],
        capture_sha256=net['sha256'],strict_dora_observed=False,lease_exchange_observed=True,
        native_renew_packets=renew,all_dhcp_packets=rows,
        latency_limit='About2s observed, no20ms/fastIRQ proof',usb_pass=False,usb_scope='PS/2 port service remained Start1 in R20; separate R20b required',
        runner_flags_unchanged=True,files_sha256={name:hashlib.sha256((CASE/'nt35-own-evidence'/name).read_bytes()).hexdigest() for name in collection['files']})
    OUT.write_bytes((json.dumps(evidence,indent=2)+'\n').encode('utf-8'))
    print(json.dumps({k:evidence[k] for k in ('desktop_observed','lan_functional_pass','native_ping_first','native_ping_warm','strict_dora_observed','lease_exchange_observed','usb_pass')},indent=2))

if __name__=='__main__':main()
