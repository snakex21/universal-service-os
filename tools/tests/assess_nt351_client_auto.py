"""Assess only completed, explicitly reviewed fresh351 AUTO client evidence."""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TAG = 'nt351-client-auto-fresh01'
HERE = ROOT/'artifacts/coverage'/TAG
CASE = ROOT/'artifacts/coverage/vm'/TAG
WORK = Path(r'G:\USOS-Kolekcja\_vm')/TAG
OLD = ROOT.parent/'nt351-fresh/artifacts/coverage/vm/nt351-irq-fresh01'
DRIVER = 'f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf'
POST = '615f6d6b49b3c53df62603b804195f80c0d431dad4b2d88145ece1ad166ed48b'


def file_sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def native_field(text, label, value):
    return bool(re.search(r'^\s*'+re.escape(label)+r'[ .]+:[ \t]*'+
                          re.escape(value)+r'[ \t\r]*$',text,re.M))


def normalized(argv, tag):
    return [re.sub(r'port=\d+','port=<LOCAL>',re.sub(r'127\.0\.0\.1:\d+',
            '127.0.0.1:<LOCAL>',value.replace(tag,'<CASE>'))) for value in argv]


def main():
    output=HERE/'guest-evaluation.json'
    require(not output.exists(),'Preserve completed assessment')
    result=read(CASE/'result.json'); parent=read(HERE/'process-exit.json')
    collection=read(CASE/'nt351-own-evidence/collection.json')
    stopped=read(HERE/'stopped-readback.json'); cache=read(HERE/'cache-manifest.json')
    require(parent['returncode']==0 and result['qemu_returncode']==0 and
            result['error'] is None and result['product_failure'] is None,'Actual completed writer0')
    require(collection['collector_result']['exit_code']==0 and collection['driver_hash_matches'] and
            collection['driver_readback_sha256']==DRIVER,'Stopped guest collector driver proof')
    # Keep the first collector typo/missing result intact. Exact missing records
    # were independently read from the same stopped FAT in RAM, never inferred.
    require(collection['missing']==['CLNT3511.REQ','CLNT3511.LOG','CLNT3511.ERR'],
            'Unexpected historical collector missing record')
    require(set(collection['files'])=={'C351NET.LOG','NET351.ON','NET351.STATUS','POST.LOG',
                                     'USABILITY.TXT','USOSNET351.SHA256'},'Exact collected own files')
    require(stopped['driver_sha256']==DRIVER and stopped['driver_bytes']==17024 and
            stopped['post_sha256']==POST and stopped['post_bytes']==30208,'Actual installed tuple')
    policy=stopped['policy']; require(policy['selected']=={'current':1,'default':1},'Selected clean hive')
    expected={'Browser':(4,32),'LanmanServer':(4,32),'LanmanWorkstation':(2,32),
              'Tcpip':(3,1),'NDISLoop':(2,1),'usosnt3':(4,16)}
    require(policy['services']['1']=={name:dict(present=True,start=value[0],type=value[1])
                                    for name,value in expected.items()},'Exact existing-service readback')
    own=stopped['own_policy_records']
    require(all(own[name].get('matches_exact_public_record') for name in ('CLNT351.REQ','CLNT351.LOG'))
            and own['CLNT351.ERR']=={'present':False},'Independent actual public policy records')
    require(stopped['scratch_whole_disk_removed'] and stopped['no_hive_export'] and
            stopped['no_ms_binary_export'] and not stopped['registry_modified'],'Read-only RAM boundary')
    evidence=CASE/'nt351-own-evidence'
    native=(evidence/'C351NET.LOG').read_text(encoding='utf-8')
    require((HERE/'C351NET.LOG').read_bytes()==(evidence/'C351NET.LOG').read_bytes(),
            'Independent native log bytes match')
    services=native.split('The command completed successfully.',1)[0]
    require(re.search(r'^\s+Workstation\s*$',services,re.M) and 'DHCP Client' in services and
            not re.search(r'^\s+(Server|Computer Browser)\s*$',services,re.M),'Actual native service list')
    require('IP address 10.0.2.15 successfully released' in native,'Actual DHCP release')
    for label,value in (('DHCP Enabled','Yes'),('DNS Servers','10.0.2.3'),
                        ('Default Gateway','10.0.2.2'),('Subnet Mask','255.255.255.0')):
        require(native_field(native,label,value),'Actual native DHCP/configuration: '+label)
    ping=re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time([=<])(\d+)ms TTL=255',native)
    require(len(ping)==3 and all(int(n)<=10 for mode,n in ping),'Three native replies within10ms')
    log=(evidence/'USABILITY.TXT').read_text(encoding='utf-8')
    snapshots=re.findall(r'=== USOSLOG .*?=== end of snapshot #[^\n]+',log,re.S)
    require(len(snapshots)==1 and 'Windows 3.51 build 1057' in log,'One fresh completed actual351 snapshot')
    require('ICMP gateway 10.0.2.2: PASS status=0 replies=1 rtt=0 ms echo_match=1' in log,'Matched ICMP')
    dns=[line for line in log.splitlines() if 'DNS PASS dns_match=1' in line]
    require(len(dns)==3 and all(re.search(r'id=[A-F0-9]{4} question=frogfind\.com A=64\.227\.13\.248$',line)
                               for line in dns),'Three actual strict DNS replies')
    require(any('from 1.1.1.1:53:' in line for line in dns) and any('from 8.8.8.8:53:' in line for line in dns)
            and any('TCP DNS 1.1.1.1:53:' in line for line in dns),'Exact observed fixed DNS peers/transports')
    require('gethostbyname(frogfind.com): 64.227.13.248' in log,'Actual native configured resolver')
    oldcmd=read(OLD/'command.json'); command=read(CASE/'command.json')
    require(normalized(oldcmd,'nt351-irq-fresh01')==normalized(command,TAG),'Matched outer hardware argv')
    for relative,row in cache['source_cache_files'].items():
        require(file_sha(Path(cache['base'])/relative)==row['sha256'],'Old cache unchanged: '+relative)
        wanted=cache['initrd_sha256'] if relative=='zig-out/micro-linux/initramfs-usos' else row['sha256']
        require(file_sha(Path(cache['output'])/relative)==wanted,'Frozen candidate unchanged: '+relative)
    capture=result['network_capture']; pcap=CASE/'network.pcap'
    require(file_sha(pcap)==capture['sha256'] and not capture['capped'] and capture['error'] is None,
            'Completed uncapped capture identity')
    spec=importlib.util.spec_from_file_location('auto351_capture',HERE/'harness/nt351_capture.py')
    cap=importlib.util.module_from_spec(spec);spec.loader.exec_module(cap)
    data=pcap.read_bytes(); offset=24;record=0; leases=[]
    while offset<len(data):
        require(offset+16<=len(data),'PCAP record header')
        _,_,size,original=struct.unpack_from('<IIII',data,offset);offset+=16;record+=1
        require(size==original and size<=65536 and offset+size<=len(data),'Bounded complete PCAP frame')
        frame=data[offset:offset+size];offset+=size
        packet=cap.dhcp(frame)
        if packet and record>=capture['analysis']['prepared_target_start_record']:
            leases.append(dict(record=record,packet=packet))
    qimg=ROOT.parent/'bety-instalacja/tools/qemu/qemu-img.exe'
    target=WORK/'target-retained.qcow2'
    info=json.loads(subprocess.check_output([str(qimg),'info','--output=json',str(target)]))
    require(info['format']=='qcow2' and info['virtual-size']==4*1024**3 and not info.get('backing-filename'),
            'New standalone target, no installed parent')
    require(file_sha(target)==stopped['target_sha256'],'Stopped target pin retained')
    retained={leaf:dict(bytes=(WORK/leaf).stat().st_size,sha256=file_sha(WORK/leaf))
              for leaf in ('target-retained.qcow2','stick-retained.qcow2','vars-retained.fd')}
    evaluation=dict(case=TAG,scope='Exact normal fresh351 Workstation EN PROFILE route; PS2 allowed',
        fresh_normal_usos_desktop='PASS',client_no_sharing_policy='PASS',native_lan='PASS',
        source_archive_sha256='24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975',
        source_iso_sha256='b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c',
        actual_version='Windows NT3.51 build1057 Workstation EN',driver_sha256=DRIVER,driver_bytes=17024,
        post_sha256=POST,post_bytes=30208,post_original351_imports=50,post_subsystem=[3,10],
        actual_native_workstation_running=True,actual_native_server_browser_absent=True,stopped_policy=policy,
        independent_exact_public_policy_records=own,first_collector_typo_retained=True,
        first_collector_missing_records=collection['missing'],recovery='Bounded stopped FAT RAM-only exact public records; no new VM',
        native_dhcp_release_renew=True,address='10.0.2.15',mask='255.255.255.0',gateway='10.0.2.2',dns='10.0.2.3',
        native_ping=[dict(comparison=mode,milliseconds=int(n)) for mode,n in ping],
        native_ping_all_strictly_under10ms=False,matched_guest_icmp_ms=0,strict_fixed_dns=dns,
        native_configured_resolution=True,configured_dns_matched_packet_claim=False,
        http_68k200='status line "HTTP/1.1 200 OK"' in log,
        preserved_negative_probe_lines=[line for line in log.splitlines() if 'NO REPLY' in line or 'TIMEOUT' in line],
        strict_same_xid_dora=capture['analysis']['dora_observed'],actual_dhcp_packets=leases,
        capture=dict(bytes=pcap.stat().st_size,frames=capture['stored_frames'],sha256=capture['sha256'],
                     controlled_boundary_reset_accepted=capture.get('controlled_boundary_reset_accepted')),
        native_safe_frame='operator-11.png',qemu_returncode=0,parent_returncode=0,
        independent_driver_readbacks=2,outer_hardware_argv_matches_previous_fresh351=True,
        all_old_cache_files_unchanged=True,all_other_candidate_cache_files_identical=True,
        initrd_sha256=cache['initrd_sha256'],effective_entries=832,changed_entries=3,unchanged_entries=829,
        elapsed_seconds=result['elapsed'],retained=retained,
        original_fresh351_running_server_browser_failure_preserved=True,
        NT35_POST615_runtime_qualified=False,NT35_frozen_other_tuple='d94/POST87cb, independent agent',
        limits=['No freshDEFAULT/USER/Server/NT31 qualification','No USB isolation/replug/MSC retest',
                'No physical X470/I211/SMP/fullIRQroute/fullrelease claim','First native ping10ms, other two<10ms',
                'Fixed strict DNS separate from native configured resolver; no configured-peer strictpacket claim'])
    output.write_text(json.dumps(evaluation,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps({key:evaluation[key] for key in ('case','fresh_normal_usos_desktop',
        'client_no_sharing_policy','native_lan','post_sha256','driver_sha256','elapsed_seconds')},indent=2))


if __name__=='__main__':
    main()
