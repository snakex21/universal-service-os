# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Host tests for the portable engine of the USOS Win16 Winsock provider.

The sources under src/platform/bios/win16/winsock16/net/ are plain C89 with no
Windows or DOS dependency, so they are compiled here with the host compiler
(clang/gcc from PATH, else ``zig cc``) together with tools/tests/win16/
net_harness.c and exercised with hand-made frames: no network, no QEMU, no
Windows.

What is pinned:

* checksums: the RFC 1071 example IPv4 header, an odd-length buffer, and the
  UDP/TCP pseudo-header term cross-checked against an independent Python
  implementation;
* IPv4: header build/parse, DF always set, fragments rejected (MF and offset),
  bad version/checksum/runt rejected, dotted-quad conversion;
* ARP: request layout (broadcast, opcode, addresses), reply learning, cache
  ageing, miss/pending behaviour;
* UDP: build/parse round trip, checksum rejection, zero-checksum acceptance;
* ICMP: echo request/reply with the payload preserved;
* DNS: query encoding for "68k.news" and parsing of a synthetic A response that
  uses a compression pointer for the answer name;
* TCP: the blocking-client state machine on synthetic segments - ISN from the
  LFSR, SYN/SYN+ACK/ACK, one-segment window, ACK advance, retransmission and
  the retry budget, FIN/CLOSE_WAIT/LAST_ACK, RST, duplicates, gaps.

Two source-level contracts close the set: the engine never uses select or the
asynchronous Winsock calls, and only net/win16_pkt.c may include Windows/DOS
headers.
"""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
NET_DIR = ROOT / 'src' / 'platform' / 'bios' / 'win16' / 'winsock16' / 'net'
HARNESS = Path(__file__).resolve().parent / 'net_harness.c'

# The portable core: win16_pkt.c and win16_sock.c are the Win16 side and are
# intentionally not compiled here.
CORE = ['checksum.c', 'ip.c', 'arp.c', 'udp.c', 'icmp.c', 'tcp.c', 'dns.c', 'config.c']

ZIG_CANDIDATES = [Path(os.environ.get('USOS_ZIG', ROOT / 'tools/zig/zig.exe'))]



def _compiler() -> list[str] | None:
    for name in ('clang', 'gcc', 'cc'):
        found = shutil.which(name)
        if found:
            return [found]
    for zig in ZIG_CANDIDATES:
        if zig.is_file():
            return [str(zig), 'cc']
    return None


def _compiler_env() -> dict[str, str]:
    env = dict(os.environ)
    env['ZIG_GLOBAL_CACHE_DIR'] = os.environ.get('USOS_ZIG_CACHE', str(ROOT/'tools/cache/zig-global'))
    env['ZIG_LOCAL_CACHE_DIR'] = str(ROOT/'zig-out/win16/host-cache')
    return env


@pytest.fixture(scope='session')
def harness(tmp_path_factory) -> Path:
    compiler = _compiler()
    if compiler is None:
        pytest.skip('no host C compiler (clang/gcc/cc) and no zig fallback')
    exe = tmp_path_factory.mktemp('win16net') / ('net_harness.exe' if os.name == 'nt' else 'net_harness')
    cmd = compiler + [
        '-std=c89', '-pedantic', '-Wall', '-Wextra',
        '-I', str(NET_DIR),
        '-o', str(exe),
        str(HARNESS),
    ] + [str(NET_DIR / name) for name in CORE]
    result = subprocess.run(cmd, capture_output=True, text=True, env=_compiler_env())
    assert result.returncode == 0, 'compile failed:\n%s\n%s' % (result.stdout, result.stderr)
    return exe


def run_case(harness: Path, case: str, *args: str) -> dict[str, str]:
    result = subprocess.run([str(harness), case, *args], capture_output=True, text=True)
    assert result.returncode == 0, '%s failed:\n%s\n%s' % (case, result.stdout, result.stderr)
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if '=' in line:
            key, _, value = line.partition('=')
            values[key.strip()] = value.strip()
    return values


# ---------------------------------------------------------------------------
# Independent reference implementation of the ones-complement checksum
# ---------------------------------------------------------------------------

def _sum16(data: bytes) -> int:
    total = 0
    if len(data) % 2:
        data += b'\0'
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return total


def _pseudo(src: bytes, dst: bytes, proto: int, length: int) -> int:
    total = _sum16(src) + _sum16(dst) + proto + length
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return total


def _ones_complement(total: int) -> int:
    return (~total) & 0xFFFF


def test_checksum_vectors(harness: Path) -> None:
    out = run_case(harness, 'checksum')
    assert out['ipv4_header'].upper() == '0XB861'
    assert out['ipv4_header_filled'].upper() in ('0X0', '0X0000')
    assert int(out['odd'], 16) == _ones_complement(_sum16(b'abc'))
    assert int(out['htons'], 16) == 0x3412
    assert int(out['htonl'], 16) == 0x78563412
    # Pseudo-header for 192.168.0.1 -> 192.168.0.2, UDP, 13 bytes.
    expected = _ones_complement(
        _pseudo(bytes([192, 168, 0, 1]), bytes([192, 168, 0, 2]), 17, 13))
    assert int(out['pseudo'], 16) == expected
    assert int(out['udp_csum'], 16) != 0


def test_ip_build_and_parse(harness: Path) -> None:
    out = run_case(harness, 'ip')
    assert out['parse'] == '0'
    assert out['df'] == '1'
    assert out['mf clear'] == '0'
    assert out['proto'] == '17'
    assert out['total'] == '33'
    assert out['hdr'] == '20'
    assert out['payload'] == '13'
    assert out['ntoa'] == '192.168.0.1'


def test_arp_request_and_cache(harness: Path) -> None:
    out = run_case(harness, 'arp')
    assert out['request_len'] == '42'
    assert out['parsed op'] == '2'
    assert out['lookup hit'] == '1'
    assert out['unknown miss'] == '0'
    assert out['unknown pending'] == '1'
    assert out['expired'] == '0'


def test_udp_roundtrip(harness: Path) -> None:
    out = run_case(harness, 'udp')
    assert out['udp len'] == '33'
    assert out['udp sport'] == '1234'
    assert out['udp dport'] == '80'
    assert out['udp data len'] == '5'


def test_icmp_echo(harness: Path) -> None:
    out = run_case(harness, 'icmp')
    assert out['icmp id'] == '4660'
    assert out['icmp seq'] == '7'
    assert out['icmp reply type'] == '0'
    assert out['icmp reply id'] == '4660'


def _dns_name(name: str) -> bytes:
    out = bytearray()
    for label in name.split('.'):
        out.append(len(label))
        out.extend(label.encode('ascii'))
    out.append(0)
    return bytes(out)


def _dns_response(name: str = '68k.news', addr: str = '192.0.2.68') -> bytes:
    """A synthetic A response whose answer name is a 0xC00C pointer."""
    question = _dns_name(name)
    header = struct.pack('>HHHHHH', 0x1234, 0x8180, 1, 1, 0, 0)
    q = question + struct.pack('>HH', 1, 1)
    a = struct.pack('>H', 0xC00C) + struct.pack('>HHIH', 1, 1, 300, 4)
    a += bytes(int(part) for part in addr.split('.'))
    return header + q + a


def test_dns_query_and_response(harness: Path, tmp_path: Path) -> None:
    response = tmp_path / 'response.bin'
    response.write_bytes(_dns_response())
    out = run_case(harness, 'dns', str(response))

    expected_query = struct.pack('>HHHHHH', 0x1234, 0x0100, 1, 0, 0, 0)
    expected_query += _dns_name('68k.news') + struct.pack('>HH', 1, 1)
    assert out['query_len'] == str(len(expected_query))
    assert out['query_hex'].lower() == expected_query.hex()
    assert out['response_len'] == str(len(_dns_response()))
    assert out['dns count'] == '1'
    assert out['addr'] == '192.0.2.68'


def test_tcp_state_machine(harness: Path) -> None:
    out = run_case(harness, 'tcp')
    assert out['isn differs'] == '1'
    assert out['synack_ev'] == '1'          # USOS_TCP_EV_SYNACK
    assert out['data_ev'] == '3'            # USOS_TCP_EV_DATA
    assert out['fin_ev'] == '4'             # USOS_TCP_EV_FIN
    assert out['rst_ev'] == '5'             # USOS_TCP_EV_RST
    assert out['timeout_giveup'] == '-12'   # USOS_NET_ERR_TIME


def _strip_comments(text: str) -> str:
    """Drop C comments so a rule in a comment is not mistaken for code."""
    out = []
    i = 0
    while i < len(text):
        if text.startswith('/*', i):
            end = text.find('*/', i + 2)
            i = len(text) if end < 0 else end + 2
            out.append(' ')
        elif text.startswith('//', i):
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def test_engine_has_no_select_or_async() -> None:
    """No select()/WSAAsyncSelect anywhere in the engine."""
    offenders = []
    for path in sorted(NET_DIR.glob('*.[ch]')):
        text = _strip_comments(path.read_text(encoding='ascii', errors='replace'))
        for token in ('WSAAsync', 'select('):
            if token in text:
                offenders.append('%s: %s' % (path.name, token))
    assert offenders == []


def test_no_windows_dependency_in_portable_core() -> None:
    """Only win16_pkt.c may touch Windows, DOS or the compiler's i86.h."""
    forbidden = ('windows.h', 'dos.h', 'i86.h', 'GetTickCount', 'PeekMessage')
    offenders = []
    for path in sorted(NET_DIR.glob('*.[ch]')):
        if path.name in ('win16_pkt.c', 'usos_pkt.h'):
            continue          # the Win16 transport and its driver contract
        text = _strip_comments(path.read_text(encoding='ascii', errors='replace'))
        for token in forbidden:
            if token in text:
                offenders.append('%s: %s' % (path.name, token))
    assert offenders == []


def test_net_header_has_no_system_includes() -> None:
    header = (NET_DIR / 'net.h').read_text(encoding='ascii', errors='replace')
    includes = [line for line in header.splitlines() if line.strip().startswith('#include')]
    assert includes == ['#include <limits.h>']


@pytest.mark.parametrize('network', ['default','lan'])
def test_blocking_socket_keeps_all_segments_and_fin_data(tmp_path,network) -> None:
    compiler = _compiler()
    assert compiler is not None, 'host compiler needed for socket regression'
    exe = tmp_path / ('socket-peer.exe' if os.name == 'nt' else 'socket-peer')
    sources = [HARNESS.with_name('socket_harness.c'), NET_DIR / 'win16_sock.c']
    sources += [NET_DIR / name for name in CORE]
    result = subprocess.run(compiler + ['-std=c89', '-I', str(NET_DIR), '-o', str(exe)] +
                            [str(p) for p in sources], capture_output=True, text=True, env=_compiler_env())
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run([str(exe)]+(['lan'] if network=='lan' else []), capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'bytes=5157 eof=0 routed=1 failures=0' in result.stdout
    assert 'dns_onlink=1' in result.stdout


@pytest.fixture(scope='session')
def config_parser(tmp_path_factory):
    compiler=_compiler()
    assert compiler is not None
    exe=tmp_path_factory.mktemp('config-parser')/'config.exe'
    built=subprocess.run(compiler+['-std=c89','-pedantic','-Wall','-Wextra','-I',str(NET_DIR),
        '-o',str(exe),str(HARNESS.with_name('config_harness.c')),str(NET_DIR/'config.c'),
        str(NET_DIR/'ip.c'),str(NET_DIR/'checksum.c')],capture_output=True,text=True,env=_compiler_env())
    assert built.returncode==0,built.stdout+built.stderr
    return exe


@pytest.mark.parametrize('suffix,valid',[
    ('',True),
    ('NAMESERVER 1.1.1.1\r\n',True),
    ('NETMASK 255.0.255.0\r\n',False),
    ('IPADDR 256.1.2.3\r\n',False),
    ('GATEWAY 192.168.9.1\r\n',False),
    ('IPADDR 172.31.8.99\r\n',False),
])
def test_config_parser_lease_and_invalid_duplicates(config_parser,tmp_path,suffix,valid):
    cfg=tmp_path/'mtcp.cfg'
    cfg.write_text('# DHCP output\r\nPACKETINT 0x60\r\nHOSTNAME USOSDOS\r\n'
        'ipaddr\t172.31.8.15\r\nNETMASK 255.255.254.0\r\n'
        'GATEWAY 172.31.8.1 # LAN router\r\nNAMESERVER 172.31.9.3\r\n'+suffix,encoding='ascii')
    result=subprocess.run([str(config_parser),str(cfg)],capture_output=True,text=True,check=True)
    assert ('valid=1' in result.stdout)==valid
    if valid:
        assert 'ip=ac1f080f mask=fffffe00 gateway=ac1f0801 dns=ac1f0903' in result.stdout


@pytest.mark.parametrize('text',[
    '', 'PACKETINT 0x60\nHOSTNAME USOSDOS\n',
    'IPADDR 10.0.2.15\nNETMASK 255.255.255.0\nNAMESERVER 10.0.2.3\n',
    'IPADDR 10.0.2.0\nNETMASK 255.255.255.0\nGATEWAY 10.0.2.2\nNAMESERVER 10.0.2.3\n',
    'IPADDR 10.0.2.255\nNETMASK 255.255.255.0\nGATEWAY 10.0.2.2\nNAMESERVER 10.0.2.3\n',
])
def test_config_parser_rejects_partial_or_nonhost_addresses(config_parser,tmp_path,text):
    cfg=tmp_path/'mtcp.cfg'; cfg.write_text(text,encoding='ascii')
    result=subprocess.run([str(config_parser),str(cfg)],capture_output=True,text=True,check=True)
    assert 'valid=0' in result.stdout
