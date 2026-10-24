#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent closed-capture DHCP/DNS/TCP/HTTP evidence for Win16 tests.

Reads a completed Ethernet pcap; never queries a running VM. TCP payload is
reassembled by sequence and compared with the guest's response when supplied.
Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
"""
from pathlib import Path
import argparse
import hashlib
import ipaddress
import json
import struct


def dns_name(message, offset):
    labels, seen, end = [], set(), None
    while offset < len(message):
        if offset in seen:
            raise ValueError('cyclic DNS name')
        seen.add(offset)
        count = message[offset]
        if count & 0xc0 == 0xc0:
            if offset+1 >= len(message):
                raise ValueError('short DNS pointer')
            if end is None:
                end = offset+2
            offset = ((count & 63) << 8) | message[offset+1]
            continue
        offset += 1
        if count == 0:
            return '.'.join(labels), end if end is not None else offset
        if count > 63 or offset+count > len(message):
            raise ValueError('invalid DNS label')
        labels.append(message[offset:offset+count].decode('ascii'))
        offset += count
    raise ValueError('short DNS name')


def collect(path, boundaries=None):
    raw = path.read_bytes()
    if raw[:4] != b'\xd4\xc3\xb2\xa1' or struct.unpack_from('<I', raw, 20)[0] != 1:
        raise ValueError('expected little endian Ethernet pcap')
    offset, packets = 24, 0
    flows, queries, answers, acks = {}, [], {}, []
    while offset < len(raw):
        _, _, length, _ = struct.unpack_from('<4I', raw, offset)
        frame = raw[offset+16:offset+16+length]
        offset += 16+length
        packets += 1
        if len(frame) < 34 or frame[12:14] != b'\x08\x00':
            continue
        ip = frame[14:]
        header, total = (ip[0] & 15)*4, struct.unpack_from('>H', ip, 2)[0]
        src, dst = str(ipaddress.IPv4Address(ip[12:16])), str(ipaddress.IPv4Address(ip[16:20]))
        payload = ip[header:total]
        if ip[9] == 17:
            sport, dport, size, _ = struct.unpack_from('>4H', payload)
            udp = payload[8:size]
            if (sport, dport) == (67, 68) and len(udp) >= 240 and udp[236:240] == b'\x63\x82\x53\x63':
                options, pos = {}, 240
                while pos < len(udp):
                    kind = udp[pos]; pos += 1
                    if kind == 255: break
                    if kind == 0: continue
                    count = udp[pos]; pos += 1
                    options[kind] = udp[pos:pos+count]; pos += count
                if options.get(53) == b'\x05':
                    acks.append({'ip': str(ipaddress.IPv4Address(udp[16:20])),
                                 'mask': str(ipaddress.IPv4Address(options[1])),
                                 'gateway': str(ipaddress.IPv4Address(options[3][:4])),
                                 'dns': str(ipaddress.IPv4Address(options[6][:4]))})
            if (sport == 53 or dport == 53) and len(udp) >= 12:
                flags, qcount, acount = struct.unpack_from('>3H', udp, 2)
                pos, names = 12, []
                for _ in range(qcount):
                    name, pos = dns_name(udp, pos)
                    names.append(name); pos += 4
                if not flags & 0x8000: queries.extend(names)
                for _ in range(acount):
                    owner, pos = dns_name(udp, pos)
                    kind, cls, ttl, count = struct.unpack_from('>HHIH', udp, pos); pos += 10
                    if kind == 1 and cls == 1 and count == 4:
                        address = str(ipaddress.IPv4Address(udp[pos:pos+4]))
                        for name in names: answers.setdefault(name, set()).add(address)
                    pos += count
        elif ip[9] == 6:
            sport, dport, sequence, ack = struct.unpack_from('>HHII', payload)
            content = payload[(payload[12] >> 4)*4:]
            key = (src, sport, dst, dport)
            if boundaries is not None and payload[13] & 1:
                boundaries[key] = (sequence + len(content)) & 0xffffffff
            if content:
                flow = flows.setdefault(key, {})
                for i, byte in enumerate(content):
                    at = (sequence+i) & 0xffffffff
                    if at in flow and flow[at] != byte:
                        raise ValueError('conflicting TCP retransmission')
                    flow[at] = byte
    streams = {}
    for key, octets in flows.items():
        start = min(octets)
        data = bytearray()
        for i in range(len(octets)):
            if start+i not in octets:
                raise ValueError('gap in TCP stream')
            data.append(octets[start+i])
        streams[key] = bytes(data)
    return packets, streams, queries, {k: sorted(v) for k,v in answers.items()}, acks


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pcap', type=Path, required=True)
    p.add_argument('--host', required=True)
    p.add_argument('--response', type=Path)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    boundaries = {}
    packets, streams, queries, answers, acks = collect(a.pcap, boundaries)
    hits = []
    for key, request in streams.items():
        if key[3] != 80 or not request.startswith(b'GET '):
            continue
        reverse = (key[2], key[3], key[0], key[1])
        response = streams.get(reverse, b'')
        header, separator, body = response.partition(b'\r\n\r\n')
        lengths = [int(line.split(b':',1)[1]) for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:')]
        status = response.startswith((b'HTTP/1.0 200', b'HTTP/1.1 200'))
        # Some original HTTP/0.9 clients receive a body with no header.
        legacy = b'HTTP/' not in request.split(b'\r\n',1)[0] and response.lstrip().lower().startswith((b'<!doctype', b'<html'))
        # HTTP/1.0/Connection:close can delimit its body by TCP FIN instead
        # of Content-Length. The sequence must follow every captured byte.
        closed = False
        if reverse in boundaries and response:
            # collect() rejects gaps and conflicting retransmissions. Recover
            # the first server sequence by parsing the immutable capture once.
            raw = a.pcap.read_bytes(); pos = 24; first = None
            while pos < len(raw):
                count = struct.unpack_from('<I', raw, pos+8)[0]
                frame = raw[pos+16:pos+16+count]; pos += 16+count
                if len(frame)<54 or frame[12:14] != b'\x08\x00': continue
                ip = frame[14:]; ih = (ip[0]&15)*4
                if ip[9] != 6: continue
                tcp = ip[ih:struct.unpack_from('>H', ip, 2)[0]]
                source = str(ipaddress.IPv4Address(ip[12:16])); dest = str(ipaddress.IPv4Address(ip[16:20]))
                sp, dp, seq = struct.unpack_from('>HHI', tcp)
                if (source,sp,dest,dp) == reverse and len(tcp) > (tcp[12]>>4)*4:
                    first = seq if first is None else min(first,seq)
            closed = first is not None and boundaries[reverse] == ((first+len(response)) & 0xffffffff)
        whole = bool(separator) and ((len(lengths) == 1 and lengths[0] == len(body)) or (not lengths and closed)) or legacy
        hit = {'client': list(key[:2]), 'server': list(key[2:]), 'request': request.decode('latin1'),
               'status_200': status, 'http09_body': legacy, 'complete_body': whole, 'server_fin_at_end': closed,
               'response_bytes': len(response), 'body_bytes': len(body) if separator else len(response),
               'response_sha256': hashlib.sha256(response).hexdigest(),
               'resolved_server': key[2] in answers.get(a.host, [])}
        if a.response is not None:
            hit['guest_file_identical'] = response == a.response.read_bytes()
        hits.append(hit)
    passed = bool(acks) and a.host in queries and any(
        (h['status_200'] or h['http09_body']) and h['complete_body'] and h['resolved_server'] and h.get('guest_file_identical', True)
        for h in hits)
    result = {'pass': passed, 'packets': packets, 'pcap_sha256': hashlib.sha256(a.pcap.read_bytes()).hexdigest(),
              'dns_queries': queries, 'dns_answers': answers, 'dhcp_acks': acks, 'http_streams': hits}
    a.out.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
