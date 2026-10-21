"""Read only a guest-filtered network excerpt from an ended private NT4 VM.

The actual first-logon observer is mandatory. No Setup/registry/process dump,
answer, screen or raw driver leaves the evidence guest. Diagnostic evidence,
never desktop/HID/LAN PASS by file presence.
"""
from pathlib import Path
import asyncio
import importlib.util
import io
import json
import re
import tarfile
import zlib

spec=importlib.util.spec_from_file_location('nt4_serial_shell',Path(__file__).with_name('serial_shell.py'))
serial_shell=importlib.util.module_from_spec(spec);spec.loader.exec_module(serial_shell)

DRIVER_SHA256='4f2eb16b71753baab740302025b9e8ba02c38a676670b13626c757bdb3700f8d'
DRIVER_BYTES=21376
LOGGER_SHA256='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7'
LOGS=('network-coverage.txt','network-nt4.txt')
NAMES=(*LOGS,'collection-state.txt','driver-sha256.txt','observer-status.txt')
OBSERVER_HELPER_SHA256='37e7a0f69846d9bab18a718f7d66c3fd937f0f35913d2b0eb22f2d7ce4eae0e9'
OBSERVER_STATES=('ARM_ABSENT','STAGING_FAILED','HOOK_CLEANUP_FAILED','ARM_CLEANUP_FAILED','FIRSTLO_FAILED','READY','NOT_READY','TESTNET_FAILED','TESTNET_DONE')
MAX_FILE=65536
MAX_RAW=1024**2
MAX_LINES=128
MAX_TOTAL=3*MAX_FILE
MAX_TRANSPORT=2*1024**2
HEADER='NT4 own network excerpt; unavailable means read failure, not missing file.'
OCTET=r'(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
IP=OCTET+r'(?:\.'+OCTET+r'){3}'
NUM=r'(?:0|[1-9][0-9]{0,9})'
WHY=r'(?:configured|gateway|fixed|fixed gateway)'
ANSWER=NUM+r' bytes DNS PASS dns_match=1 id=[0-9A-F]{4} question=frogfind\.com A='+IP
FAIL=NUM+r' bytes DNS FAIL dns_match=0 \(peer/ID/question/flags/records\)'
PATTERNS=(
 r'\[NET\] ICMP gateway '+IP+r': (?:PASS|FAIL) status='+NUM+r' replies='+NUM+r' rtt='+NUM+r' ms echo_match=[01]',
 r'\[NET\] ICMP gateway '+IP+r': (?:PASS|FAIL) raw Winsock echo_match=[01] rtt='+NUM+r' ms packets='+NUM,
 r'\[NET\] ICMP gateway: SKIP, no configured gateway; no guessed address',
 r'\[NET\] ICMP gateway '+IP+r': UNAVAILABLE \(no complete ICMP API\)',
 r'\[NET\] ICMP gateway '+IP+r': (?:FAIL, no echo reply, error |create failed error )'+NUM,
 r'\[NET\] gethostbyname\(frogfind\.com\): '+IP+r' after '+NUM+r' ms',
 r'\[NET\] gethostbyname\(frogfind\.com\): FAILED error -?'+NUM+r' after '+NUM+r' ms',
 r'\[NET\] UDP DNS '+IP+r' \('+WHY+r'\): reply after '+NUM+r' ms from '+IP+r':'+NUM+r': (?:'+ANSWER+'|'+FAIL+')',
 r'\[NET\] UDP DNS '+IP+r' \('+WHY+r'\): (?:socket error -?'+NUM+r'|sendto error -?'+NUM+r'|recvfrom error -?'+NUM+r' after '+NUM+r' ms|query '+NUM+r' bytes sent, NO REPLY in 3000 ms)',
 r'\[NET\] TCP DNS '+IP+r':53: connected in '+NUM+r' ms, reply: (?:'+ANSWER+'|'+FAIL+')',
 r'\[NET\] WSOCK32\.DLL not loadable \(no TCP/IP installed\?\): tests skipped',
 r'\[NET\] WSAStartup error -?'+NUM,
 r'\[NET\] IPHLPAPI\.DLL: not loadable \(error '+NUM+r'\)',
)
MATCHERS=tuple(re.compile('^'+p+'$') for p in PATTERNS)
KEY=re.compile(r'[A-Za-z0-9]{5}(?:-[A-Za-z0-9]{5}){4}|[0-9]{5}-OEM-[0-9]{7}-[0-9]{5}|[0-9]{3}-[0-9]{7}',re.I)


def module(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


def validate(metadata,work,assets,output,collection,root,first_logon=False,preflight=False):
    if metadata.get('private_profile') is not True or metadata.get('folder')!='Windows NT 4.0':
        raise ValueError('Only explicitly private NT4 success fixtures are allowed')
    if metadata.get('usability_logger_sha256')!=LOGGER_SHA256 or metadata.get('observer_kind')!='nt4-test-run':
        raise ValueError('Exact strict DNS logger and NT4 target-local test observer required')
    token=metadata.get('observer_token','')
    if not isinstance(token,str) or not re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',token):
        raise ValueError('Actual first-logon observer required')
    if metadata.get('nt4_observer_helper_sha256')!=OBSERVER_HELPER_SHA256:raise ValueError('Exact own NT4 GUI observer required')
    if metadata.get('nt4_network_evidence') is not True:raise ValueError('Explicit NT4 network policy required')
    if not preflight and first_logon is not True:raise ValueError('Observed actual first logon required; prepared target is insufficient')
    if not work.resolve().is_relative_to(collection.resolve()/'_vm') or work.resolve()==collection.resolve()/'_vm':
        raise ValueError('Only owned disposable target')
    if not assets.resolve().is_relative_to(collection.resolve()/'_assets') or assets.resolve()==collection.resolve()/'_assets':
        raise ValueError('Explicit frozen owned cache required')
    if not output.resolve().is_relative_to(root.resolve()/'artifacts/coverage'):
        raise ValueError('Evidence must remain in owned artifacts')
    if not preflight and not (work/'target.qcow2').is_file():raise FileNotFoundError('Stopped target absent')


def valid_line(line):
    if len(line)>512 or KEY.search(line) or not any(p.fullmatch(line) for p in MATCHERS):return False
    if line.startswith('[NET] ICMP gateway ') and ': PASS ' in line:
        if 'raw Winsock' in line:
            if not re.search(r'echo_match=1 rtt=[0-9]+ ms packets=[1-9][0-9]*$',line):return False
        elif not re.search(r': PASS status=0 replies=[1-9][0-9]* rtt=[0-9]+ ms echo_match=1$',line):return False
    if line.startswith('[NET] UDP DNS ') and 'DNS PASS' in line:
        match=re.match(r'\[NET\] UDP DNS ([0-9.]+) .* from ([0-9.]+):([0-9]+):',line)
        if not match or match[1]!=match[2] or match[3]!='53':return False
    return True


def guest_filter():
    patterns=' ||\n'.join('line ~ /^'+p.replace('(?:','(').replace('/','\\/')+'$/' for p in PATTERNS)
    # ASCII is checked on whole original lines; dropping a non-ASCII byte must
    # never turn a malformed/private line into an accepted result.
    return "LC_ALL=C sed -E 's/[[:alnum:]]{5}(-[[:alnum:]]{5}){4}/[key omitted]/g; s/[0-9]{5}-[Oo][Ee][Mm]-[0-9]{7}-[0-9]{5}/[key omitted]/g; s/[0-9]{3}-[0-9]{7}/[key omitted]/g' | LC_ALL=C awk '"+r'''
{sub(/\r$/, ""); line=$0
 if (length(line)>512 || line ~ /[^ -~]/) next
 if (PATTERNS) {
     if (++count>128) exit 42
     print line
 }
}'''.replace('PATTERNS',patterns)+"'"


def commands():
    reads=[]
    for source,name in (('/USOS/Coverage/USABILITY.TXT',LOGS[0]),('/USOS/NT4/USABILITY.TXT',LOGS[1])):
        reads.append('readnet "'+source+'" '+name)
    return r'''/bin/busybox --install -s /bin
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -e
set -o pipefail
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
for m in virtio_pci virtio_blk vfat fat; do modprobe "$m"; done
mdev -s
mkdir -p /tmp/raw /tmp/export/nt4
disk=/dev/vda@@32256
printf '%s\n' 'HEADER' >/tmp/export/nt4/collection-state.txt
readnet() {
 rm -f /tmp/raw/log "/tmp/export/nt4/$2"
 status=unavailable; ok=no
 if MTOOLS_SKIP_CHECK=1 mtype -i "$disk" "::$1" 2>/dev/null | dd bs=4096 count=257 of=/tmp/raw/log 2>/dev/null; then ok=yes; fi
 if [ "$(wc -c </tmp/raw/log)" -gt 1048576 ]; then status=too-large
 elif [ "$ok" = yes ]; then
  if cat /tmp/raw/log | FILTER >"/tmp/export/nt4/$2"; then
   if [ "$(wc -c <"/tmp/export/nt4/$2")" -gt 65536 ]; then status=too-large
   elif [ -s "/tmp/export/nt4/$2" ]; then status=exported
   else status=empty; fi
  else status=too-large; fi
 fi
 case "$status" in exported|empty) :;; *) rm -f "/tmp/export/nt4/$2";; esac
 rm -f /tmp/raw/log
 printf '%s=%s\n' "$2" "$status" >>/tmp/export/nt4/collection-state.txt
}
READS
status=unavailable
if MTOOLS_SKIP_CHECK=1 mtype -i "$disk" ::/WINNT/SYSTEM32/DRIVERS/usosnet4.sys 2>/dev/null | dd bs=4096 count=7 of=/tmp/raw/driver 2>/dev/null; then
 if [ "$(wc -c </tmp/raw/driver)" -eq 21376 ]; then
  digest=$(sha256sum /tmp/raw/driver); digest=${digest%% *}
  if [ "$digest" = DRIVER_SHA ]; then
   printf '%s\n' "$digest" >/tmp/export/nt4/driver-sha256.txt
   status=matched
  else status=mismatch; fi
 else status=mismatch; fi
fi
rm -f /tmp/raw/driver
printf 'driver=%s\n' "$status" >>/tmp/export/nt4/collection-state.txt
status=unavailable
if MTOOLS_SKIP_CHECK=1 mtype -i "$disk" ::/USOS/Coverage/OBSERVER.STATUS 2>/dev/null | dd bs=256 count=1 of=/tmp/raw/status 2>/dev/null; then
 if LC_ALL=C awk 'BEGIN { ok=1 } { sub(/\r$/, ""); if(NR!=1 || $0 !~ /^NT4_OBSERVER_STATUS=(OBSERVER_STATES)$/) ok=0; text=$0 } END { if(ok && NR==1) print text; else exit 1 }' /tmp/raw/status >/tmp/export/nt4/observer-status.txt; then status=exported; fi
fi
[ "$status" = exported ] || rm -f /tmp/export/nt4/observer-status.txt
rm -f /tmp/raw/status
printf 'observer=%s\n' "$status" >>/tmp/export/nt4/collection-state.txt
cd /tmp/export/nt4
tar -czf /tmp/evidence.tgz ./*.txt
echo COVERAGE_EVIDENCE_BEGIN
base64 /tmp/evidence.tgz
echo COVERAGE_EVIDENCE_END
cd /
echo LOWRAM-RESULT=PASS
poweroff -f
'''.replace('HEADER',HEADER).replace('FILTER',guest_filter()).replace('READS','\n'.join(reads)).replace('DRIVER_SHA',DRIVER_SHA256).replace('OBSERVER_STATES','|'.join(OBSERVER_STATES))


def export_evidence(payload,output):
    inflater=zlib.decompressobj(16+zlib.MAX_WBITS)
    plain=inflater.decompress(payload,MAX_TOTAL+65537)
    if len(plain)>MAX_TOTAL+65536 or not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
        raise ValueError('Invalid or multiple bounded gzip streams')
    records={};total=0
    with tarfile.open(fileobj=io.BytesIO(plain),mode='r:') as archive:
        for member in archive:
            name=member.name.removeprefix('./')
            if not member.isfile() or name not in NAMES or name in records or not 0<=member.size<=MAX_FILE:
                raise ValueError('Unexpected own NT4 evidence entry')
            total+=member.size
            if total>MAX_TOTAL:raise ValueError('Own NT4 evidence total limit')
            data=archive.extractfile(member).read(MAX_FILE+1)
            if len(data)!=member.size:raise ValueError('Truncated own NT4 evidence')
            text=data.decode('ascii')
            if re.search(r'[^\n\x20-\x7e]',text) or KEY.search(text):raise ValueError('Unfiltered private evidence rejected')
            records[name]=text
        if len(plain)%512 or any(plain[archive.offset:]):raise ValueError('Trailing tar data rejected')
    lines=records.get('collection-state.txt','').splitlines()
    if not lines or lines[0]!=HEADER:raise ValueError('Missing own NT4 status')
    states={}
    for line in lines[1:]:
        pair=line.split('=')
        if len(pair)!=2 or pair[0] not in (*LOGS,'driver','observer') or pair[0] in states:raise ValueError('Invalid own NT4 status')
        allowed=({'matched','mismatch','unavailable'} if pair[0]=='driver' else {'exported','unavailable'} if pair[0]=='observer' else {'exported','empty','unavailable','too-large'})
        if pair[1] not in allowed:raise ValueError('Invalid own NT4 status value')
        states[pair[0]]=pair[1]
    if set(states)!=set((*LOGS,'driver','observer')):raise ValueError('Incomplete own NT4 status')
    for name in LOGS:
        status=states[name]
        if status in ('exported','empty'):
            if name not in records or bool(records[name])!=(status=='exported'):raise ValueError('Evidence/status disagreement')
            content=records[name].splitlines()
            if len(content)>MAX_LINES or any(not valid_line(line) for line in content):raise ValueError('Unexpected network grammar')
        elif name in records:raise ValueError('Unexpected unread log')
    if states['driver']=='matched':
        if records.get('driver-sha256.txt')!=DRIVER_SHA256+'\n':raise ValueError('Own driver hash mismatch')
    elif 'driver-sha256.txt' in records:raise ValueError('Unexpected own driver hash')
    observer=records.get('observer-status.txt')
    if states['observer']=='exported':
        if observer not in {'NT4_OBSERVER_STATUS='+v+'\n' for v in OBSERVER_STATES}:raise ValueError('Invalid observer status')
        observer=observer.strip().split('=',1)[1]
    elif observer is not None:raise ValueError('Unexpected observer status')
    output.mkdir(parents=True,exist_ok=False)
    for name,text in records.items():(output/name).write_text(text,encoding='utf-8',newline='\n')
    return dict(files=sorted(records),status=states,observer_status=observer,driver_hash_matches=states['driver']=='matched',
        own_network_lines=sum(len(records.get(n,'').splitlines()) for n in LOGS),
        installed_runtime_pass=False,dhcp_pass=False,gateway_pass=False,dns_pass=False,
        scope='Guest-filtered own network excerpt only; registry/configuration and file presence are not connectivity PASS')


def correlate(evidence,directory,capture):
    # Only a completed explicitly NT4 first-logon-bound capture can supply DHCP.
    proof=capture if isinstance(capture,dict) else {}
    if (proof.get('policy')!='NT4_DHCP_ONLY_AFTER_ACTUAL_FIRST_LOGON' or proof.get('error') or
        proof.get('first_logon_observed') is not True or proof.get('connected') is not True or
        proof.get('mac')!='52:54:00:55:53:01' or proof.get('netdev')!='usabilitynet'):
        return dict(dhcp_pass=False,gateway_pass=False,dns_pass=False)
    analysis=proof.get('analysis',{});exchanges=analysis.get('exchanges',[]) if analysis.get('dora_observed') else []
    if not evidence['driver_hash_matches'] or evidence.get('observer_status')!='TESTNET_DONE':exchanges=[]
    lines=[line for n in LOGS for line in ((directory/n).read_text(encoding='utf-8').splitlines() if (directory/n).exists() else [])]
    pairs=[]
    for lease in exchanges:
        routers=lease.get('routers',[]);dns=lease.get('dns',[])
        gateway=any(any(line.startswith('[NET] ICMP gateway '+ip+': PASS ') and 'echo_match=1' in line for line in lines) for ip in routers)
        matched=any(any(re.fullmatch(r'\[NET\] UDP DNS '+re.escape(ip)+r' \((?:configured|gateway)\): reply after '+NUM+r' ms from '+re.escape(ip)+r':53: '+ANSWER,line) for line in lines) for ip in dns)
        pairs.append(dict(address=lease.get('address'),server=lease.get('server'),routers=routers,dns=dns,gateway_match=gateway,dns_match=matched))
    return dict(dhcp_pass=bool(pairs),gateway_pass=any(p['gateway_match'] for p in pairs),dns_pass=any(p['dns_match'] for p in pairs),
        lan_traffic_matches_lease=any(p['gateway_match'] and p['dns_match'] for p in pairs),lease_matches=pairs)


async def main(args):
    fixture=module('nt4_success_fixture','prepare_stick.py');transport=module('nt4_success_transport','collect_guest_logs.py')
    root=Path(__file__).resolve().parents[3];work=args.fixture.resolve()
    metadata=json.loads((work/'fixture.json').read_text(encoding='utf-8'))
    validate(metadata,work,args.assets,args.out,fixture.COLLECTION,root,first_logon=args.first_logon_observed)
    if args.out.exists():raise FileExistsError('Refusing existing evidence')
    fixture.check_resources(work,1024)
    result=await fixture.load_bootstrap().run_case(args.qemu,args.assets/'zig-out/micro-linux/vmlinuz-virt',
        args.assets/'zig-out/micro-linux/initramfs-usos',work/'read-nt4-network',1024,'qemu64',180,
        ['-drive',f'file={(work/"target.qcow2").as_posix()},format=qcow2,if=virtio,readonly=on'],commands=serial_shell.wrap(commands()),suffix='-nt4-network')
    if result['result']!='PASS':raise RuntimeError('Read-only own network collector failed')
    serial=Path(result['directory'])/'serial.log'
    if serial.stat().st_size>MAX_TRANSPORT:raise ValueError('Own evidence transport limit')
    evidence=export_evidence(transport.decode_transport(serial.read_text(encoding='utf-8',errors='strict')),args.out)
    evidence.update(correlate(evidence,args.out,args.network_capture))
    evidence.update(first_logon_observed=True,collector_result=result,logger_sha256=LOGGER_SHA256)
    (args.out/'collection.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('NT4_OWN_NETWORK_COLLECTION_COMPLETE; desktop and HID require separate assessment',flush=True)
