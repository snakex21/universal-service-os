# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Controlled IRC gate for mIRC Win16; localhost/QEMU only.

Protocol reference: https://www.rfc-editor.org/rfc/rfc1459.html
This is a single-client test endpoint, not a general IRC daemon. No relaying,
public network connection, ident lookup, configuration or external cache is
used. All evidence is written underneath the supplied output directory.

Run ``serve --out DIR`` before the VM, wait for its ready event, and point the
client at the QEMU user-network host address, port 16667. Completion is an
Event set after registered JOIN #usos-test and its replies have been sent.
``analyze --pcap FILE --out DIR`` reads a *completed* classic Ethernet PCAP
once; it does not tail an active capture or poll a VM.

CRLF framing is strict by default. The explicit ``--allow-legacy-lf`` option
also accepts bare LF from the original mIRC 5.91 Win16 evaluation client;
it is recorded in the evidence and never changes the server's CRLF replies.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import ipaddress
import json
from pathlib import Path
import re
import socket
import struct
import threading
import time
from typing import Callable

CHANNEL = "#usos-test"
SERVER = "usos.test"
SCOPE = "localhost/QEMU only; controlled IRC endpoint, not public Internet IRC"
MAX_LINE = 510  # RFC1459's 512-byte limit includes CRLF.
MAX_STREAM = 256 * 1024
MAX_FLOWS = 16
NICK = re.compile(r"[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,8}\Z")


def irc_casefold(value: str) -> str:
    return value.lower().translate(str.maketrans("[]\\^", "{}|~"))


def parse_message(line: str) -> tuple[str, str, list[str]]:
    """Parse one complete line, preserving the trailing parameter as a unit."""
    if not line or any(char in line for char in "\r\n\0"):
        raise ValueError("invalid IRC line")
    prefix = ""
    if line.startswith(":"):
        prefix, separator, line = line[1:].partition(" ")
        if not separator or not prefix:
            raise ValueError("missing command after prefix")
    head, separator, trailing = line.partition(" :")
    parts = head.split()
    if not parts:
        raise ValueError("missing IRC command")
    command, parameters = parts[0].upper(), parts[1:]
    if not (command.isascii() and (command.isalpha() or (command.isdigit() and len(command) == 3))):
        raise ValueError("invalid IRC command")
    if separator:
        parameters.append(trailing)
    if len(parameters) > 15:
        raise ValueError("too many IRC parameters")
    return prefix, command, parameters


class IrcStage3Server:
    """One blocking listener with readiness/completion/finished Events.

    The bind address is deliberately fixed to loopback. Port 0 is available
    for isolated host tests; the CLI and actual QEMU gate default to 16667.
    """

    def __init__(self, out: Path, *, port: int = 16667, timeout: float = 180,
                 linger: float = 5, on_event: Callable[[dict], None] | None = None,
                 allow_legacy_lf: bool = False):
        if not 0 <= port <= 65535 or timeout <= 0 or linger < 0:
            raise ValueError("invalid port or timeout")
        self.out = Path(out)
        self.port, self.timeout, self.linger = port, timeout, linger
        self.on_event = on_event
        self.allow_legacy_lf = allow_legacy_lf
        self.ready, self.completion, self.finished = (threading.Event() for _ in range(3))
        self.summary: dict = {"scope": SCOPE, "registered": False, "joined": False, "pass": False,
                              "allow_legacy_lf": allow_legacy_lf, "bare_lf_observed": False}
        self._events = self._log = None

    def _event(self, kind: str, **values) -> None:
        event = {"event": kind, "time_utc": datetime.now(timezone.utc).isoformat(), **values}
        self._events.write(json.dumps(event, ensure_ascii=True) + "\n")
        self._events.flush()
        self._log.write(kind + " " + json.dumps(values, ensure_ascii=True) + "\n")
        self._log.flush()
        if self.on_event:
            self.on_event(event)

    def run(self) -> dict:
        self.out.mkdir(parents=True, exist_ok=True)
        # Exclusive creation prevents silently replacing another test's evidence.
        try:
            with (self.out / "events.jsonl").open("x", encoding="utf-8") as self._events, \
                    (self.out / "server.log").open("x", encoding="utf-8") as self._log:
                try:
                    self._serve()
                except (OSError, ValueError) as error:
                    self.summary["error"] = f"{type(error).__name__}: {error}"
                    self._event("error", error=self.summary["error"])
                self.summary["pass"] = self.summary["registered"] and self.summary["joined"]
                self._event("finished", **self.summary)
            (self.out / "summary.json").write_text(json.dumps(self.summary, indent=2) + "\n", encoding="utf-8")
            return self.summary
        finally:
            self.finished.set()

    def _serve(self) -> None:
        nick = user = ""
        registered = joined = False
        deadline = time.monotonic() + self.timeout
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen(1)
            self.port = listener.getsockname()[1]
            self.summary.update(bind="127.0.0.1", port=self.port, channel=CHANNEL)
            self._event("ready", bind="127.0.0.1", port=self.port)
            self.ready.set()
            listener.settimeout(max(0.001, deadline - time.monotonic()))
            connection, address = listener.accept()
            with connection:
                self._event("accepted", peer_address=address[0], peer_port=address[1])
                buffer = b""

                def send(line: str) -> None:
                    encoded = line.encode("latin1")
                    if len(encoded) > MAX_LINE or any(char in line for char in "\r\n\0"):
                        raise ValueError("invalid server reply")
                    connection.sendall(encoded + b"\r\n")
                    self._event("server_line", line=line)

                def numeric(code: int, rest: str) -> None:
                    send(f":{SERVER} {code:03d} {nick or '*'} {rest}")

                def names() -> None:
                    numeric(353, f"= {CHANNEL} :@{nick}")
                    numeric(366, f"{CHANNEL} :End of NAMES list")

                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        if not joined:
                            raise TimeoutError("registered JOIN deadline expired")
                        return
                    connection.settimeout(remaining)
                    try:
                        data = connection.recv(2048)
                    except TimeoutError:
                        if joined:
                            return
                        raise
                    if not data:
                        self._event("peer_closed")
                        return
                    buffer += data
                    delimiter = b"\n" if self.allow_legacy_lf else b"\r\n"
                    while delimiter in buffer:
                        raw, buffer = buffer.split(delimiter, 1)
                        bare_lf = self.allow_legacy_lf and not raw.endswith(b"\r")
                        if self.allow_legacy_lf and not bare_lf:
                            raw = raw[:-1]
                        if len(raw) > MAX_LINE:
                            raise ValueError("IRC line exceeds 512 bytes")
                        line = raw.decode("latin1")
                        prefix, command, parameters = parse_message(line)
                        self.summary["bare_lf_observed"] |= bare_lf
                        self._event("client_line", line="PASS :[redacted]" if command == "PASS" else line,
                                    line_ending="LF" if bare_lf else "CRLF")
                        if prefix and irc_casefold(prefix) != irc_casefold(nick):
                            raise ValueError("untrusted client prefix")
                        if command == "NICK":
                            if not parameters or not NICK.fullmatch(parameters[0]):
                                numeric(432, "* :Erroneous nickname")
                                continue
                            new_nick = parameters[0]
                            if registered:
                                send(f":{nick}!{user}@localhost NICK :{new_nick}")
                            nick = new_nick
                        elif command == "USER":
                            if registered:
                                numeric(462, ":You may not reregister")
                            elif len(parameters) < 4 or not re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", parameters[0]):
                                numeric(461, "USER :Not enough or invalid parameters")
                            else:
                                user = parameters[0]
                        elif command == "PING":
                            if parameters:
                                send(f":{SERVER} PONG {SERVER} :{parameters[-1]}")
                            else:
                                numeric(461, "PING :Not enough parameters")
                        elif command in {"PONG", "PASS"}:
                            pass
                        elif command == "QUIT":
                            self._event("quit")
                            return
                        elif not registered:
                            numeric(451, ":You have not registered")
                        elif command == "JOIN":
                            if not parameters or irc_casefold(parameters[0]) != CHANNEL:
                                numeric(403, f"{parameters[0] if parameters else '*'} :Only {CHANNEL} is available")
                            else:
                                send(f":{nick}!{user}@localhost JOIN :{CHANNEL}")
                                numeric(332, f"{CHANNEL} :USOS controlled local Win16 IRC test")
                                names()
                                if not joined:
                                    joined = True
                                    self.summary.update(joined=True, nick=nick, user=user)
                                    self._event("join_complete", nick=nick, channel=CHANNEL)
                                    self.completion.set()
                                    deadline = min(deadline, time.monotonic() + self.linger)
                        elif command == "NAMES" and parameters and irc_casefold(parameters[0]) == CHANNEL:
                            names()
                        elif command == "MODE":
                            if parameters and irc_casefold(parameters[0]) == CHANNEL:
                                numeric(324, f"{CHANNEL} +nt")
                            else:
                                numeric(221, "+i")
                        elif command == "USERHOST":
                            numeric(302, f":{nick}=+{user}@localhost")
                        elif command == "WHO":
                            numeric(315, f"{parameters[0] if parameters else '*'} :End of WHO list")
                        else:
                            numeric(421, f"{command} :Unsupported by local test endpoint")
                        if nick and user and not registered:
                            registered = True
                            self.summary.update(registered=True, nick=nick, user=user)
                            numeric(1, f":Welcome to the local test network {nick}!{user}@localhost")
                            numeric(2, f":Your host is {SERVER}, running USOS-stage3")
                            numeric(3, ":This controlled server has a fixed test configuration")
                            numeric(4, f"{SERVER} USOS-stage3 i nt")
                            numeric(5, "CHANTYPES=# NICKLEN=9 CASEMAPPING=rfc1459 :are supported by this server")
                            numeric(375, f":- {SERVER} Message of the day -")
                            numeric(372, ":Local test only; no public IRC or external users")
                            numeric(376, ":End of MOTD command")
                            self._event("registered", nick=nick)
                    if len(buffer) > MAX_LINE or b"\n" in buffer or b"\0" in buffer:
                        raise ValueError("malformed or oversized partial IRC line")


def _difference(a: int, b: int) -> int:
    return ((a - b + 0x80000000) & 0xffffffff) - 0x80000000


@dataclass
class Direction:
    syn: int | None = None
    pieces: list[tuple[int, bytes]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    size: int = 0
    bare_lf_observed: bool = False

    def add(self, sequence: int, flags: int, payload: bytes) -> None:
        if flags & 2:
            self.syn = sequence
            sequence = (sequence + 1) & 0xffffffff
        if payload:
            self.size += len(payload)
            if self.size > MAX_STREAM * 4:
                raise ValueError("too much TCP payload/retransmission in one direction")
            self.pieces.append((sequence, payload))

    def lines(self, *, allow_legacy_lf: bool = False) -> list[str]:
        if not self.pieces:
            return []
        origin = (self.syn + 1) & 0xffffffff if self.syn is not None else self.pieces[0][0]
        offsets = [(_difference(sequence, origin), data) for sequence, data in self.pieces]
        if self.syn is None:
            lowest = min(offset for offset, _ in offsets)
            offsets = [(offset - lowest, data) for offset, data in offsets]
        size = max(offset + len(data) for offset, data in offsets)
        if size > MAX_STREAM or any(offset < 0 for offset, _ in offsets):
            self.errors.append("TCP sequence range outside bounded stream")
            return []
        contents, present = bytearray(size), bytearray(size)
        for offset, data in offsets:
            for position, byte in enumerate(data, offset):
                if present[position] and contents[position] != byte:
                    self.errors.append("conflicting TCP retransmission")
                    return []
                contents[position], present[position] = byte, 1
        end = present.find(0)
        if end < 0:
            end = size
        if end != size:
            self.errors.append("TCP stream has a capture gap")
        stream = bytes(contents[:end])
        if not allow_legacy_lf and any(i == 0 or stream[i - 1] != 13
                                     for i, byte in enumerate(stream) if byte == 10):
            self.errors.append("bare LF IRC framing requires explicit opt-in")
            return []
        raw_lines = stream.split(b"\n" if allow_legacy_lf else b"\r\n")[:-1]
        if allow_legacy_lf:
            self.bare_lf_observed = any(not line.endswith(b"\r") for line in raw_lines)
            raw_lines = [line[:-1] if line.endswith(b"\r") else line for line in raw_lines]
        if any(len(line) > MAX_LINE or any(char in line for char in (b"\r", b"\n", b"\0")) for line in raw_lines):
            self.errors.append("malformed IRC line in TCP stream")
            return []
        return [line.decode("latin1") for line in raw_lines if line]


def _tcp_frame(frame: bytes):
    if len(frame) < 14:
        return None
    ether_type, offset = struct.unpack_from("!H", frame, 12)[0], 14
    for _ in range(2):
        if ether_type not in (0x8100, 0x88a8):
            break
        if len(frame) < offset + 4:
            return None
        ether_type = struct.unpack_from("!H", frame, offset + 2)[0]
        offset += 4
    ip = frame[offset:]
    if ether_type != 0x800 or len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 6:
        return None
    header, total = (ip[0] & 15) * 4, struct.unpack_from("!H", ip, 2)[0]
    if header < 20 or total < header + 20 or total > len(ip) or struct.unpack_from("!H", ip, 6)[0] & 0x3fff:
        return None
    tcp = ip[header:total]
    tcp_header = (tcp[12] >> 4) * 4
    if tcp_header < 20 or tcp_header > len(tcp):
        return None
    source, dest = str(ipaddress.IPv4Address(ip[12:16])), str(ipaddress.IPv4Address(ip[16:20]))
    sport, dport, sequence, ack = struct.unpack_from("!HHII", tcp)
    return source, dest, sport, dport, sequence, ack, tcp[13], tcp[tcp_header:]


def parse_pcap(path: Path, *, port: int = 16667, server_ip: str | None = None,
               allow_legacy_lf: bool = False) -> dict:
    """Reassemble a finished classic Ethernet PCAP, rejecting gaps/conflicts.

    Retransmissions, segmentation, out-of-order capture and 32-bit sequence
    wrap are supported. A new client SYN starts a fresh connection epoch;
    commands from distinct TCP connections cannot be combined into a PASS.
    """
    flows: list[dict] = []
    active: dict[tuple, dict] = {}
    packet_count = relevant = 0
    with Path(path).open("rb") as capture:
        header = capture.read(24)
        magic = header[:4]
        if len(header) != 24 or magic not in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4", b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d"):
            raise ValueError("expected complete classic PCAP header")
        endian = "<" if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
        major, minor, _, _, snaplen, link = struct.unpack(endian + "HHIIII", header[4:])
        if (major, minor) != (2, 4) or link != 1 or not 14 <= snaplen <= 16 * 1024 * 1024:
            raise ValueError("unsupported PCAP version/link type/snaplen")
        while True:
            record = capture.read(16)
            if not record:
                break
            if len(record) != 16:
                raise ValueError("truncated PCAP packet header")
            _, _, included, original = struct.unpack(endian + "IIII", record)
            if included > snaplen or included > original:
                raise ValueError("invalid PCAP packet length")
            frame = capture.read(included)
            if len(frame) != included:
                raise ValueError("truncated PCAP packet data")
            packet_count += 1
            tcp = _tcp_frame(frame)
            if not tcp:
                continue
            source, dest, sport, dport, sequence, _, flags, payload = tcp
            if dport == port and (server_ip is None or dest == server_ip):
                key, direction = (source, sport, dest, dport), "client"
            elif sport == port and (server_ip is None or source == server_ip):
                key, direction = (dest, dport, source, sport), "server"
            else:
                continue
            relevant += 1
            flow = active.get(key)
            fresh_syn = direction == "client" and flags & 2 and not flags & 16
            if flow is None or (fresh_syn and flow["client"].syn != sequence):
                if len(flows) >= MAX_FLOWS:
                    raise ValueError("too many IRC TCP connection epochs")
                flow = {"endpoints": key, "client": Direction(), "server": Direction()}
                flows.append(flow)
                active[key] = flow
            flow[direction].add(sequence, flags, payload)
    results = []
    for flow in flows:
        client_lines = flow["client"].lines(allow_legacy_lf=allow_legacy_lf)
        server_lines = flow["server"].lines()  # Replies always require CRLF.
        errors = flow["client"].errors + flow["server"].errors
        try:
            requests = [parse_message(line) for line in client_lines]
            replies = [parse_message(line) for line in server_lines]
        except ValueError as error:
            requests = replies = []
            errors.append(str(error))
        nicknames = [params[0] for _, command, params in requests if command == "NICK" and params and NICK.fullmatch(params[0])]
        users = [params for _, command, params in requests if command == "USER" and len(params) >= 4]
        joins = [params[0] for _, command, params in requests if command == "JOIN" and params and irc_casefold(params[0]) == CHANNEL]
        matching = []
        for nick in nicknames:
            addressed = [(prefix, command, params) for prefix, command, params in replies
                         if params and irc_casefold(params[0]) == irc_casefold(nick)]
            numerics = {command for _, command, _ in addressed}
            echo = any(command == "JOIN" and prefix.split("!", 1)[0] == nick and params and irc_casefold(params[0]) == CHANNEL
                       for prefix, command, params in replies)
            names = any(command == "353" and len(params) >= 4 and irc_casefold(params[2]) == CHANNEL
                        for _, command, params in addressed)
            end_names = any(command == "366" and len(params) >= 2 and irc_casefold(params[1]) == CHANNEL
                            for _, command, params in addressed)
            matching.append({"nick": nick, "welcome": "001" in numerics, "motd_complete": "376" in numerics,
                             "join_echo": echo, "names_reply": names, "end_names": end_names})
        passed = bool(users and joins and not errors and any(all(item[key] for key in
                      ("welcome", "motd_complete", "join_echo", "names_reply", "end_names")) for item in matching))
        results.append({"endpoints": flow["endpoints"], "client_lines": client_lines, "server_lines": server_lines,
                        "client_bare_lf_observed": flow["client"].bare_lf_observed,
                        "nicknames": nicknames, "user_seen": bool(users), "join_requested": bool(joins),
                        "matching_replies": matching, "errors": errors, "pass": passed})
    return {"scope": SCOPE, "pcap": str(Path(path)), "packets": packet_count, "irc_packets": relevant,
            "channel": CHANNEL, "allow_legacy_lf": allow_legacy_lf,
            "flows": results, "pass": any(flow["pass"] for flow in results)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--out", type=Path, required=True)
    serve.add_argument("--port", type=int, default=16667)
    serve.add_argument("--timeout", type=float, default=180)
    serve.add_argument("--linger", type=float, default=5)
    serve.add_argument("--allow-legacy-lf", action="store_true")
    analyze = commands.add_parser("analyze")
    analyze.add_argument("--pcap", type=Path, required=True)
    analyze.add_argument("--out", type=Path, required=True)
    analyze.add_argument("--port", type=int, default=16667)
    analyze.add_argument("--server-ip")
    analyze.add_argument("--allow-legacy-lf", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "serve":
        def notify(event):
            if event["event"] in {"ready", "join_complete", "finished"}:
                print(json.dumps(event), flush=True)
        result = IrcStage3Server(args.out, port=args.port, timeout=args.timeout,
                                linger=args.linger, on_event=notify, allow_legacy_lf=args.allow_legacy_lf).run()
    else:
        args.out.mkdir(parents=True, exist_ok=True)
        result = parse_pcap(args.pcap, port=args.port, server_ip=args.server_ip,
                            allow_legacy_lf=args.allow_legacy_lf)
        with (args.out / "pcap-summary.json").open("x", encoding="utf-8") as output:
            json.dump(result, output, indent=2)
            output.write("\n")
        print(json.dumps({"scope": SCOPE, "pass": result["pass"], "flows": len(result["flows"])}))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
