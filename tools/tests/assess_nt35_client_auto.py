"""Assess only a closed, independently visually reviewed fresh NT35 case."""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import subprocess

from readback_nt35_client_auto import native_policy, policy_pass

ROOT=Path(__file__).resolve().parents[2]
TAG='nt35-client-auto-fresh01'
HERE=ROOT/'artifacts/coverage'/TAG
CASE=ROOT/'artifacts/coverage/vm'/TAG
WORK=Path(r'G:\USOS-Kolekcja\_vm')/TAG
DRIVER='d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
POST='87cb43259878583758269b979c8e59411d69366ce5d58ec949a51638786d449f'


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def guest_network(native,log):
    text=native.replace('\r\n','\n')
    for required in ('IP address 10.0.2.15 successfully released',
                     'DHCP Enabled. . . . . . . . : Yes',
                     'DNS Servers . . . . . . . . : 10.0.2.3',
                     'Default Gateway . . . . . . : 10.0.2.2'):
        if required not in text:raise ValueError('Native DHCP configuration/renewal evidence missing: '+required)
    replies=re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time([^\n]+)',text)
    if len(replies)!=3:raise ValueError('Three real native gateway replies required')
    snapshots=re.findall(r'=== USOSLOG .*?=== end of snapshot #[^\n]+',log,re.S)
    if len(snapshots)!=1:raise ValueError('One explicit completed logger snapshot required; retain separate attempts')
    snapshot=snapshots[0]
    if 'Windows 3.50 build 807' not in snapshot:raise ValueError('Actual NT35 guest version missing')
    echo=re.search(r'ICMP gateway 10\.0\.2\.2: PASS status=0 replies=1 rtt=(\d+) ms echo_match=1',snapshot)
    dns=re.findall(r'(?:UDP|TCP) DNS [^\n]*DNS PASS dns_match=1[^\n]*',snapshot)
    if not echo or len(dns)!=3:raise ValueError('Strict matching guest echo and all three frozen fixed-DNS results required')
    if 'status line "HTTP/1.1 200 OK"' not in snapshot:raise ValueError('Real guest HTTP200 required')
    return dict(native_dhcp_release_renew=True,address='10.0.2.15',gateway='10.0.2.2',
        configured_dns_in_native_ipconfig='10.0.2.3',native_gateway_replies=replies,
        strict_gateway_echo_match=True,strict_gateway_rtt_ms=int(echo[1]),
        strict_fixed_dns_results=dns,strict_configured_dns_10_0_2_3='NOT_TESTED',
        native_gethostbyname_lines=[x for x in snapshot.splitlines() if 'gethostbyname' in x],
        http_200_observed=True,http_is_own_logger_not_ie=True,
        retained_negative_logger_lines=[x for x in snapshot.splitlines() if any(v in x for v in ('TIMEOUT','NO REPLY','FAIL'))])


def main():
    output=HERE/'guest-evaluation.json'
    if output.exists():raise FileExistsError('Preserve every prior assessment')
    result=json.loads((CASE/'result.json').read_text(encoding='utf-8'))
    process=json.loads((HERE/'process-exit.json').read_text(encoding='utf-8'))
    if process.get('returncode')!=0 or result.get('qemu_returncode')!=0 or result.get('error') is not None or result.get('product_failure') is not None:
        raise ValueError('Successful parent/QEMU writer completion required')
    if not (CASE/'cleanup.json').is_file():raise ValueError('Completed cleanup required')
    collection=json.loads((CASE/'nt35-own-evidence/collection.json').read_text(encoding='utf-8'))
    if set(collection['missing'])-{'CLNT35.ERR'} or not collection['driver_hash_matches'] or collection['driver_readback_sha256']!=DRIVER:
        raise ValueError('Required own diagnostics and actual driver readback missing')
    if 'CLNT35.ERR' in collection['files']:raise ValueError('Real terminal installer policy error present')
    readback=json.loads((HERE/'stopped-readback.json').read_text(encoding='utf-8'))
    if readback['driver_sha256']!=DRIVER or readback['post_sha256']!=POST or not policy_pass(readback['policy']):
        raise ValueError('Actual d94/POST/selected service configuration mismatch')
    if readback['own_files']['CLNT35.ERR']['present']:raise ValueError('Stopped installer error present')
    if (HERE/'CLNT35.REQ').read_bytes()!=b'USOS NT35 client-no-sharing\r\n':raise ValueError('Actual bounded request missing')
    if b'next_target_boot_required=true' not in (HERE/'CLNT35.LOG').read_bytes():raise ValueError('Actual preparation readback missing')
    native=(HERE/'C35NET.LOG').read_text(encoding='utf-8')
    services=native_policy(native)
    if not services['no_sharing_running_state']:raise ValueError('Actual native services violate client policy')
    log=(CASE/'nt35-own-evidence/USABILITY.TXT').read_text(encoding='utf-8')
    network=guest_network(native,log)
    visual=json.loads((HERE/'visual-review.json').read_text(encoding='utf-8'))
    required={'desktop','native_services','native_dhcp','native_ping','logger_complete','safe_shutdown'}
    if visual.get('case')!=TAG or set(visual['images'])!=required or not visual.get('native_safe_shutdown_observed'):
        raise ValueError('Explicit separate actual visual review required')
    for role,row in visual['images'].items():
        if not re.fullmatch(r'operator-\d{2}\.png',row['file']) or not row.get('observed') or digest(CASE/row['file'])!=row['sha256']:
            raise ValueError('Actual operator frame/review mismatch: '+role)
    command=json.loads((CASE/'command.json').read_text(encoding='utf-8'))
    for option,value in (('-machine','q35'),('-cpu','EPYC-Rome'),('-smp','2'),('-m','2048')):
        if command.count(option)!=1 or command[command.index(option)+1]!=value:raise ValueError('Unexpected topology '+option)
    if command.count('igb,netdev=usabilitynet,mac=52:54:00:55:53:01')!=1:raise ValueError('Exact one igb/MAC required')
    cache=json.loads((HERE/'cache-manifest.json').read_text(encoding='utf-8'))
    for name,row in cache['source_cache_files'].items():
        if digest(Path(cache['base'])/name)!=row['sha256']:raise ValueError('Original qualified cache changed')
        expected=cache['initrd_sha256'] if name=='zig-out/micro-linux/initramfs-usos' else row['sha256']
        if digest(Path(cache['output'])/name)!=expected:raise ValueError('Private frozen cache changed')
    qimg=ROOT.parent/'bety-instalacja/tools/qemu/qemu-img.exe'
    info=json.loads(subprocess.check_output([str(qimg),'info','--output=json',str(WORK/'target-retained.qcow2')]))
    if info['virtual-size']!=4*1024**3 or info['format']!='qcow2' or info.get('dirty-flag') or 'backing-filename' in info:
        raise ValueError('Clean fresh standalone4GiB target required')
    (HERE/'target-info.json').write_bytes((json.dumps(info,indent=2)+'\n').encode('utf-8'))
    capture=result['network_capture']
    if capture['capped'] or digest(CASE/'network.pcap')!=capture['sha256']:raise ValueError('Completed bounded capture mismatch')
    spec=importlib.util.spec_from_file_location('client_auto_capture',HERE/'harness/nt351_capture.py')
    cap=importlib.util.module_from_spec(spec);spec.loader.exec_module(cap)
    strict=cap.analyze_pcap((CASE/'network.pcap').read_bytes(),capture['analysis']['prepared_target_start_record'])
    (HERE/'pcap-completed-analysis.json').write_bytes((json.dumps(strict,indent=2)+'\n').encode('utf-8'))
    retained={name:dict(bytes=(WORK/name).stat().st_size,sha256=digest(WORK/name))
              for name in ('target-retained.qcow2','vars-retained.fd','stick-retained.qcow2')}
    assessment=dict(case=TAG,fresh_normal_usos_blank_target=True,fresh_desktop='PASS',
        fresh_auto_client_no_sharing='PASS',fresh_d94_guest_lan='PASS',
        auto_policy_source_commit='1feadbaf534d4546c42a051b6d34d430371d8f89',
        policy_configured_before_first_target_boot=True,manual_policy_helper_invoked=False,
        native_services=services,stopped_policy=readback['policy'],network=network,
        driver_sha256=DRIVER,driver_bytes=16384,actual_post_sha256=POST,actual_post_bytes=30208,
        independent_actual_driver_readbacks=2,initrd_sha256=cache['initrd_sha256'],
        changed_effective_entries=3,other_834_effective_entries_unchanged=True,
        old_and_private_cache_unchanged_after_runtime=True,visual_review=visual,
        native_safe_shutdown=True,qemu_returncode=0,process_returncode=0,
        target_sha256=readback['target_sha256'],retained_images=retained,
        bounded_vm_capture_sha256=capture['sha256'],strict_dora_observed=strict['dora_observed'],
        packet_capture_alone_never_guest_pass=True,ps2_baseline=True,new_usb_or_msc_qualification=False,
        previous_fresh_sharing_fail_and_overlay_policy_pass_unchanged=True,
        no_ms_binary_hive_export=True,no_physical_writes=True,no_progress_polling=True,
        scope='Exact NT3.5 Workstation EN/QEMU/AHCI/igb; no NT31/NT351/Server/physical/SMP or SMB-client transfer qualification')
    output.write_bytes((json.dumps(assessment,indent=2)+'\n').encode('utf-8'))
    print(json.dumps({k:assessment[k] for k in ('case','fresh_desktop','fresh_auto_client_no_sharing','fresh_d94_guest_lan','driver_sha256','actual_post_sha256')},indent=2))


if __name__=='__main__':main()
