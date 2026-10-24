# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Abortive close checks actual Ethernet/TCP bytes and socket ownership."""
from pathlib import Path
import os
import subprocess
import pytest
from test_winsock16_net import CORE, NET_DIR, _compiler, _compiler_env


@pytest.fixture(scope="session")
def abort_peer(tmp_path_factory):
    compiler = _compiler()
    assert compiler, "a host C compiler is required"
    exe = tmp_path_factory.mktemp("socket-abort") / ("peer.exe" if os.name == "nt" else "peer")
    sources = [Path(__file__).with_name("socket_abort_harness.c"), NET_DIR / "win16_sock.c"]
    sources += [NET_DIR / name for name in CORE]
    built = subprocess.run(compiler + ["-std=c89", "-pedantic", "-Wall", "-Wextra", "-I", str(NET_DIR),
                                      "-o", str(exe)] + list(map(str, sources)),
                           capture_output=True, text=True, env=_compiler_env())
    assert built.returncode == 0, built.stdout + built.stderr
    return exe


@pytest.mark.parametrize("case,marker", [
    ("connected", "connected_rst=1 pending_bytes_discarded=0 other_socket_io=1"),
    ("pending", "connected_rst=1 pending_bytes_discarded=1176 other_socket_io=1"),
    ("connecting", "connecting_rst=1 unknown_peer_sequence_no_ack=1"),
    ("udp", "udp_no_wire=1 unconnected_no_wire=1 invalid_double_close=1"),
    ("listener", "backlog_established_and_syn_rcvd_reset=2 accepted_io_preserved=1"),
    ("listener-full", "unrelated_preserved=1 reset_result=ENOBUFS"),
    ("full", "reset_tx_failure=ENOBUFS slot_closed=1 no_retry=1"),
    ("failed-send", "reset_tx_failure=EHOSTUNREACH slot_closed=1 no_retry=1"),
    ("no-arp", "unresolved_next_hop=EHOSTUNREACH no_arp_wait_or_send=1 slot_closed=1"),
])
def test_abortive_close(abort_peer, case, marker):
    result = subprocess.run([str(abort_peer), case], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert marker in result.stdout
    assert "idle_calls=0" in result.stdout
    assert "cancel_hook_calls=0" in result.stdout
    assert "failures=0" in result.stdout
