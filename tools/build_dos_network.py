"""DOS network helpers for the MS-DOS installer (INSTALL.BAT -> C:\\NET).

USOSPKT.COM: own packet driver for the Intel igb family (I211 / I210 /
82576), src/platform/bios/msdos/usospkt.S, assembled with zig cc and linked
at 0100h like USOSKBC.COM. mTCP 2026-10-10 (GPL-3.0, Michael Brutman):
pinned binaries from tools/vendor/mtcp/2026-10-10 plus its complete source
zip (MTCPSRC.ZIP) and the licence (MTCP.TXT). NETSTART.BAT loads the driver
and runs DHCP (src/platform/bios/msdos/network_start.cmd).
Design and test results: docs/dos-usospkt-2026-10-23.md.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MTCP_VERSION = '2026-10-10'
MTCP_TOOLS = ('DHCP.EXE', 'PING.EXE', 'HTGET.EXE', 'FTP.EXE', 'TELNET.EXE', 'SNTP.EXE', 'NC.EXE',
              'DNSTEST.EXE', 'PKTTOOL.EXE')
MTCP_SOURCE = f'mTCP-src_{MTCP_VERSION}.zip'
# Every name INSTALL.BAT copies into C:\NET (installer payload list too).
NET_FILES = ('USOSPKT.COM', 'NETSTART.BAT', 'MTCP.DEF', 'MTCP.TXT', 'MTCPSRC.ZIP') + MTCP_TOOLS


def zig() -> str:
    return os.environ.get('USOS_ZIG', str(ROOT / 'tools/zig/zig.exe'))


def build_usospkt(root: Path, out: Path, work: Path) -> Path:
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.environ.get('USOS_ZIG_CACHE', str(root / 'tools/cache/zig-global')))
    obj, elf, com = work / 'usospkt.o', work / 'usospkt.elf', out / 'USOSPKT.COM'
    subprocess.run([zig(), 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(root / 'src/platform/bios/msdos/usospkt.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig(), 'ld.lld', '-m', 'elf_i386', '-T', str(root / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig(), 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    check_usospkt(com.read_bytes())
    return com


def build_usospkt_queue(root: Path, out: Path, work: Path) -> Path:
    """Experimental queue binary, never part of the default NET_FILES payload."""
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.environ.get('USOS_ZIG_CACHE', str(root / 'tools/cache/zig-global')))
    obj, elf, com = work / 'usospktq.o', work / 'usospktq.elf', out / 'USOSPKTQ.COM'
    subprocess.run([zig(), 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(root / 'src/platform/bios/msdos/usospktq.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig(), 'ld.lld', '-m', 'elf_i386', '-T', str(root / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig(), 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    check_usospkt(com.read_bytes())
    return com


def check_usospkt(data: bytes):
    """Layout the packet driver spec and the second-load check rely on."""
    if not 4096 <= len(data) <= 16384:
        raise ValueError('unexpected USOSPKT.COM size %d' % len(data))
    at = data.find(b'PKT DRVR\0USOSPKT')
    if at < 3 or data[at - 3] != 0xE9:
        raise ValueError('USOSPKT.COM: "PKT DRVR" must follow a 3-byte JMP at the packet entry')
    if data[:1] not in (b'\xe9', b'\xeb'):
        raise ValueError('USOSPKT.COM: must start with a jump to the install code')


def mtcp_vendor(root: Path) -> Path:
    vendor = root / 'tools/vendor/mtcp' / MTCP_VERSION
    manifest = json.loads((vendor / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        path = vendor / name
        if not path.is_file():
            # The source zip is not tracked (tools/vendor/**/*.zip is ignored);
            # GPL-3.0 needs it next to the binaries, so the build stops.
            raise FileNotFoundError(f'mTCP: {path} missing; download {manifest["source"].split()[0]} '
                                    f'(sha256 {expected}) into {vendor}')
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('mTCP checksum mismatch: ' + name)
    return vendor


def dos_text(text: str) -> bytes:
    return text.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


def build(root: Path = ROOT, out: Path | None = None) -> list:
    out = (out or root / 'zig-out/dos-native/msdos').resolve()
    work = root / 'zig-out/dos-network'
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    com = build_usospkt(root, out, work)
    vendor = mtcp_vendor(root)
    for name in MTCP_TOOLS:
        shutil.copyfile(vendor / name, out / name)
    shutil.copyfile(vendor / MTCP_SOURCE, out / 'MTCPSRC.ZIP')
    notice = ((vendor / 'SOURCES.txt').read_text(encoding='ascii') + '\n' + '-' * 72 + '\n\n'
              + (vendor / 'README.TXT').read_text(encoding='latin-1') + '\n' + '-' * 72 + '\n\n'
              + (vendor / 'COPYING.TXT').read_text(encoding='latin-1'))
    (out / 'MTCP.TXT').write_bytes(notice.replace('\r\n', '\n').replace('\n', '\r\n').encode('latin-1'))
    (out / 'MTCP.DEF').write_bytes(b'PACKETINT 0x60\r\nHOSTNAME USOSDOS\r\n')
    start = (root / 'src/platform/bios/msdos/network_start.cmd').read_text(encoding='ascii')
    for line in start.splitlines():
        if len(line) > 127:
            raise ValueError('network_start.cmd: MS-DOS command line exceeds 127 bytes')
    (out / 'NETSTART.BAT').write_bytes(dos_text(start))
    print(f'[PASS] DOS network: {com.name} {com.stat().st_size} bytes (own igb packet driver), '
          f'mTCP {MTCP_VERSION} ({len(MTCP_TOOLS)} tools + source + licence), NETSTART.BAT')
    return [out / n for n in NET_FILES]


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path)
    a = p.parse_args()
    build(ROOT, a.out)
