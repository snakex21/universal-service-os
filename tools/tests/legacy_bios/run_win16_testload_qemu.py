#!/usr/bin/env python3
"""QEMU harness: does Windows 3.1 load the USOS WINSOCK.DLL and can a Win16
application call WSAStartup?

One command, repeatable:

    python tools/tests/legacy_bios/run_win16_testload_qemu.py \
        --dos-iso "OS/DOS/MS-DOS/MS-DOS 6.22 EN.iso" \
        --win-iso "OS/Windows/Windows 3.1/Windows 3.1 PL.iso" \
        --dos-payload zig-out/dos-native/msdos \
        --dos-boot-sector zig-out/win16/dosboot.vbr

The layout is the one USOS itself installs (``W3START.BAT`` of the MS-DOS
payload): MS-DOS 6.22 in the root of an active FAT16 partition, ``C:\\DOS``,
``C:\\USOSW3`` with the scripted-answer driver, ``C:\\W31`` with the flat
Windows 3.1 Setup directory and ``SETUP.EXE /H:USOS.SHH`` driven by
``USOSKBC.COM C:\\USOSW3\\SETUP.KEY`` - the Polish edition shows two text pages
(keyboard layout, code page 852) that the answer file cannot reach and that
``USOSKBC.COM`` fills in, so Setup needs no keyboard at all.

What the script does:

1. builds ``zig-out/win16/WINSOCK.DLL`` and ``zig-out/win16/TESTLOAD.EXE``
   (``tools/build_win16_winsock.py``: Open Watcom 16-bit, ``USOS_WATCOM``);
2. writes a 128 MiB FAT16 image with ``tools/win16_disk.py`` (MBR + one active
   partition; the MS-DOS boot sector comes from the MS-DOS media - only its
   BPB is replaced); copies ``USOS.SHH``, ``USOSKBC.COM`` and ``USOSKEY.DRV``
   **bit for bit** from the MS-DOS payload directory and compiles
   ``SETUP.KEY`` from ``src/platform/bios/msdos/keys/W3PL.txt`` with
   ``tools/usos_keyscript.py`` (the same builder as the production key scripts);
3. installs Windows 3.1 **once**: QEMU (SeaBIOS, pentium3, 64 MiB, no display,
   no network) boots ``AUTOEXEC.BAT`` -> ``USOSKBC.COM`` + ``SETUP.EXE
   /H:USOS.SHH``; the harness waits for ``SETUP-DONE`` on COM1;
4. turns the installed image into the read-only base ``win31-base.qcow2``;
5. every further run creates ``run-<tag>.qcow2`` (``qemu-img create -f qcow2
   -b win31-base.qcow2``), materialises it to raw, stages the payload there
   with ``win16_disk.Fat16Volume`` (``WINSOCK.DLL`` -> ``C:\\WINDOWS\\SYSTEM``,
   ``TESTLOAD.EXE`` -> ``C:\\TEST``, per-run ``AUTOEXEC.BAT``), boots it and
   shuts the VM down, so the installed Windows is never reinstalled and the
   base image is never modified;
6. starts ``WIN.COM /S /B C:\\TEST\\TESTLOAD.EXE`` (standard mode), waits for
   ``USOS-WIN16-DONE`` on COM1, kills the VM and reads ``C:\\WSTEST.LOG`` back.

PASS: the log carries ``USOS WINSOCK OK version=1.1 high=... desc=...``.
Negative run (``--negative``): the DLL is removed from ``C:\\WINDOWS\\SYSTEM``
and the log must carry ``USOS WINSOCK FAIL err=...``.

Evidence goes to ``zig-out/win16/qemu/`` (``WSTEST.LOG``, ``result.txt``,
serial logs and screenshots; nothing there is committed).  Staging into the
image uses ``tools/win16_disk.py`` (stdlib only): no mtools, no WSL, no loop
mount and no administrator rights are needed.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))

import win16_disk  # noqa: E402  (tools/win16_disk.py)
import usos_keyscript  # noqa: E402  (tools/usos_keyscript.py)

ARTIFACT_DIR = ROOT / 'zig-out' / 'win16'
DLL = ARTIFACT_DIR / 'WINSOCK.DLL'
EXE = ARTIFACT_DIR / 'TESTLOAD.EXE'
EVIDENCE = ARTIFACT_DIR / 'qemu'
BASE_RAW = EVIDENCE / 'win31-base.img'
BASE_QCOW2 = EVIDENCE / 'win31-base.qcow2'
KEY_SOURCE = ROOT / 'src' / 'platform' / 'bios' / 'msdos' / 'keys' / 'W3PL.txt'

PAYLOAD_FILES = ('USOS.SHH', 'USOSKBC.COM', 'USOSKEY.DRV')

CONFIG_SYS_INSTALL = 'FILES=40\r\nBUFFERS=30\r\nSHELL=C:\\COMMAND.COM /P /E:512\r\n'

# Install boot: USOSKBC.COM reads the answers from SETUP.KEY while
# SETUP.EXE /H:USOS.SHH installs.  Exactly the W3START.BAT sequence.
AUTOEXEC_INSTALL = '''@ECHO OFF
PROMPT $P$G
SET TEMP=C:\\TEMP
PATH C:\\;C:\\DOS;C:\\W31;C:\\USOSW3
ECHO INSTALL-START>COM1
C:\\USOSW3\\USOSKBC.COM{kbc} C:\\USOSW3\\SETUP.KEY > C:\\KBC.LOG
CD C:\\W31
SETUP.EXE /H:USOS.SHH
ECHO INSTALL-EXIT>COM1
IF NOT EXIST C:\\WINDOWS\\WIN.COM GOTO nosetup
ECHO SETUP-DONE>COM1
GOTO end
:nosetup
ECHO SETUP-FAILED>COM1
:end
'''

# Test boot: standard mode, boot log, the application quits by itself.
AUTOEXEC_RUN = '''@ECHO OFF
PROMPT $P$G
SET TEMP=C:\\TEMP
PATH C:\\;C:\\DOS;C:\\WINDOWS;C:\\WINDOWS\\SYSTEM;C:\\TEST
ECHO WIN-START>COM1
C:\\WINDOWS\\WIN.COM /S /B C:\\TEST\\TESTLOAD.EXE
ECHO WIN-END>COM1
ECHO USOS-WIN16-DONE>COM1
'''

CONFIG_SYS_RUN_HEAD = 'DEVICE=C:\\WINDOWS\\HIMEM.SYS\r\nDOS=HIGH\r\n'
CONFIG_SYS_RUN_TAIL = ('FILES=40\r\nBUFFERS=30\r\n'
                       'SHELL=C:\\COMMAND.COM /P /E:512\r\nSTACKS=9,256\r\n')


def log(message: str) -> None:
    print(message, flush=True)


def find_qemu(explicit: str | None) -> Path:
    for candidate in (explicit, os.environ.get('USOS_QEMU'),
                      str(ROOT / 'tools' / 'qemu' / 'qemu-system-x86_64.exe'),
                      shutil.which('qemu-system-x86_64')):
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise SystemExit('brak qemu-system-x86_64 - podaj --qemu albo ustaw USOS_QEMU')


def find_qemu_img(qemu: Path) -> Path:
    for candidate in (os.environ.get('USOS_QEMU_IMG'),
                      str(qemu.with_name('qemu-img.exe')), shutil.which('qemu-img')):
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise SystemExit('brak qemu-img obok qemu-system-x86_64')


def require(path: Path, what: str) -> Path:
    if not path.is_file():
        raise SystemExit('%s: brak %s' % (what, path))
    return path


def run_tool(command: list[str], what: str) -> None:
    log('%s: %s' % (what, ' '.join(command)))
    result = subprocess.run(command, cwd=str(ROOT), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if result.returncode != 0:
        log(result.stdout.decode('latin1', 'replace')[-1500:])
        raise SystemExit('%s nie powiodlo sie (kod %d)' % (what, result.returncode))


def build_artifacts(rebuild: bool) -> None:
    if not rebuild and DLL.is_file() and EXE.is_file():
        log('artefakty: %s (%d B), %s (%d B) - build pominiety'
            % (DLL.name, DLL.stat().st_size, EXE.name, EXE.stat().st_size))
        return
    run_tool([sys.executable, str(ROOT / 'tools' / 'build_win16_winsock.py'), '--strict'],
             'build WINSOCK.DLL/TESTLOAD.EXE')
    require(DLL, 'WINSOCK.DLL')
    require(EXE, 'TESTLOAD.EXE')


def setup_key(source: Path | None = None) -> tuple[bytes, dict[str, str]]:
    """SETUP.KEY = USOSKBC script compiled from keys/W3PL.txt (production builder)."""
    path = source or KEY_SOURCE
    data = usos_keyscript.compile_script(path.read_text(encoding='ascii'))
    info = {'setup_key_source': str(path),
            'setup_key_bytes': str(len(data)),
            'setup_key_sha256': hashlib.sha256(data).hexdigest()}
    return data, info


def load_payload(directory: Path) -> tuple[dict[str, bytes], dict[str, str]]:
    """Bit-exact USOS.SHH / USOSKBC.COM / USOSKEY.DRV from the MS-DOS build."""
    files: dict[str, bytes] = {}
    info: dict[str, str] = {}
    for name in PAYLOAD_FILES:
        path = require(directory / name, 'MS-DOS payload')
        files[name] = path.read_bytes()
        info['payload_' + name.lower()] = hashlib.sha256(files[name]).hexdigest()
    return files, info


def boot_sector(dos_iso: win16_disk.Iso,
                explicit: Path | None) -> tuple[bytes, str]:
    """MS-DOS 6.22 boot sector: loader code from the media, BPB from USOS."""
    if explicit is not None:
        data = require(explicit, '--dos-boot-sector').read_bytes()[:512]
        if data[510:512] != b'\x55\xaa' or data[0] not in (0xE9, 0xEB):
            raise SystemExit('%s: to nie jest sektor rozruchowy (brak 55AA/jmp)'
                             % explicit)
        return data, explicit.name
    try:  # an unpacked SYS.COM carries the template; the 6.22 upgrade ISO packs it
        return win16_disk.boot_sector_template(dos_iso.read('SYS.COM')), 'SYS.COM'
    except win16_disk.IsoError as error:
        raise SystemExit('%s; podaj --dos-boot-sector (512 B VBR z media MS-DOS, '
                         'np. zig-out/win16/dosboot.vbr)' % error) from None


def build_image(dos_iso: Path, win_iso: Path, boot: Path | None, payload: Path,
                size_mib: int, kbc: str, script_source: Path | None) -> dict[str, str]:
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    files, info = load_payload(payload)
    key, key_info = setup_key(script_source)

    with win16_disk.Iso(dos_iso) as dos, win16_disk.Iso(win_iso) as win:
        for name in ('IO.SYS', 'MSDOS.SYS', 'COMMAND.COM'):
            if not dos.has(name):
                raise SystemExit('%s: brak plikow systemowych %s' % (dos_iso.name, name))
        template, template_name = boot_sector(dos, boot)
        log('sektor rozruchowy MS-DOS: %s (OEM %r)'
            % (template_name, template[3:11].decode('latin1')))

        builder = win16_disk.Fat16Builder(size_mib * 1024 * 1024, template)
        builder.add('IO.SYS', dos.read('IO.SYS'), attr=0x27)
        builder.add('MSDOS.SYS', dos.read('MSDOS.SYS'), attr=0x27)
        builder.add('COMMAND.COM', dos.read('COMMAND.COM'))
        builder.add('CONFIG.SYS', CONFIG_SYS_INSTALL.encode('ascii'))
        builder.add('AUTOEXEC.BAT', AUTOEXEC_INSTALL.format(kbc=kbc)
                    .replace('\n', '\r\n').encode('ascii'))

        # C:\USOSW3 - what W3START.BAT expects next to the SETUP.KEY it uses.
        for name, data in files.items():
            builder.add('USOSW3\\' + name, data)
        builder.add('USOSW3\\SETUP.KEY', key)
        builder.add('DOS\\README.TXT', b'MS-DOS tools for the Win16 test\r\n')

        setup_files = 0
        setup_bytes = 0
        for name, (_, size) in sorted(win.entries.items()):
            if '/' in name or ';' in name or '.' not in name:
                continue  # only the flat root of the Windows 3.1 media
            builder.add('W31\\' + name, win.read(name))
            setup_files += 1
            setup_bytes += size
        if not win.has('SETUP.EXE') or not win.has('SETUP.INF'):
            raise SystemExit('%s: to nie jest plyta instalacyjna Windows 3.1'
                             % win_iso.name)

    # Setup resolves /H:USOS.SHH against its own directory: same bytes, two names.
    builder.add('W31\\USOS.SHH', files['USOS.SHH'])
    builder.add('TEST\\TESTLOAD.EXE', EXE.read_bytes())
    builder.add('TEST\\WINSOCK.DLL', DLL.read_bytes())
    builder.add('TEMP\\README.TXT', b'USOS Win16 test TEMP directory\r\n')

    log('obraz: %s (%d MiB, %d plikow Setup, %.1f MiB Setup)'
        % (BASE_RAW.name, size_mib, setup_files, setup_bytes / 1048576.0))
    BASE_RAW.write_bytes(builder.build())
    info.update(key_info)
    info.update({'setup_files': str(setup_files),
                 'setup_bytes': str(setup_bytes),
                 'boot_sector': template_name,
                 'usos_shh_sha256': hashlib.sha256(files['USOS.SHH']).hexdigest()})
    return info


class Monitor:
    """HMP monitor (screendump, quit) over TCP."""

    def __init__(self, port: int) -> None:
        self.port = port
        self.sock: socket.socket | None = None

    def connect(self, timeout: float = 20.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self.sock = socket.create_connection(('127.0.0.1', self.port), timeout=5)
                self.sock.settimeout(0.5)
                time.sleep(0.3)
                self._drain()
                return
            except OSError:
                time.sleep(0.2)
        raise SystemExit('monitor QEMU nie odpowiada na porcie %d' % self.port)

    def _drain(self) -> bytes:
        data = b''
        assert self.sock is not None
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    break
                data += chunk
        except (socket.timeout, OSError):
            pass
        return data

    def command(self, text: str, wait: float = 0.4) -> bytes:
        assert self.sock is not None
        self.sock.sendall((text + '\n').encode('ascii'))
        time.sleep(wait)
        return self._drain()

    def screendump(self, target: Path) -> None:
        self.command('screendump %s' % target, wait=1.0)

    def close(self) -> None:
        if self.sock is not None:
            self.sock.close()
            self.sock = None


def tail(path: Path, limit: int = 4096) -> bytes:
    try:
        with path.open('rb') as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - limit))
            return handle.read()
    except OSError:
        return b''


class Qemu:
    """One VM run: qemu-system-x86_64 + HMP monitor + COM1 file + screenshots."""

    def __init__(self, qemu: Path, image: Path, tag: str, serial: Path,
                 frames_dir: Path) -> None:
        self.image = image
        self.qemu_bin = qemu
        self.serial = serial
        self.frames_dir = frames_dir
        self.frames: list[Path] = []
        self.tag = tag
        self.port = 4466
        self.process: subprocess.Popen | None = None
        self.monitor = Monitor(self.port)

    def _command(self) -> list[str]:
        fmt = 'qcow2' if self.image.suffix == '.qcow2' else 'raw'
        return [str(self.qemu_bin), '-machine', 'pc,smm=off,vmport=off',
                '-cpu', 'pentium3', '-m', '64', '-display', 'none', '-vga', 'std',
                '-rtc', 'base=localtime', '-net', 'none',
                '-monitor', 'tcp:127.0.0.1:%d,server,nowait' % self.port,
                '-serial', 'file:%s' % self.serial,
                '-drive', 'file=%s,format=%s,if=ide,index=0' % (self.image, fmt),
                '-no-reboot']

    def __enter__(self) -> 'Qemu':
        self.frames_dir.mkdir(parents=True, exist_ok=True)
        if self.serial.exists():
            self.serial.unlink()
        command = self._command()
        log('qemu[%s]: %s' % (self.tag, ' '.join(command)))
        self.process = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.STDOUT)
        self.monitor.connect()
        return self

    def __exit__(self, *exc: object) -> None:
        try:
            if self.frames:
                self.shot()
        except Exception:  # noqa: BLE001 - evidence only
            pass
        self.monitor.close()
        if self.process is not None:
            self.process.kill()
            self.process.wait()
        self.to_png()

    def shot(self) -> None:
        frame = self.frames_dir / ('%s-%02d.ppm' % (self.tag, len(self.frames)))
        self.monitor.screendump(frame)
        self.frames.append(frame)

    def to_png(self) -> None:
        for frame in self.frames:
            png = frame.with_suffix('.png')
            try:
                from PIL import Image  # optional, evidence only
                Image.open(frame).save(png)
            except Exception:  # noqa: BLE001
                continue
            frame.unlink(missing_ok=True)

    def wait_for(self, needles: list[bytes], timeout: float,
                 screenshot_every: float = 20.0, max_frames: int = 30) -> bytes | None:
        deadline = time.time() + timeout
        next_shot = time.time() + screenshot_every
        while time.time() < deadline:
            data = tail(self.serial, 4096)
            for needle in needles:
                if needle in data:
                    return needle
            if self.process is not None and self.process.poll() is not None:
                return b'VM-EXIT'
            if time.time() >= next_shot and len(self.frames) < max_frames:
                try:
                    self.shot()
                except Exception:  # noqa: BLE001 - a missing frame is not fatal
                    pass
                next_shot = time.time() + screenshot_every
            time.sleep(1.0)
        return None

    def shutdown(self) -> None:
        try:
            self.shot()
        except Exception:  # noqa: BLE001
            pass
        try:
            self.monitor.command('quit', wait=0.5)
        except Exception:  # noqa: BLE001
            pass


def install_windows(qemu: Path, timeout: float) -> dict[str, str]:
    """First boot: USOSKBC.COM + SETUP.EXE /H:USOS.SHH, unattended.

    Windows 3.1 Setup ends its DOS half by restarting the machine (the harness
    runs QEMU with ``-no-reboot``, so the VM simply exits) - a finished image is
    recognised by ``C:\\WINDOWS\\WIN.COM``, not only by the COM1 marker.
    """
    serial = EVIDENCE / 'install-serial.log'
    frames_dir = EVIDENCE / 'install'
    for stale in frames_dir.glob('install-*'):
        stale.unlink()
    started = time.time()
    frames_every = max(6.0, min(30.0, timeout / 20.0))
    with Qemu(qemu, BASE_RAW, 'install', serial, frames_dir) as vm:
        needle = vm.wait_for([b'SETUP-DONE', b'SETUP-FAILED', b'INSTALL-EXIT'],
                             timeout, screenshot_every=frames_every, max_frames=60)
        phases = {'install_at': '%.0fs' % (time.time() - started),
                  'install_marker': needle.decode('latin1') if needle else 'TIMEOUT'}
        if needle is not None:
            time.sleep(3.0)  # let Setup finish writing before the VM goes away
        vm.shutdown()
    with win16_disk.Fat16Volume(BASE_RAW) as volume:
        installed = volume.exists('WINDOWS\\WIN.COM')
        try:
            (EVIDENCE / 'install-kbc.log').write_bytes(volume.read('KBC.LOG'))
            phases['install_kbc'] = volume.read('KBC.LOG').decode('latin1').strip()
        except FileNotFoundError:
            phases['install_kbc'] = '(brak C:\\KBC.LOG)'
    if phases['install_marker'] == 'VM-EXIT' and installed:
        phases['install_marker'] = 'SETUP-DONE (restart VM)'
    phases['windows_installed'] = str(installed)
    phases['install_serial'] = tail(serial, 1500).decode('latin1', 'replace')
    return phases


def make_base(qemu_img: Path) -> None:
    run_tool([str(qemu_img), 'convert', '-f', 'raw', '-O', 'qcow2', '-o', 'compat=1.1',
              str(BASE_RAW), str(BASE_QCOW2)], 'qemu-img (baza qcow2)')


def stage_run(qemu_img: Path, tag: str, negative: bool) -> tuple[Path, dict[str, str]]:
    """New overlay of the installed base, staged with this run's payload."""
    overlay = EVIDENCE / ('run-%s.qcow2' % tag)
    raw = EVIDENCE / ('run-%s.img' % tag)
    for stale in (overlay, raw):
        stale.unlink(missing_ok=True)
    run_tool([str(qemu_img), 'create', '-f', 'qcow2', '-F', 'qcow2', '-b',
              str(BASE_QCOW2), str(overlay)], 'qemu-img create (nakladka %s)' % tag)
    run_tool([str(qemu_img), 'convert', '-f', 'qcow2', '-O', 'raw', str(overlay),
              str(raw)], 'qemu-img convert (nakladka %s -> raw)' % tag)

    with win16_disk.Fat16Volume(raw) as volume:
        himem = volume.exists('WINDOWS\\HIMEM.SYS')
        config = (CONFIG_SYS_RUN_HEAD if himem else '') + CONFIG_SYS_RUN_TAIL
        volume.put('CONFIG.SYS', config.encode('ascii'))
        volume.put('AUTOEXEC.BAT', AUTOEXEC_RUN.replace('\n', '\r\n').encode('ascii'))
        volume.put('TEST\\TESTLOAD.EXE', EXE.read_bytes())
        volume.remove('WSTEST.LOG')
        # The Polish edition starts ADD852.EXE ("MS-DOS code page 852 support")
        # on the first Windows start and waits for a click; the smoke test needs
        # the session to itself, so the applet and its WIN.INI hooks go away.
        volume.remove('WINDOWS\\ADD852.EXE')
        volume.remove('WINDOWS\\STARTUP\\ADD852.EXE')
        if volume.exists('WINDOWS\\WIN.INI'):
            win_ini = [line for line in
                       volume.read('WINDOWS\\WIN.INI').decode('latin1').split('\r\n')
                       if not line.lower().startswith(('load=', 'run='))]
            volume.put('WINDOWS\\WIN.INI', '\r\n'.join(win_ini).encode('latin1'))
        if negative:
            removed = volume.remove('WINDOWS\\SYSTEM\\WINSOCK.DLL')
            log('nakladka %s: WINSOCK.DLL usuniety=%s (test negatywny)' % (tag, removed))
        else:
            volume.put('WINDOWS\\SYSTEM\\WINSOCK.DLL', DLL.read_bytes())
            log('nakladka %s: WINSOCK.DLL -> C:\\WINDOWS\\SYSTEM (%d B)'
                % (tag, DLL.stat().st_size))
        staged = {'himem': str(himem),
                  'winsock_in_system': str(volume.exists('WINDOWS\\SYSTEM\\WINSOCK.DLL'))}
    return raw, staged


def run_windows(qemu: Path, image: Path, tag: str, timeout: float) -> dict[str, str]:
    serial = EVIDENCE / ('%s-serial.log' % tag)
    started = time.time()
    with Qemu(qemu, image, tag, serial, EVIDENCE / tag) as vm:
        needle = vm.wait_for([b'USOS-WIN16-DONE', b'WIN-END'], timeout,
                             screenshot_every=12.0, max_frames=30)
        phases = {'run_at': '%.0fs' % (time.time() - started),
                  'run_marker': needle.decode('latin1') if needle else 'TIMEOUT'}
        vm.shutdown()
    phases['run_serial'] = tail(serial, 1500).decode('latin1', 'replace')
    return phases


def read_log(image: Path) -> tuple[str, dict[str, str]]:
    with win16_disk.Fat16Volume(image) as volume:
        info = {'himem': str(volume.exists('WINDOWS\\HIMEM.SYS')),
                'winsock_dll': str(volume.exists('WINDOWS\\SYSTEM\\WINSOCK.DLL'))}
        try:
            raw = volume.read('WSTEST.LOG')
        except FileNotFoundError:
            return '', info
    return raw.decode('latin1').strip(), info


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dos-iso', default=os.environ.get('USOS_DOS_ISO'),
                        help='MS-DOS 6.22 Setup ISO (pliki systemowe)')
    parser.add_argument('--win-iso', default=os.environ.get('USOS_WIN31_ISO'),
                        help='Windows 3.1 PL ISO (flat katalog Setup)')
    parser.add_argument('--dos-payload', default=os.environ.get('USOS_DOS_PAYLOAD'),
                        help='katalog MS-DOS z USOS.SHH, USOSKBC.COM, USOSKEY.DRV')
    parser.add_argument('--dos-boot-sector', default=None,
                        help='512 B VBR z media MS-DOS (gdy SYS.COM jest spakowany)')
    parser.add_argument('--qemu', default=None, help='qemu-system-x86_64')
    parser.add_argument('--size-mib', type=int, default=128, help='rozmiar dysku (128)')
    parser.add_argument('--timeout', type=float, default=2400.0,
                        help='limit jednej fazy w sekundach (2400)')
    parser.add_argument('--rebuild', action='store_true', help='wymus build DLL/EXE')
    parser.add_argument('--reinstall', action='store_true',
                        help='zignoruj win31-base.qcow2 i zainstaluj Windows od nowa')
    parser.add_argument('--kbc-script', default=None,
                        help='zrodlo skryptu USOSKBC (domyslnie keys/W3PL.txt)')
    parser.add_argument('--kbc-relay', action='store_true',
                        help='USOSKBC /R: przekaznik 8042 (IRQ1) dla stron tekstowych')
    parser.add_argument('--negative', action='store_true',
                        help='test negatywny: TESTLOAD.EXE bez WINSOCK.DLL')
    parser.add_argument('--only', choices=('both', 'positive', 'negative'),
                        default='both', help='ktore przebiegi wykonac')
    args = parser.parse_args(argv)

    payload = Path(args.dos_payload) if args.dos_payload \
        else ROOT / 'zig-out' / 'dos-native' / 'msdos'
    boot = Path(args.dos_boot_sector) if args.dos_boot_sector else (
        ARTIFACT_DIR / 'dosboot.vbr' if (ARTIFACT_DIR / 'dosboot.vbr').is_file() else None)

    qemu = find_qemu(args.qemu)
    qemu_img = find_qemu_img(qemu)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    build_artifacts(args.rebuild)
    info: dict[str, str] = {}

    if args.reinstall or not BASE_QCOW2.is_file():
        dos_iso = require(Path(args.dos_iso or ''), '--dos-iso')
        win_iso = require(Path(args.win_iso or ''), '--win-iso')
        require(payload / 'USOS.SHH', '--dos-payload')
        info = build_image(dos_iso, win_iso, boot, payload, args.size_mib,
                           ' /R' if args.kbc_relay else '',
                           Path(args.kbc_script) if args.kbc_script else None)
        info.update(install_windows(qemu, args.timeout))
        if info.get('windows_installed') != 'True':
            log('instalacja Windows nie doszla do konca: %s' % info.get('install_marker'))
            log('dowody: %s' % EVIDENCE)
            return 2
        make_base(qemu_img)
        BASE_RAW.unlink(missing_ok=True)
    else:
        log('baza: %s (instalacja pominieta, --reinstall wymusza nowa)' % BASE_QCOW2.name)
        info['install_marker'] = 'reused'

    report = {'base': str(BASE_QCOW2), 'image_size': '%d MiB' % args.size_mib, **info}
    results: dict[str, bool] = {}
    order = ['positive', 'negative']
    if args.only != 'both':
        order = [args.only]

    for tag in order:
        negative = tag == 'negative'
        raw, staged = stage_run(qemu_img, tag, negative)
        phases = run_windows(qemu, raw, tag, args.timeout)
        text, after = read_log(raw)
        ok = 'USOS WINSOCK FAIL err=' in text if negative else (
            'USOS WINSOCK OK version=1.1 high=' in text and 'desc=' in text)
        evidence = EVIDENCE / ('WSTEST-negatywny.LOG' if negative else 'WSTEST.LOG')
        evidence.write_text(text + '\n', encoding='utf-8')
        for key, value in list(staged.items()) + list(after.items()):
            report[tag + '_' + key] = value
        for key, value in phases.items():
            report[tag + '_' + key] = value
        report[tag + '_wstest_log'] = text.replace('\n', ' | ') or '(brak C:\\WSTEST.LOG)'
        report[tag + '_result'] = 'PASS' if ok else 'FAIL'
        results[tag] = ok
        raw.unlink(missing_ok=True)
        log('--- %s: C:\\WSTEST.LOG ---' % tag)
        log(text or '(brak C:\\WSTEST.LOG w obrazie)')

    (EVIDENCE / 'result.txt').write_text(
        '\n'.join('%s: %s' % item for item in report.items()) + '\n', encoding='utf-8')
    log('--- COM1 (ogon) ---')
    log(report.get('positive_run_serial', '').strip()[-400:])
    passed = results.get('positive', False) and results.get('negative', False)
    log('dowody: %s' % EVIDENCE)
    log('WYNIK: %s (pozytywny=%s negatywny=%s)'
        % ('PASS' if passed else 'FAIL', results.get('positive'),
           results.get('negative')))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
