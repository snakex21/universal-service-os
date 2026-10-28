# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Wire-level cooperative socket tests: no Windows, driver or network."""
from pathlib import Path
import os
import subprocess
import pytest
from test_winsock16_net import CORE, NET_DIR, _compiler, _compiler_env


@pytest.fixture(scope="session")
def stage2_peer(tmp_path_factory):
    compiler = _compiler()
    assert compiler, "a host C compiler is required"
    exe = tmp_path_factory.mktemp("socket-stage2") / ("peer.exe" if os.name == "nt" else "peer")
    sources = [Path(__file__).with_name("socket_stage2_harness.c"), NET_DIR / "win16_sock.c"]
    sources += [NET_DIR / source for source in CORE]
    built = subprocess.run(compiler + ["-std=c89", "-pedantic", "-Wall", "-Wextra", "-I", str(NET_DIR),
                                      "-o", str(exe)] + list(map(str, sources)),
                           capture_output=True, text=True, env=_compiler_env())
    assert built.returncode == 0, built.stdout + built.stderr
    return exe


@pytest.mark.parametrize("case,marker", [
    ("multi", "sixteen=16 out_of_order=3000 independent_rx=1 peek=1"),
    ("window", "multi_segment_flight=2 partial_ack=1 receive_window=4096 retransmitted_tail=500"),
    ("backoff", "rto_ms=1000,2000,4000,8000 duplicate_ack_does_not_reset=1 timeout=31000"),
    ("listener", "listen_handshake=1 accept=1 half_close=1"),
    ("wrap", "receive_sequence_wrap=1 out_of_order_fin=1"),
    ("udp", "udp_sendto=1 recvfrom=1 empty_datagram=1"),
    ("persist", "zero_window_probe=1 resumed_bytes=100"),
])
def test_cooperative_wire_cases(stage2_peer, case, marker):
    result = subprocess.run([str(stage2_peer), case], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert marker in result.stdout
    assert "idle_calls=0" in result.stdout
    assert "failures=0" in result.stdout
