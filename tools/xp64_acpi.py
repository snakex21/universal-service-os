"""The community x64 ACPI for Windows XP x64 SP2 (NT 5.2 amd64) in the XP
package, the counterpart of the XP x86 community ACPI (xp_driver_overlay.py).

The stock 5.2 ACPI.SYS stops with 0xA5 on new AMD boards (X470). USOS ships
the community ACPI 2.0 build 5.2.3790.7777.4 (amd64 free build, pinned below;
provenance: media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x64) and
tools/nt5_storage_stage.sh applies it on every XP x64 target.

Package entries (under usr/lib/usos/nt5-storage/amd64/acpi/):
  acpi.sys, ReadMe.txt     the driver and its provenance note
  sp2/<sha256>/SP2.CAB     per XP x64 SP2 source: the ISO's AMD64\\SP2.CAB
                           with acpi.sys replaced (GUI-phase PnP and the
                           driver cache take it from there); <sha256> is the
                           hash of the ISO's own SP2.CAB, so the target only
                           replaces the cabinet it was built from
"""
from pathlib import Path
import hashlib, os, struct, subprocess, tempfile
import xp_cab

ROOT = Path(__file__).resolve().parents[1]
DRIVER_DIR = ROOT / 'media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x64/ACPI'
ACPI_SHA256 = '2aaac644abd3b94d8e1f41d1ea98ba88a18fe8c7273ba423796f0fdac20b6202'
SEVEN = os.environ.get('USOS_7Z', 'C:/Program Files/7-Zip/7z.exe')
PREFIX = 'amd64/acpi/'


def sha(b): return hashlib.sha256(b).hexdigest()


def check_pe(data):
    """x64 native driver: 'MZ', PE, machine 0x8664, PE32+, subsystem 1 (native)."""
    if data[:2] != b'MZ': raise ValueError('XP x64 ACPI: not an MZ image')
    p = struct.unpack_from('<I', data, 60)[0]
    if data[p:p + 4] != b'PE\0\0': raise ValueError('XP x64 ACPI: no PE header')
    machine = struct.unpack_from('<H', data, p + 4)[0]; opt = p + 24
    magic = struct.unpack_from('<H', data, opt)[0]; subsystem = struct.unpack_from('<H', data, opt + 68)[0]
    if machine != 0x8664 or magic != 0x20b: raise ValueError('XP x64 ACPI: not an x64 (AMD64, PE32+) image: machine=0x%x magic=0x%x' % (machine, magic))
    if subsystem != 1: raise ValueError('XP x64 ACPI: subsystem %d, not a native driver' % subsystem)
    return {'machine': machine, 'subsystem': subsystem}


def driver():
    data = (DRIVER_DIR / 'acpi.sys').read_bytes()
    if sha(data) != ACPI_SHA256: raise ValueError('XP x64 ACPI: acpi.sys does not match the pinned SHA-256')
    check_pe(data)
    return data


def is_xp64_sp2(iso):
    """An XP x64 / Server 2003 x64 SP2 source: AMD64\\SP2.CAB on the media."""
    listing = subprocess.run([SEVEN, 'l', '-ba', str(iso), 'AMD64\\SP2.CAB'], check=True, capture_output=True, text=True, errors='replace').stdout.upper()
    return 'AMD64\\SP2.CAB' in listing


def sp2_cab(iso, acpi):
    """(sha256 of the ISO's AMD64\\SP2.CAB, the cabinet with acpi.sys = acpi)."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp); orig = tmp / 'orig'; cab = tmp / 'cab'; out = tmp / 'out'
        for d in (orig, cab, out): d.mkdir()
        subprocess.run([SEVEN, 'e', '-y', str(iso), 'AMD64\\SP2.CAB', '-o' + str(orig)], check=True, stdout=subprocess.DEVNULL)
        original = (orig / 'SP2.CAB').read_bytes()
        subprocess.run([SEVEN, 'e', '-y', str(orig / 'SP2.CAB'), '-o' + str(cab)], check=True, stdout=subprocess.DEVNULL)
        found = [p for p in cab.iterdir() if p.name.lower() == 'acpi.sys']
        if len(found) != 1: raise ValueError('XP x64 SP2.CAB lacks a unique acpi.sys: ' + iso.name)
        found[0].write_bytes(acpi)
        stamps = xp_cab.stamps(original)
        directives = ['.OPTION EXPLICIT', '.Set Cabinet=on', '.Set Compress=on', '.Set CompressionType=MSZIP', '.Set MaxDiskSize=0',
                      '.Set CabinetNameTemplate=SP2.CAB', f'.Set DiskDirectoryTemplate="{out}"', f'.Set RptFileName="{tmp / "sp2.rpt"}"', f'.Set InfFileName="{tmp / "sp2.inf"}"']
        directives += ['"' + str(p) + '" ' + p.name for p in sorted(cab.iterdir()) if p.is_file()]
        (tmp / 'sp2.ddf').write_text('\n'.join(directives) + '\n', encoding='ascii')
        subprocess.run(['C:/Windows/System32/makecab.exe', '/F', str(tmp / 'sp2.ddf')], check=True, stdout=subprocess.DEVNULL)
        # Unchanged files keep Microsoft's date/time; the replaced ACPI gets the pinned one.
        xp_cab.pin(out / 'SP2.CAB', {n: t for n, t in stamps.items() if n != found[0].name.lower()})
        packed = (out / 'SP2.CAB').read_bytes()
        subprocess.run([SEVEN, 'e', '-y', str(out / 'SP2.CAB'), found[0].name, '-o' + str(tmp / 'verify')], check=True, stdout=subprocess.DEVNULL)
        if (tmp / 'verify' / found[0].name).read_bytes() != acpi: raise ValueError('rebuilt SP2.CAB does not hold the XP x64 ACPI')
    return sha(original), packed


def files(isos=()):
    """nt5-storage entries: the driver, its note and one SP2.CAB per XP x64 SP2 ISO."""
    acpi = driver()
    out = {PREFIX + 'acpi.sys': acpi, PREFIX + 'ReadMe.txt': (DRIVER_DIR / 'ReadMe.txt').read_bytes()}
    for iso in isos:
        source, packed = sp2_cab(iso, acpi)
        out[PREFIX + 'sp2/' + source + '/SP2.CAB'] = packed
        print('XP64_ACPI_SP2_CAB', Path(iso).name, 'source SP2.CAB', source, flush=True)
    return out
