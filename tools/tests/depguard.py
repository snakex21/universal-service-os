"""Runtime probes for optional dependencies of the host test suite.

Every probe resolves its path when it is called, never at import time, so a
worktree that gains ``tools/zig`` or ``tools/cache/openwatcom/ow-*`` later
needs no edit here.  The tests use these helpers to skip with a clear message
("brak ... - uruchom build.bat") instead of failing with FileNotFoundError.

Nothing in this module changes an assertion: it only decides whether the
dependency exists.
"""
from __future__ import annotations

import os
import shutil
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD_HINT = 'uruchom build.bat'
CACHE_HINT = 'uruchom build.bat (albo ustaw USOS_WATCOM)'


def zig() -> Path | None:
    """Pinned Zig compiler: USOS_ZIG override, else tools/zig/zig.exe."""
    override = os.environ.get('USOS_ZIG')
    if override and Path(override).is_file():
        return Path(override)
    candidate = ROOT / 'tools/zig/zig.exe'
    return candidate if candidate.is_file() else None


def require_zig(feature: str = 'kompilator Zig') -> Path:
    found = zig()
    if found is None:
        raise unittest.SkipTest(
            f'brak {feature}: tools/zig/zig.exe nie istnieje - {BUILD_HINT}')
    return found


def watcom() -> Path | None:
    """Open Watcom root: USOS_WATCOM override, else the newest ow-* in tools/cache.

    The buildkit unpacks snapshots as tools/cache/openwatcom/ow-<hash>; only a
    tree that really carries binnt64/wcc.exe is accepted.
    """
    override = os.environ.get('USOS_WATCOM')
    if override and Path(override).is_dir():
        return Path(override)
    cache = ROOT / 'tools/cache/openwatcom'
    if not cache.is_dir():
        return None
    for candidate in sorted((p for p in cache.glob('ow-*') if p.is_dir()), reverse=True):
        if (candidate / 'binnt64/wcc.exe').is_file() or (candidate / 'binnt/wcc.exe').is_file():
            return candidate
    return None


def require_watcom(component: str = 'binnt64/wcc.exe') -> Path:
    found = watcom()
    if found is None:
        raise unittest.SkipTest(
            f'brak Open Watcom ({component}): USOS_WATCOM nie ustawione i brak '
            f'tools/cache/openwatcom/ow-* - {CACHE_HINT}')
    return found


def path(rel: str) -> Path | None:
    """Repo-relative artefact (file or directory) resolved at call time."""
    candidate = ROOT / rel
    return candidate if candidate.exists() else None


def require_path(rel: str, feature: str | None = None) -> Path:
    found = path(rel)
    if found is None:
        raise unittest.SkipTest(f'brak artefaktu {rel} - {feature or BUILD_HINT}')
    return found


def posix_shell() -> Path | None:
    """sh for the shell-driven tests: PATH first, then Git for Windows."""
    found = shutil.which('sh')
    if found:
        return Path(found)
    for candidate in (Path(r'C:\Program Files\Git\usr\bin\sh.exe'),
                      Path(r'C:\Program Files (x86)\Git\usr\bin\sh.exe')):
        if candidate.is_file():
            return candidate
    return None


def coreutils() -> bool:
    """True when the sh environment also carries the POSIX tools the scripts call."""
    shell = posix_shell()
    if shell is None:
        return False
    return all(shutil.which(tool) or (shell.parent / f'{tool}.exe').is_file()
               for tool in ('rm', 'cp', 'mv'))


def require_posix_shell(tools: bool = False, feature: str = 'POSIX sh') -> Path:
    shell = posix_shell()
    if shell is None:
        raise unittest.SkipTest(
            f'brak {feature}: nie ma sh w PATH ani w Git for Windows')
    if tools and not coreutils():
        raise unittest.SkipTest(
            f'brak {feature}: sh jest ({shell}), ale rm/cp/mv nie sa na PATH')
    return shell
