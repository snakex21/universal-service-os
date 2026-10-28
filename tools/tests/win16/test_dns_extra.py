# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
"""Independent RFC1035 packets exercise both reverse and A parser bounds."""
import os
import struct
import subprocess
from pathlib import Path
import pytest
from test_winsock16_net import NET_DIR, _compiler, _compiler_env


def label(name):
    return b"".join(bytes([len(part)]) + part.encode("ascii") for part in name.split(".")) + b"\0"


def pointer(offset):
    return struct.pack(">H", 0xC000 | offset)


QNAME = "68.2.0.192.in-addr.arpa"
QUESTION = label(QNAME) + struct.pack(">HH", 12, 1)


def header(answers=1, flags=0x8180, authority=0):
    return struct.pack(">HHHHHH", 0x1234, flags, 1, answers, authority, 0)


def record(data, kind=12, owner=pointer(12), rdlen=None):
    return owner + struct.pack(">HHIH", kind, 1, 60, len(data) if rdlen is None else rdlen) + data


def plain(data=None):
    return header() + QUESTION + record(label("host.example.test") if data is None else data)


@pytest.fixture(scope="session")
def dns_bridge(tmp_path_factory):
    compiler = _compiler()
    assert compiler
    exe = tmp_path_factory.mktemp("dns-extra") / ("bridge.exe" if os.name == "nt" else "bridge")
    sources = [Path(__file__).with_name("dns_extra_harness.c")]
    sources += [NET_DIR / name for name in ("dns_extra.c", "dns.c", "ip.c", "checksum.c")]
    built = subprocess.run(compiler + ["-std=c89", "-pedantic", "-Wall", "-Wextra", "-I", str(NET_DIR),
                                      "-o", str(exe)] + list(map(str, sources)),
                           capture_output=True, text=True, env=_compiler_env())
    assert built.returncode == 0, built.stdout + built.stderr
    return exe


def run(dns_bridge, *args):
    result = subprocess.run([str(dns_bridge), *map(str, args)], capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def parse(dns_bridge, tmp_path, packet, room=256, kind="ptr"):
    file = tmp_path / "packet.bin"
    file.write_bytes(packet)
    result = run(dns_bridge, kind, file, room)
    if kind == "ptr":
        assert result["guards"] == "1"
    return result


@pytest.mark.parametrize("ip,reverse", [(0xC0000244, QNAME), (0x00010AFF, "255.10.1.0.in-addr.arpa"),
                                       (0xFFFFFFFF, "255.255.255.255.in-addr.arpa")])
def test_ptr_question_reverses_hostorder_octets(dns_bridge, ip, reverse):
    result = run(dns_bridge, "query", f"{ip:x}")
    expected = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + label(reverse) + struct.pack(">HH", 12, 1)
    assert bytes.fromhex(result["hex"]) == expected
    assert int(result["length"]) == len(expected)


def test_plain_ptr_and_compressed_cname_suffix(dns_bridge, tmp_path):
    result = parse(dns_bridge, tmp_path, plain())
    assert result["rc"] == "0" and result["name"] == "host.example.test"
    first = header(2) + QUESTION
    cname_offset = len(first) + 12
    cname = label("target.example.test")
    first += record(cname, kind=5)
    example_offset = cname_offset + len("target") + 1
    packet = first + record(b"\x04node" + pointer(example_offset), owner=pointer(cname_offset))
    result = parse(dns_bridge, tmp_path, packet)
    assert result["rc"] == "0" and result["name"] == "node.example.test"


@pytest.mark.parametrize("flags,expected", [(0x8183, -8), (0x8182, -9), (0x8380, -2), (0x0980, -6)])
def test_negative_and_truncated_flags(dns_bridge, tmp_path, flags, expected):
    result = parse(dns_bridge, tmp_path, header(0, flags) + QUESTION)
    assert int(result["rc"]) == expected and result["name"] == ""


@pytest.mark.parametrize("cut", [0, 11, 12, 14, len(header() + QUESTION) - 1, len(plain()) - 1])
def test_truncated_name_header_and_rdata(dns_bridge, tmp_path, cut):
    assert int(parse(dns_bridge, tmp_path, plain()[:cut])["rc"]) != 0


def test_cyclic_forward_and_overflowing_pointer_rdata(dns_bridge, tmp_path):
    at = len(header() + QUESTION) + 12
    for bad in (pointer(at), pointer(at + 2), b"\xff\xff", b"\xc0"):
        assert int(parse(dns_bridge, tmp_path, plain(bad))["rc"]) != 0
    result = parse(dns_bridge, tmp_path, plain(), room=5)
    assert result["rc"] == "-7" and result["name"] == ""
    huge = label("a" * 63 + "." + "b" * 63 + "." + "c" * 63 + "." + "d" * 63)
    assert parse(dns_bridge, tmp_path, plain(huge))["rc"] == "-8"


def test_no_ptr_unrelated_answer_and_referral_are_not_host_answers(dns_bridge, tmp_path):
    cases = [header(0) + QUESTION,
             header() + QUESTION + record(b"\xc0\x00\x02\x44", kind=1),
             header(0, authority=1) + QUESTION + record(label("host.example.test")),
             header() + QUESTION + record(label("host.example.test"), owner=label("other.in-addr.arpa"))]
    for packet in cases:
        assert parse(dns_bridge, tmp_path, packet)["rc"] == "-8"


def test_rdlength_65535_does_not_wrap_in_either_parser(dns_bridge, tmp_path):
    packet = header() + QUESTION + record(b"\0", rdlen=65535)
    assert parse(dns_bridge, tmp_path, packet)["rc"] == "-2"
    a_question = label("a") + struct.pack(">HH", 1, 1)
    packet = header() + a_question + record(b"\0", kind=1, rdlen=65535)
    assert parse(dns_bridge, tmp_path, packet, kind="a")["rc"] == "-2"


def test_a_rr_header_near_16bit_end_is_checked_before_reading(dns_bridge, tmp_path):
    prefix = header(2) + label("a") + struct.pack(">HH", 1, 1)
    packet = prefix + record(bytes(65497), kind=16) + bytes(7)
    assert len(packet) == 65535
    result = parse(dns_bridge, tmp_path, packet, kind="a")
    assert result["rc"] == "-2" and result["count"] == "0"


def test_a_owner_compression_cycle_is_rejected(dns_bridge, tmp_path):
    prefix = header() + label("a") + struct.pack(">HH", 1, 1)
    packet = prefix + record(b"\xc0\x00\x02\x44", kind=1, owner=pointer(len(prefix)))
    assert parse(dns_bridge, tmp_path, packet, kind="a")["rc"] == "-8"
