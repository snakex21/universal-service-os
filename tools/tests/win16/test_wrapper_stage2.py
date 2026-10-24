# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
"""Execute the actual wrapper with native pointers and fake Windows events.

This supplements QEMU; it does not claim to emulate segmented pointers,
PASCAL stack conventions, NE loading, DPMI or a real Windows timer.
"""
from pathlib import Path
import os
import subprocess
import pytest
from test_winsock16_net import CORE, NET_DIR, _compiler, _compiler_env


@pytest.fixture(scope="session")
def wrapper_bridge(tmp_path_factory):
    compiler = _compiler()
    assert compiler
    directory = Path(__file__).parent
    exe = tmp_path_factory.mktemp("wrapper-stage2") / ("wrapper.exe" if os.name == "nt" else "wrapper")
    sources = [directory / "wrapper_harness.c", NET_DIR / "win16_sock.c", NET_DIR / "dns_extra.c"]
    sources += [NET_DIR / name for name in CORE]
    result = subprocess.run(compiler + ["-std=c89", "-Wall", "-Wextra", "-I", str(directory / "shim"),
                                       "-I", str(NET_DIR), "-o", str(exe)] + list(map(str, sources)),
                            capture_output=True, text=True, env=_compiler_env())
    assert result.returncode == 0, result.stdout + result.stderr
    return exe


@pytest.mark.parametrize("case,marker", [
    ("select", "empty_select=WSAEINVAL"),
    ("rearm", "async_nonblock=1 read_rearm=1 write_rearm=1"),
    ("name", "cancel_no_completion=1 hostent_native_pointers=1 local_hostname=1"),
    ("error", "invalid_optlen_preserves_so_error=1"),
    ("blocking", "per_task_reentry=1 cancellation=WSAEINTR hook_restored=1 nonblock_no_hook=1"),
    ("tasks", "two_task_errors=1 socket_ownership=1 independent_results=1 separate_windows_jobs=1 survivor_transport=1"),
    ("nested", "nested_tasks=1 separate_cancel_flags=1 transport_survives_nested_cleanup=1"),
    ("cancel", "select_cancel=1 forward_dns_cancel=1 reverse_dns_cancel=1 state_restored=1"),
    ("contexts", "eight_context_limit=1 freed_context_reuse=1 startup_reference_counts=1 remaining_app_survives=1"),
])
def test_real_wrapper_with_fake_windows(wrapper_bridge, case, marker):
    result = subprocess.run([str(wrapper_bridge), case], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert marker in result.stdout
    assert "failures=0" in result.stdout
