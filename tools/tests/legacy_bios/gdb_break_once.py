#!/usr/bin/env python3
import argparse
import socket


def checksum(payload: bytes) -> bytes:
    return f"{sum(payload) & 0xff:02x}".encode()


def packet(payload: str) -> bytes:
    raw = payload.encode()
    return b"$" + raw + b"#" + checksum(raw)


def recv_packet(sock: socket.socket) -> str:
    while True:
        ch = sock.recv(1)
        if not ch:
            raise RuntimeError("GDB connection closed")
        if ch == b"$":
            break
    data = bytearray()
    while True:
        ch = sock.recv(1)
        if ch == b"#":
            break
        data += ch
    got = sock.recv(2)
    want = checksum(bytes(data))
    if got.lower() != want:
        raise RuntimeError(f"GDB checksum mismatch: got {got!r}, expected {want!r}")
    sock.sendall(b"+")
    return data.decode(errors="replace")


def send_cmd(sock: socket.socket, cmd: str, expect_reply: bool = True) -> str:
    sock.sendall(packet(cmd))
    ack = sock.recv(1)
    if ack != b"+":
        raise RuntimeError(f"GDB command {cmd!r} was not ACKed: {ack!r}")
    return recv_packet(sock) if expect_reply else ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--address", type=lambda x: int(x, 0), required=True)
    args = ap.parse_args()

    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        sock.settimeout(30)
        stop = send_cmd(sock, "?")
        print(f"INITIAL_STOP={stop}")
        result = send_cmd(sock, f"Z1,{args.address:x},1")
        if result != "OK":
            raise RuntimeError(f"hardware breakpoint rejected: {result}")
        print(f"BREAKPOINT=0x{args.address:X}")
        sock.sendall(packet("c"))
        ack = sock.recv(1)
        if ack != b"+":
            raise RuntimeError(f"continue was not ACKed: {ack!r}")
        stopped = recv_packet(sock)
        print(f"STOP={stopped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
