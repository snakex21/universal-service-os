# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real engine cancellation and two nested cooperative resolver contexts."""
from pathlib import Path
import os
import subprocess
import pytest
from test_winsock16_net import CORE, NET_DIR, _compiler, _compiler_env


@pytest.fixture(scope="session")
def cancel_peer(tmp_path_factory):
    compiler = _compiler()
    assert compiler, "a host C compiler is required"
    exe = tmp_path_factory.mktemp("socket-cancel") / ("peer.exe" if os.name == "nt" else "peer")
    sources = [Path(__file__).with_name("socket_cancel_harness.c"), NET_DIR / "win16_sock.c"]
    sources += [NET_DIR / name for name in CORE]
    built = subprocess.run(compiler + ["-std=c89", "-pedantic", "-Wall", "-Wextra", "-I", str(NET_DIR),
                                      "-o", str(exe)] + list(map(str, sources)),
                           capture_output=True, text=True, env=_compiler_env())
    assert built.returncode == 0, built.stdout + built.stderr
    return exe


@pytest.mark.parametrize("case,marker", [
    ("recv", "cancel_recv=1 socket_preserved=1 other_context_progress=1"),
    ("connect", "cancel_connect=1 slot_reusable=1 local_port_preserved=1 other_socket_preserved=1"),
    ("send", "cancel_send_accepted=4096 queued_bytes_preserved=1 other_context_progress=1"),
    ("send-full", "cancel_send_accepted=0 full_queue_preserved=1 other_context_progress=1"),
    ("accept", "cancel_accept=1 listener_preserved=1 other_socket_preserved=1"),
    ("close", "cancel_close=1 fin_wait=0 target_released=1 other_context_progress=1"),
    ("close-fin", "cancel_close=1 fin_wait=1 target_released=1 other_context_progress=1"),
    ("dns", "nested_dns_contexts=2 distinct_port_id=1 isolated_answers=1 cancel_outer=0 no_slot_leak=1"),
    ("dns-cancel", "nested_dns_contexts=2 distinct_port_id=1 isolated_answers=1 cancel_outer=1 no_slot_leak=1"),
    ("arp", "cancel_arp_wait=1 datagram_socket_preserved=1 other_socket_preserved=1"),
    ("tick", "timer_tick_cancel_hook_calls=0 nonblocking_cancel_hook_calls=0"),
])
def test_blocking_cancellation(cancel_peer, case, marker):
    result = subprocess.run([str(cancel_peer), case], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert marker in result.stdout
    assert "failures=0" in result.stdout
