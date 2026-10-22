"""Evaluate only the completed, retained NT35 IRQ qualification."""
from pathlib import Path
import hashlib
import importlib.util
import ipaddress
import json
import re
import struct

ROOT = Path(__file__).resolve().parents[3]
CASE = ROOT / 'artifacts/coverage/vm/nt35-irq-fixed01'
READBACK = ROOT / 'artifacts/nt35-irq/stopped-readback'
OUT = ROOT / 'artifacts/nt35-irq/evaluation.json'


def main():
    if OUT.exists():
        raise FileExistsError('Fresh completed evaluation required')
    result = json.loads((CASE / 'result.json').read_text('utf-8'))
    readback = json.loads((READBACK / 'readback.json').read_text('utf-8'))
    if result['qemu_returncode'] != 0 or result['error'] is not None or not readback['base_unchanged']:
        raise ValueError('Completed, pinned stopped readback required')
    complete_log = (READBACK / 'USABILITY.TXT').read_text('utf-8')
    headers = list(re.finditer(r'^=== USOSLOG 1\.0 snapshot #1 .*? ===$', complete_log, re.M))
    if len(headers) != 3:
        raise ValueError('Two historical and one new snapshot required')
    latest = complete_log[headers[-1].start():]
    if '[SYS] Windows 3.50 build 807 platform 2' not in latest or '=== end of snapshot #1 (11637 ms) ===' not in latest:
        raise ValueError('The new native NT35 snapshot is incomplete')
    native = (READBACK / 'IRQPOST.LOG').read_text('utf-8')
    if len(re.findall(r'Reply from 10\.0\.2\.2: bytes=32 time<10ms TTL=255', native)) != 3 or 'Request timed out.' in native:
        raise ValueError('Standard native ping3/3 below10ms absent')
    for wanted in ('DHCP Enabled. . . . . . . . : Yes', '10.0.2.15', '255.255.255.0',
                   '10.0.2.2', '10.0.2.3', '52-54-00-55-53-01'):
        if wanted not in native:
            raise ValueError('Native lease output differs')
    icmp = next(line for line in latest.splitlines() if 'ICMP gateway 10.0.2.2:' in line)
    if 'PASS status=0 replies=1 rtt=0 ms echo_match=1' not in icmp:
        raise ValueError('New strict logger ICMP result differs')
    dns = [line for line in latest.splitlines() if 'DNS PASS dns_match=1' in line]
    expected_dns = [('UDP DNS 1.1.1.1', 'id=72B1', 'reply after 80 ms'),
                    ('UDP DNS 8.8.8.8', 'id=7C08', 'reply after 30 ms'),
                    ('TCP DNS 1.1.1.1', 'id=25A3', 'connected in 20 ms')]
    if len(dns) != 3 or any(not any(all(token in line for token in tokens) for line in dns) for tokens in expected_dns):
        raise ValueError('Exact new strict DNS matches absent')
    if 'connected in 121 ms, 4095 bytes, status line "HTTP/1.1 200 OK"' not in latest:
        raise ValueError('New HTTP200 result differs')
    cap_path = Path(r'C:\Users\ASRock\usos-work\macierz-windows\tools\tests\coverage\nt351_capture.py')
    spec = importlib.util.spec_from_file_location('nt35_irq_completed_capture', cap_path)
    cap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cap)
    network = result['network_capture']
    pcap = (CASE / 'network.pcap').read_bytes()
    if network['error'] is not None or network['capped'] or hashlib.sha256(pcap).hexdigest() != network['sha256']:
        raise ValueError('Incomplete or changed capture')
    strict = cap.analyze_pcap(pcap, network['analysis']['prepared_target_start_record'])
    if strict != network['analysis']:
        raise ValueError('Strict capture analysis differs')
    offset = 24
    number = 0
    dhcp = []
    while offset < len(pcap):
        seconds, micros, size, _ = struct.unpack_from('<IIII', pcap, offset)
        offset += 16
        number += 1
        frame = pcap[offset:offset + size]
        offset += size
        packet = cap.dhcp(frame)
        if packet is None:
            continue
        ip_header = (frame[14] & 15) * 4
        payload = frame[14 + ip_header + 8:]
        dhcp.append(dict(record=number, timestamp=seconds + micros / 1e6,
                         ciaddr=str(ipaddress.IPv4Address(payload[12:16])), **packet))
    pairs = []
    for index, packet in enumerate(dhcp):
        if packet['kind'] != 5:
            continue
        request = next((old for old in reversed(dhcp[:index]) if old['kind'] == 3 and old['xid'] == packet['xid']), None)
        if request and packet['yiaddr'] == '10.0.2.15' and packet['server'] == '10.0.2.2' and packet['dns'] == ['10.0.2.3'] and packet['routers'] == ['10.0.2.2'] and packet['lease_seconds'] == 86400 and '10.0.2.15' in (request['ciaddr'], request['requested']):
            pairs.append(dict(xid=packet['xid'], records=[request['record'], packet['record']],
                address=packet['yiaddr'], server=packet['server'], dns=packet['dns'],
                routers=packet['routers'], lease_seconds=packet['lease_seconds']))
    if not pairs:
        raise ValueError('Pinned matching native renew REQUEST/ACK absent')
    images = ['endpoint.png'] + [f'operator-{number:02}.png' for number in (2, 9, 12, 13, 14, 17)]
    record = dict(scope='Installed NT3.5 Workstation R20b driver qualification; not a fresh installation or physical Intel result',
        manual_qualification_pass=True, driver_sha256=readback['installed_candidate_sha256'],
        driver_bytes=16384, i8042prt_start=4, source_backing_unchanged=True,
        native_dhcp_renew_and_all_pass=True, native_ping=dict(standard_timeout_unchanged=True, replies=3,
            total=3, each_rtt_ms_less_than=10), guest_icmp=icmp, guest_strict_dns=dns,
        guest_http=dict(host='68k.news', status=200, connect_ms=121, bytes=4095),
        guest_snapshot_duration_ms=11637, old_snapshot_count=2,
        historical_icmp_11010_preserved='FAIL, no echo reply, error 11010' in complete_log[:headers[-1].start()],
        historical_2s_dns_http_preserved='reply after 2003 ms' in complete_log[:headers[-1].start()],
        remaining_negative_controls=[line for line in latest.splitlines() if 'TIMEOUT' in line or 'NO REPLY' in line],
        native_safe_shutdown_image='operator-17.png', qemu_returncode=0, shutdown=result['shutdown'],
        network_capture_sha256=network['sha256'], network_capture_bytes=len(pcap), network_capture_frames=number,
        strict_dora_observed=strict['dora_observed'], matching_renew_request_ack=pairs, dhcp_packets=dhcp,
        no_new_igb_mmio_trace_claim=True, frozen_cache_changed=False, usb_hub_code_changed=False,
        historical_runner_flags_unchanged=True, stopped_readback=str(READBACK / 'readback.json'),
        images_sha256={name: hashlib.sha256((CASE / name).read_bytes()).hexdigest() for name in images},
        note='The generic runner flags remain false and are not promoted by status files; this manual result binds visible native tests to the exact installed SYS and completed capture.')
    OUT.write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(json.dumps({name: record[name] for name in ('manual_qualification_pass', 'native_ping',
        'guest_http', 'historical_icmp_11010_preserved', 'strict_dora_observed', 'matching_renew_request_ack')}, indent=2))


if __name__ == '__main__':
    main()
