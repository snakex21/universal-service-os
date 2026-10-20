"""The x86 PE10 donor release asset (user decision 2026-10-20):
tools/release/build_pe10_donor.py checks and tools/release/assemble_release.py
pins. No ISO is needed; the real donor stays in artifacts/ (git-ignored)."""
from pathlib import Path
import hashlib, json, sys, types

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/release'))
sys.path.insert(0, str(ROOT / 'tools/addons'))
import assemble_release  # noqa: E402
import build_pe10_donor  # noqa: E402


def image(index, name, arch, build=19041):
    return {'index': index, 'name': name, 'arch': arch, 'major': 10, 'minor': 0, 'build': build, 'spbuild': 6396}


def test_wim_gate_per_architecture():
    x86 = [image(1, 'Microsoft Windows PE (x86)', 0), image(2, 'Microsoft Windows Setup (x86)', 0)]
    assert build_pe10_donor.check_wim('x86', 2, 2, x86) == 19041
    assert build_pe10_donor.donor_name('x86', 19041) == 'PE10_x86_19041_USOS.iso'
    with pytest.raises(SystemExit):
        build_pe10_donor.check_wim('x64', 2, 2, x86)  # wrong architecture
    with pytest.raises(SystemExit):
        build_pe10_donor.check_wim('x86', 2, 1, x86)  # boot index is not Setup
    win11 = [image(1, 'Microsoft Windows PE (x86)', 0, 22000), image(2, 'Microsoft Windows Setup (x86)', 0, 22000)]
    with pytest.raises(SystemExit):
        build_pe10_donor.check_wim('x86', 2, 2, win11)  # not a PE 10 donor build
    x64 = [image(1, 'Microsoft Windows PE (x64)', 9), image(2, 'Microsoft Windows Setup (x64)', 9)]
    assert build_pe10_donor.check_wim('x64', 2, 2, x64) == 19041


def test_x86_donor_members_include_the_bios_boot_manager():
    # win-nt6-x86-uefi-csmwrap stages the donor's own root bootmgr (tools/vista_csmwrap_target.sh).
    assert build_pe10_donor.MEMBERS['x86'][0] == 'bootmgr'
    assert set(build_pe10_donor.MEMBERS['x64']) < set(build_pe10_donor.MEMBERS['x86'])


def test_release_lists_and_pins_the_x86_zip():
    names = assemble_release.component_names('1.0.0')
    assert names[:2] == ['USOS-1.0.0-WinPE-PE10-donor.zip', 'USOS-1.0.0-WinPE-PE10-x86-donor.zip']
    assert assemble_release.WINPE_X86_DONOR_NAME == 'PE10_x86_19041_USOS.iso'
    assert len(assemble_release.WINPE_X86_DONOR_SHA256) == 64
    text = assemble_release.winpe_x86_readme('1.0.0', 'B1')
    assert assemble_release.WINPE_X86_DONOR_SHA256 in text and str(assemble_release.WINPE_X86_DONOR_SIZE) in text
    assert 'Programs\\USOS\\WinPE\\PE10_x86_19041_USOS.iso' in text


def test_third_party_lists_the_x86_donor():
    data = json.loads((ROOT / 'tools/release/third-party.json').read_text(encoding='utf-8'))
    entries = {c['id']: c for c in data['components']} if isinstance(data, dict) else {c['id']: c for c in data}
    x86 = entries['microsoft-winpe-pe10-x86']
    assert x86['license'] == 'LicenseRef-Microsoft-redistributed-by-user' and 'PE10_x86_19041_USOS.iso' in x86['name']


def test_wrong_x86_donor_is_refused(tmp_path, monkeypatch):
    x64 = tmp_path / 'PE10_x64_19041_USOS.iso'
    x64.write_bytes(b'x64 donor')
    monkeypatch.setattr(assemble_release, 'WINPE_DONOR_NAME', x64.name)
    monkeypatch.setattr(assemble_release, 'WINPE_DONOR_SIZE', x64.stat().st_size)
    monkeypatch.setattr(assemble_release, 'WINPE_DONOR_SHA256', hashlib.sha256(b'x64 donor').hexdigest())
    fake = tmp_path / 'x86' / 'PE10_x86_19041_USOS.iso'
    fake.parent.mkdir()
    fake.write_bytes(b'not the validated donor')
    args = types.SimpleNamespace(winpe=x64, winpe_x86=fake, xp=[], legacy_ms=[])
    out = tmp_path / 'out'
    out.mkdir()
    with pytest.raises(SystemExit, match='x86 WinPE donor is not the validated'):
        assemble_release.build_components(args, out, '1.0.0', 'B1', 1792510607)
    assert (out / 'USOS-1.0.0-WinPE-PE10-donor.zip').is_file()
    assert not (out / 'USOS-1.0.0-WinPE-PE10-x86-donor.zip').exists()


@pytest.mark.skipif(not (ROOT / 'artifacts/pe10-x86/PE10_x86_19041_USOS.iso').is_file(), reason='donor ISO not built in this checkout')
def test_built_donor_matches_the_pin():
    iso = ROOT / 'artifacts/pe10-x86/PE10_x86_19041_USOS.iso'
    assert iso.stat().st_size == assemble_release.WINPE_X86_DONOR_SIZE
    assert assemble_release.sha256(iso) == assemble_release.WINPE_X86_DONOR_SHA256
