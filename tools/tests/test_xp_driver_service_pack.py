"""tools/xp_driver_stage.sh: the SP3 gate names the service level of the media.

RTM, SP1 and SP2 discs all carry the 5.1.2600 setup build, so the driver bundle
preflight can only tell them apart by the disc root markers (WIN51IP.SPn). This
test pins the marker detection and the refusal message that now names the level
instead of claiming "XP Professional SP3" without saying what was found.

    python -m pytest tools/tests/test_xp_driver_service_pack.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'tools' / 'xp_driver_stage.sh'
SH = next(
    (p for p in (r'C:\msys64\usr\bin\sh.exe', r'C:\Program Files\Git\usr\bin\sh.exe', shutil.which('sh') or '') if p and Path(p).exists()),
    None,
)
# The shell's own coreutils (tr) first: PowerShell runs lack them on PATH.
SH_ENV = dict(os.environ)
if SH:
    SH_ENV['PATH'] = str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', '')

pytestmark = pytest.mark.skipif(SH is None, reason='sh not found')


def posix(path: Path) -> str:
    s = str(path.resolve()).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if s[1:2] == ':' else s


def disc(tmp_path: Path, markers: list[str], lowercase: bool = False) -> Path:
    root = tmp_path / 'source-root'
    root.mkdir()
    for marker in markers:
        name = marker.lower() if lowercase else marker
        (root / name).write_bytes(b'')
    return root


def sh(command: str, source_root: Path, system: str = 'windows-xp') -> subprocess.CompletedProcess:
    env = dict(SH_ENV)
    env['SOURCE_ROOT'] = posix(source_root)
    env['NT5_SYSTEM'] = system
    return subprocess.run(
        [SH, '-c', f". '{posix(LIB)}'; {command}"],
        capture_output=True, text=True, env=env,
    )


@pytest.mark.parametrize(
    'markers,level',
    [
        ([], 'unknown'),
        (['WIN51', 'WIN51IP'], 'RTM'),
        (['WIN51', 'WIN51IP', 'WIN51IP.SP1'], 'SP1'),
        (['WIN51', 'WIN51IP', 'WIN51IP.SP1', 'WIN51IP.SP2'], 'SP2'),
        (['WIN51', 'WIN51IP', 'WIN51IP.SP1', 'WIN51IP.SP2', 'WIN51IP.SP3'], 'SP3'),
    ],
)
def test_service_pack_from_markers(tmp_path: Path, markers: list[str], level: str) -> None:
    root = disc(tmp_path, markers)
    r = sh('usos_xp_media_service_pack "$SOURCE_ROOT"', root)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == level


def test_lower_case_markers_are_identified(tmp_path: Path) -> None:
    root = disc(tmp_path, ['win51ip', 'win51ip.sp2'], lowercase=True)
    r = sh('usos_xp_media_service_pack "$SOURCE_ROOT"', root)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == 'SP2'


def test_highest_marker_wins(tmp_path: Path) -> None:
    # SP3 media keep the SP1/SP2 markers: Setup only looks for the newest one.
    root = disc(tmp_path, ['WIN51IP.SP1', 'WIN51IP.SP3', 'WIN51IP.SP2'])
    assert sh('usos_xp_media_service_pack "$SOURCE_ROOT"', root).stdout.strip() == 'SP3'


@pytest.mark.parametrize(
    'markers,level',
    [
        (['WIN51', 'WIN51IP'], 'RTM'),
        (['WIN51IP', 'WIN51IP.SP1'], 'SP1'),
        (['WIN51IP', 'WIN51IP.SP1', 'WIN51IP.SP2'], 'SP2'),
    ],
)
def test_preflight_refusal_names_the_media_level(tmp_path: Path, markers: list[str], level: str) -> None:
    root = disc(tmp_path, markers)
    r = sh('usos_xp_driver_preflight', root)
    assert r.returncode == 1
    assert 'requires XP Professional SP3' in r.stdout
    assert f'(media: {level})' in r.stdout


def test_preflight_unknown_media_reports_unknown(tmp_path: Path) -> None:
    root = disc(tmp_path, [])
    r = sh('usos_xp_driver_preflight', root)
    assert r.returncode == 1
    assert '(media: unknown)' in r.stdout


def test_sp3_media_pass_the_version_gate(tmp_path: Path) -> None:
    # No driver bundle on this host, so the original refusal stays: the point is
    # that the SP3 gate did not fire and the message is the bundle one.
    root = disc(tmp_path, ['WIN51', 'WIN51IP', 'WIN51IP.SP1', 'WIN51IP.SP2', 'WIN51IP.SP3'])
    r = sh('usos_xp_driver_preflight', root)
    assert r.returncode == 1
    assert 'requires XP Professional SP3' not in r.stdout
    assert 'ISO differs from the prepared driver package' in r.stdout
