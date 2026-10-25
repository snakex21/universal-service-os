#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded STANDARD/enhanced A/B tests on disposable installed-base overlays.

Separate exact runtime from closed stage3 evidence. No install or cleanup.
External provider binaries are control inputs only, never repository content.
"""
from pathlib import Path
import run_win16_stage3_app as app

app.stage.RUNTIME = Path(r'K:\USOS-VM\winsock-stdmode-20261025')
app.stage.FREE_RESERVE = 100 * 1024**3

if __name__ == '__main__':
    raise SystemExit(app.main())
