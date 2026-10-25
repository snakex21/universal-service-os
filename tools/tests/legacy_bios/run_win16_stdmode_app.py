#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded STANDARD/enhanced A/B tests on disposable installed-base overlays.

Separate exact runtime from closed stage3 evidence. No install or cleanup.
External provider binaries are control inputs only, never repository content.
"""
from pathlib import Path
import os
import sys
import run_win16_stage3_app as app

# Runtime directory (VM images, overlays, evidence) comes from the
# environment so no machine-specific drive path lives in the repository.
RUNTIME_ENV = 'USOS_WS_STDMODE_RUNTIME'
app.stage.FREE_RESERVE = 100 * 1024**3

if __name__ == '__main__':
    runtime = os.environ.get(RUNTIME_ENV)
    if not runtime:
        sys.exit(f'set {RUNTIME_ENV} to the standard-mode runtime directory')
    app.stage.RUNTIME = Path(runtime)
    raise SystemExit(app.main())
