# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Deterministic packet loss against the actual cooperative TCP engine."""
from pathlib import Path
import os
import subprocess
import pytest
from test_winsock16_net import CORE, NET_DIR, _compiler, _compiler_env


@pytest.fixture(scope="session")
def loss_peer(tmp_path_factory):
    compiler = _compiler()
    assert compiler, "a host C compiler is required"
    exe = tmp_path_factory.mktemp("socket-loss") / ("peer.exe" if os.name == "nt" else "peer")
    sources = [Path(__file__).with_name("socket_loss_harness.c"), NET_DIR / "win16_sock.c"]
    sources += [NET_DIR / name for name in CORE]
    built = subprocess.run(compiler + ["-std=c89", "-pedantic", "-Wall", "-Wextra", "-I", str(NET_DIR),
                                      "-o", str(exe)] + list(map(str, sources)),
                           capture_output=True, text=True, env=_compiler_env())
    assert built.returncode == 0, built.stdout + built.stderr
    return exe


@pytest.mark.parametrize("case,marker", [
    ("fast", "multiple_losses=1 recovered_without_rto=1"),
    ("multiple", "multiple_losses=3 recovered_without_rto=1"),
    ("partial", "partial_ack_inside_segment=107 subsequent_loss=1 recovered_without_rto=1"),
    ("queue", "fast_retransmit_queue_full=2 request_preserved=1 retry_budget_preserved=1"),
    ("timeout", "lost_fast_retransmission=1 rto_fallback=1010,2010 multiple_losses=2"),
    ("no-false", "window_stale_sequence_ack_not_duplicates=1 original_rto=1000"),
])
def test_loss_recovery(loss_peer, case, marker):
    result = subprocess.run([str(loss_peer), case], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert marker in result.stdout
    assert "idle_calls=0" in result.stdout
    assert "failures=0" in result.stdout
