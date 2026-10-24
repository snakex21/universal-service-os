# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Local IRC dialogue and independent, finished-PCAP reassembly gates."""
import ipaddress
import json
import socket
import struct
import threading

import pytest

from irc_stage3_server import CHANNEL, IrcStage3Server, parse_message, parse_pcap


def start_server(tmp_path, **kwargs):
    server = IrcStage3Server(tmp_path, port=0, timeout=2, linger=1, **kwargs)
    thread = threading.Thread(target=server.run)
    thread.start()
    assert server.ready.wait(2), server.summary
    return server, thread


def receive_until(connection, marker):
    result = b""
    while marker not in result:
        part = connection.recv(2048)
        assert part, result
        result += part
    return result


def register(connection):
    connection.sendall(b"NICK USOS16\r\nUSER usos 0 * :USOS local test\r\n")
    return receive_until(connection, b" 376 USOS16 ")


def finish(server, thread):
    assert server.finished.wait(2), server.summary
    thread.join()
    return json.loads((server.out / "summary.json").read_text())


def test_loopback_dialogue_fragmented_registration_and_join(tmp_path):
    server, thread = start_server(tmp_path)
    with socket.create_connection(("127.0.0.1", server.port), timeout=2) as connection:
        # USER before NICK is legal; CRLF and commands may cross TCP writes.
        connection.sendall(b"USER usos 0 * :USOS test\r")
        connection.sendall(b"\nNI")
        connection.sendall(b"CK USOS16\r\n")
        welcome = receive_until(connection, b" 376 USOS16 ")
        for number in (1, 2, 3, 4, 5, 376):
            assert f" {number:03} USOS16 ".encode() in welcome
        connection.sendall(b"PING :proof-token\r\n")
        assert b"PONG usos.test :proof-token\r\n" in receive_until(connection, b"proof-token\r\n")
        connection.sendall(b"MODE USOS16\r\nUSERHOST USOS16\r\nWHO #usos-test\r\n")
        query = receive_until(connection, b" 315 USOS16 ")
        assert b" 221 USOS16 " in query and b" 302 USOS16 " in query
        connection.sendall(b"JOIN :#USOS-TEST\r\n")
        assert server.completion.wait(2)
        joined = receive_until(connection, b" 366 USOS16 ")
        assert b":USOS16!usos@localhost JOIN :#usos-test\r\n" in joined
        assert b" 353 USOS16 = #usos-test :@USOS16\r\n" in joined
        connection.sendall(b"QUIT :Done\r\n")
    summary = finish(server, thread)
    assert summary["pass"] and summary["bind"] == "127.0.0.1"
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert sum(event["event"] == "registered" for event in events) == 1
    assert sum(event["event"] == "join_complete" for event in events) == 1
    assert {path.name for path in tmp_path.iterdir()} == {"events.jsonl", "server.log", "summary.json"}


@pytest.mark.parametrize("registered,channel,number", [(False, CHANNEL, 451), (True, "#other", 403)])
def test_server_rejects_unregistered_or_uncontrolled_join(tmp_path, registered, channel, number):
    server, thread = start_server(tmp_path)
    with socket.create_connection(("127.0.0.1", server.port), timeout=2) as connection:
        if registered:
            register(connection)
        connection.sendall(f"JOIN {channel}\r\n".encode())
        assert f" {number:03} ".encode() in receive_until(connection, f" {number:03} ".encode())
        connection.sendall(b"QUIT\r\n")
    assert not finish(server, thread)["pass"]
    assert not server.completion.is_set()  # Final, after worker completion.


@pytest.mark.parametrize("line", [b"X" * 511 + b"\r\n", b"NICK X\n", b"NICK X\0\r\n"])
def test_server_bounds_invalid_input_without_join(tmp_path, line):
    server, thread = start_server(tmp_path)
    with socket.create_connection(("127.0.0.1", server.port), timeout=2) as connection:
        connection.sendall(line)
        assert server.finished.wait(2)
    summary = finish(server, thread)
    assert not summary["pass"] and "ValueError" in summary["error"]


def test_no_connection_timeout_is_terminal_event(tmp_path):
    server = IrcStage3Server(tmp_path, port=0, timeout=0.05, linger=0)
    thread = threading.Thread(target=server.run)
    thread.start()
    assert server.ready.wait(2)
    summary = finish(server, thread)
    assert not summary["pass"] and "TimeoutError" in summary["error"]


def test_output_evidence_is_not_overwritten(tmp_path):
    evidence = tmp_path / "events.jsonl"
    evidence.write_text("original evidence\n")
    server = IrcStage3Server(tmp_path, port=0)
    with pytest.raises(FileExistsError):
        server.run()
    assert evidence.read_text() == "original evidence\n"
    assert server.finished.is_set()


def test_message_parser_trailing_parameter_and_bounds():
    assert parse_message(":nick!u@h PRIVMSG #usos-test :two words") == (
        "nick!u@h", "PRIVMSG", ["#usos-test", "two words"])
    for malformed in ("", ":prefix", "NICK x\0", "JOIN x\n", "!bad x", "CMD " + " ".join("x" for _ in range(16))):
        with pytest.raises(ValueError):
            parse_message(malformed)


CLIENT_IP, SERVER_IP = "172.31.8.15", "172.31.8.2"
CLIENT_PORT, SERVER_PORT = 49152, 16667
REQUEST = b"NICK USOS16\r\nUSER usos 0 * :Local controlled test\r\nJOIN #usos-test\r\n"
REPLY = (b":usos.test 001 USOS16 :Welcome\r\n:usos.test 376 USOS16 :End MOTD\r\n"
         b":USOS16!usos@localhost JOIN :#usos-test\r\n"
         b":usos.test 353 USOS16 = #usos-test :@USOS16\r\n"
         b":usos.test 366 USOS16 #usos-test :End of NAMES list\r\n")


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!" + "H" * (len(data) // 2), data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def tcp_frame(sequence, payload=b"", *, server=False, flags=0x18, server_port=SERVER_PORT, vlan=False, fragment=0):
    source, dest = (SERVER_IP, CLIENT_IP) if server else (CLIENT_IP, SERVER_IP)
    sport, dport = (server_port, CLIENT_PORT) if server else (CLIENT_PORT, server_port)
    addresses = ipaddress.IPv4Address(source).packed + ipaddress.IPv4Address(dest).packed
    tcp = struct.pack("!HHIIBBHHH", sport, dport, sequence & 0xffffffff, 1, 0x50, flags, 4096, 0, 0) + payload
    tcp = tcp[:16] + struct.pack("!H", checksum(addresses + b"\0\x06" + struct.pack("!H", len(tcp)) + tcp)) + tcp[18:]
    ip = struct.pack("!BBHHHBBH", 0x45, 0, 20 + len(tcp), 1, fragment, 64, 6, 0) + addresses
    ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    ethernet = b"\x52\x54\0\x12\x34\x56\x52\x55\0\x11\x22\x33"
    ethernet += b"\x81\0\0\x01\x08\0" if vlan else b"\x08\0"
    return ethernet + ip + tcp


def write_capture(path, frames, *, endian="<", nanos=False):
    magic = 0xa1b23c4d if nanos else 0xa1b2c3d4
    blob = struct.pack(endian + "IHHIIII", magic, 2, 4, 0, 0, 65535, 1)
    for i, frame in enumerate(frames):
        blob += struct.pack(endian + "IIII", i, 0, len(frame), len(frame)) + frame
    path.write_bytes(blob)
    return path


def normal_frames(*, request=REQUEST, reply=REPLY, base=100, server_port=SERVER_PORT, vlan=False):
    return [tcp_frame(base, flags=2, server_port=server_port, vlan=vlan),
            tcp_frame(500, server=True, flags=0x12, server_port=server_port, vlan=vlan),
            tcp_frame(base + 1, request, server_port=server_port, vlan=vlan),
            tcp_frame(501, reply, server=True, server_port=server_port, vlan=vlan)]


@pytest.mark.parametrize("endian,nanos,vlan", [("<", False, False), (">", False, False), ("<", True, True), (">", True, True)])
def test_pcap_complete_dialogue_both_byte_orders_and_vlan(tmp_path, endian, nanos, vlan):
    result = parse_pcap(write_capture(tmp_path / "complete.pcap", normal_frames(vlan=vlan), endian=endian, nanos=nanos), server_ip=SERVER_IP)
    assert result["pass"] and len(result["flows"]) == 1
    assert result["flows"][0]["matching_replies"][0]["names_reply"]


def test_pcap_split_out_of_order_retransmission_and_sequence_wrap(tmp_path):
    base = 0xfffffff0
    packets = normal_frames(base=base)[:2]
    a, b = 7, 39
    packets += [tcp_frame(base + 1 + a, REQUEST[a:b]), tcp_frame(base + 1, REQUEST[:a]),
                tcp_frame(base + 1 + b, REQUEST[b:]), tcp_frame(base + 1 + a, REQUEST[a:b]),
                tcp_frame(540, REPLY[39:], server=True), tcp_frame(501, REPLY[:39], server=True)]
    result = parse_pcap(write_capture(tmp_path / "reordered.pcap", packets))
    assert result["pass"]
    assert result["flows"][0]["client_lines"] == REQUEST.decode().splitlines()


@pytest.mark.parametrize("change", ["request-only", "wrong-nick", "wrong-channel", "missing-end", "no-user", "other-port"])
def test_pcap_requires_bidirectional_matching_registration_and_channel(tmp_path, change):
    request, reply, port = REQUEST, REPLY, SERVER_PORT
    if change == "request-only":
        reply = b""
    elif change == "wrong-nick":
        reply = reply.replace(b"USOS16", b"Another")
    elif change == "wrong-channel":
        reply = reply.replace(b"#usos-test", b"#other")
    elif change == "missing-end":
        reply = reply[:reply.index(b":usos.test 366")]
    elif change == "no-user":
        request = b"NICK USOS16\r\nJOIN #usos-test\r\n"
    else:
        port = 6667
    result = parse_pcap(write_capture(tmp_path / "negative.pcap", normal_frames(request=request, reply=reply, server_port=port)))
    assert not result["pass"]


@pytest.mark.parametrize("damage", ["gap", "conflict", "fragment"])
def test_pcap_never_stitches_missing_or_conflicting_bytes(tmp_path, damage):
    packets = normal_frames()[:2]
    if damage == "gap":
        packets += [tcp_frame(101, REQUEST[:12]), tcp_frame(114, REQUEST[13:])]
    elif damage == "conflict":
        packets += [tcp_frame(101, REQUEST), tcp_frame(101, b"X" + REQUEST[1:])]
    else:
        packets += [tcp_frame(101, REQUEST, fragment=1)]
    packets += [tcp_frame(501, REPLY, server=True)]
    result = parse_pcap(write_capture(tmp_path / "damage.pcap", packets))
    assert not result["pass"]


def test_pcap_connection_epochs_cannot_combine_registration_and_join(tmp_path):
    registration = REQUEST[:REQUEST.index(b"JOIN")]
    packets = normal_frames(request=registration, reply=REPLY[:REPLY.index(b":USOS16!")])
    packets += normal_frames(request=b"JOIN #usos-test\r\n", reply=REPLY, base=900)
    result = parse_pcap(write_capture(tmp_path / "epochs.pcap", packets))
    assert not result["pass"] and len(result["flows"]) == 2


def test_pcap_retransmitted_syn_does_not_create_new_epoch(tmp_path):
    packets = normal_frames()
    packets.insert(1, packets[0])
    result = parse_pcap(write_capture(tmp_path / "syn-retry.pcap", packets))
    assert result["pass"] and len(result["flows"]) == 1


@pytest.mark.parametrize("cut", [1, 12, 23, -1, -8])
def test_pcap_rejects_incomplete_capture(tmp_path, cut):
    path = write_capture(tmp_path / "truncated.pcap", normal_frames())
    path.write_bytes(path.read_bytes()[:cut])
    with pytest.raises(ValueError):
        parse_pcap(path)


def test_pcap_bounds_tcp_stream_and_connection_count(tmp_path):
    packets = normal_frames()[:2] + [tcp_frame(101 + 300000, b"JOIN #usos-test\r\n")]
    result = parse_pcap(write_capture(tmp_path / "far-sequence.pcap", packets))
    assert not result["pass"] and result["flows"][0]["errors"]
    path = write_capture(tmp_path / "many-flows.pcap", [tcp_frame(i * 10000, flags=2) for i in range(17)])
    with pytest.raises(ValueError, match="too many"):
        parse_pcap(path)
