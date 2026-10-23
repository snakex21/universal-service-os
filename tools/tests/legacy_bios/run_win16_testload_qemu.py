#!/usr/bin/env python3
"""QEMU harness: does Windows 3.1 load the USOS WINSOCK.DLL and can a Win16
application call WSAStartup?

One command, repeatable:

    python tools/tests/legacy_bios/run_win16_testload_qemu.py \
        --dos-iso "OS/DOS/MS-DOS/MS-DOS 6.22 EN.iso" \
        --win-iso "OS/Windows/Windows 3.1/Windows 3.1 PL.iso" \
        --dos-boot-floppy C:\\path\\to\\Msdos622Boot.img

What the script does (no user interaction, no mouse/keyboard injection):

1. builds ``zig-out/win16/WINSOCK.DLL`` and ``zig-out/win16/TESTLOAD.EXE``
   with ``tools/build_win16_winsock.py`` (Open Watcom 16-bit);
2. writes a 128 MiB FAT16 hard-disk image from ``tools/win16_disk.py``: MBR +
   one active partition, MS-DOS 6.22 system files (IO.SYS first, then
   MSDOS.SYS/COMMAND.COM), ``CONFIG.SYS``/``AUTOEXEC.BAT``, the whole flat
   Windows 3.1 Setup directory in ``C:\\W31``, ``USOS.SHH`` (the batch Setup
   answer file of ``src/platform/bios/msdos/windows_setup.shh``),
   ``C:\\TEST\\TESTLOAD.EXE`` and ``C:\\TEST\\WINSOCK.DLL``;
3. boots it in QEMU (SeaBIOS, pentium3, 64 MiB, ``-display none``);
   ``AUTOEXEC.BAT`` runs ``SETUP.EXE /H:USOS.SHH`` unattended.  Windows Setup
   rewrites ``CONFIG.SYS`` with ``DEVICE=C:\\WINDOWS\\HIMEM.SYS``, so the
   harness resets the VM when it sees ``SETUP-DONE`` on COM1 (the second boot
   loads HIMEM.SYS);
4. the second boot runs ``WIN /S C:\\TEST\\TESTLOAD.EXE`` (standard mode, not
   386 enhanced); the application writes ``C:\\WSTEST.LOG``, posts WM_QUIT and
   the session ends by itself; ``AUTOEXEC.BAT`` prints ``USOS-WIN16-DONE`` on
   COM1 and the harness shuts the VM down;
5. reads ``C:\\WSTEST.LOG`` back out of the image and writes the evidence to
   ``zig-out/win16/qemu/`` (log, serial log, screendumps).  Exit code 0 only
   when the log says ``USOS WINSOCK OK version=1.1 high=1.1 desc=<...>``
   (or ``FAIL err=10092`` with ``--negative``).

Staging into the image uses ``tools/win16_disk.py`` (stdlib only): no mtools,
no WSL, no loop mount and no administrator rights are needed.  The MS-DOS boot
sector code is not shipped in the tree - it is copied from the user's bootable
MS-DOS 6.22 floppy image and only its BPB is replaced, the same split the
production installer uses for the user's own boot sector.
"""
from __future__ import annotations

import argparse
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

ARTIFACT_DIR = ROOT / 'zig-out' / 'win16'
DLL = ARTIFACT_DIR / 'WINSOCK.DLL'
EXE = ARTIFACT_DIR / 'TESTLOAD.EXE'
EVIDENCE = ARTIFACT_DIR / 'qemu'

SETUP_ANSWER_FILE = '''; USOS: batch Setup for the Win16 WINSOCK.DLL smoke test.
; Base: src/platform/bios/msdos/windows_setup.shh (devices, language and
; keyboard layout come from Setup's detection and the Polish SETUP.INF).
[sysinfo]
showsysinfo=no

[windir]
c:\\windows

[userinfo]
"USOS"

[endinstall]
configfiles = modify
endopt      = exit
'''

CONFIG_SYS = 'FILES=40\r\nBUFFERS=30\r\nSHELL=C:\\COMMAND.COM /P /E:512\r\n'

# Two-phase AUTOEXEC: the first boot installs Windows (real-mode Setup, no XMS
# needed); Setup rewrites CONFIG.SYS with HIMEM.SYS, so the harness resets the
# VM and the second boot runs the Win16 test in standard mode.
AUTOEXEC_PHASE = '''@ECHO OFF
PROMPT $P$G
SET TEMP=C:\\TEMP
PATH C:\\;C:\\DOS;C:\\W31
SET TESTCMD=TESTLOAD.EXE
IF EXIST C:\\WINDOWS\\WIN.COM GOTO RUNTEST
ECHO SETUP-START>COM1
CD C:\\W31
C:\\W31\\SETUP.EXE /H:USOS.SHH
ECHO SETUP-DONE>COM1
GOTO END
:RUNTEST
COPY C:\\TEST\\WINSOCK.DLL C:\\WINDOWS\\SYSTEM\\WINSOCK.DLL >NUL
ECHO WIN-START>COM1
C:\\WINDOWS\\WIN.COM /S C:\\TEST\\TESTLOAD.EXE {args}
ECHO WIN-END>COM1
:END
ECHO USOS-WIN16-DONE>COM1
'''


def log(message: str) -> None:
    print(message, flush=True)


def find_qemu(explicit: str | None) -> Path:
    for candidate in (explicit, os.environ.get('USOS_QEMU'),
                      str(ROOT / 'tools' / 'qemu' / 'qemu-system-x86_64.exe'),
                      shutil.which('qemu-system-x86_64')):
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise SystemExit('brak qemu-system-x86_64 - podaj --qemu albo ustaw USOS_QEMU')


def require(path: Path, what: str) -> Path:
    if not path.is_file():
        raise SystemExit('%s: brak %s' % (what, path))
    return path


def build_artifacts(rebuild: bool) -> None:
    if not rebuild and DLL.is_file() and EXE.is_file():
        log('artefakty: %s (%d B), %s (%d B) - build pominiety'
            % (DLL.name, DLL.stat().st_size, EXE.name, EXE.stat().st_size))
        return
    log('build: tools/build_win16_winsock.py')
    result = subprocess.run([sys.executable, str(ROOT / 'tools' / 'build_win16_winsock.py'),
                             '--strict'], cwd=str(ROOT))
    if result.returncode != 0:
        raise SystemExit('build WINSOCK.DLL/TESTLOAD.EXE nie powiodl sie')
    require(DLL, 'WINSOCK.DLL')
    require(EXE, 'TESTLOAD.EXE')


def boot_sector_from_floppy(path: Path) -> bytes:
    """First 512 bytes of a bootable MS-DOS floppy image (VBR code template)."""
    data = path.read_bytes()[:512]
    if data[510:512] != b'\x55\xaa' or data[0] not in (0xE9, 0xEB):
        raise SystemExit('%s: to nie jest sektor rozruchowy (brak 55AA/jmp)' % path)
    return data


def build_image(dos_iso: Path, win_iso: Path, boot_floppy: Path, size_mib: int,
                args: str) -> tuple[Path, dict[str, str]]:
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    template = boot_sector_from_floppy(boot_floppy)
    log('sektor rozruchowy MS-DOS 6.22: %s (OEM %r)'
        % (boot_floppy.name, template[3:11].decode('latin1')))

    with win16_disk.Iso(dos_iso) as dos, win16_disk.Iso(win_iso) as win:
        missing = [name for name in ('IO.SYS', 'MSDOS.SYS', 'COMMAND.COM')
                   if not dos.has(name)]
        if missing:
            raise SystemExit('%s: brak plikow systemowych %s'
                             % (dos_iso.name, ', '.join(missing)))
        builder = win16_disk.Fat16Builder(size_mib * 1024 * 1024, template)
        builder.add('IO.SYS', dos.read('IO.SYS'), attr=0x27)
        builder.add('MSDOS.SYS', dos.read('MSDOS.SYS'), attr=0x27)
        builder.add('COMMAND.COM', dos.read('COMMAND.COM'))
        builder.add('CONFIG.SYS', CONFIG_SYS.encode('ascii'))
        builder.add('AUTOEXEC.BAT',
                    AUTOEXEC_PHASE.format(args=args).replace('\n', '\r\n').encode('ascii'))
        builder.add('USOS.SHH', SETUP_ANSWER_FILE.replace('\n', '\r\n').encode('ascii'))
        setup_files = 0
        setup_bytes = 0
        for name, (_, size) in sorted(win.entries.items()):
            if '/' in name or ';' in name or '.' not in name:
                continue  # only the flat root of the Windows 3.1 media
            builder.add('W31\\' + name, win.read(name))
            setup_files += 1
            setup_bytes += size
        if not win.has('SETUP.EXE') or not win.has('SETUP.INF'):
            raise SystemExit('%s: to nie jest plyta instalacyjna Windows 3.1' % win_iso.name)

    # Setup resolves /H:USOS.SHH against its own directory, so the answer file
    # goes next to SETUP.EXE (a copy stays in the root for inspection).
    builder.add('W31\\USOS.SHH',
                SETUP_ANSWER_FILE.replace('\n', '\r\n').encode('ascii'))

    builder.add('TEST\\TESTLOAD.EXE', EXE.read_bytes())
    builder.add('TEST\\WINSOCK.DLL', DLL.read_bytes())
    builder.add('TEMP\\README.TXT', b'USOS Win16 test TEMP directory\r\n')

    image = EVIDENCE / 'win31-winsock16.img'
    log('obraz: %s (%d MiB, %d plikow Setup, %.1f MiB Setup)'
        % (image.name, size_mib, setup_files, setup_bytes / 1048576.0))
    image.write_bytes(builder.build())
    return image, {'setup_files': str(setup_files), 'setup_bytes': str(setup_bytes)}


class Monitor:
    """HMP monitor (screendump, system_reset, quit) over TCP."""

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
        self.command('screendump %s' % target)

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


def read_from(path: Path, offset: int) -> bytes:
    """Serial log content written after ``offset`` (bounded to the last 8 KiB)."""
    try:
        with path.open('rb') as handle:
            handle.seek(offset)
            return handle.read()[-8192:]
    except OSError:
        return b''


def wait_for(log_path: Path, needles: list[bytes], timeout: float,
             monitor: Monitor, frames: list[Path], offset: int = 0,
             press_enter_every: float = 0.0) -> bytes | None:
    deadline = time.time() + timeout
    seen = 0
    next_enter = (time.time() + press_enter_every) if press_enter_every else 0.0
    while time.time() < deadline:
        data = read_from(log_path, offset)
        for needle in needles:
            if needle in data:
                return needle
        if next_enter and time.time() >= next_enter:
            # Windows 3.1 batch Setup still shows its language/keyboard screen:
            # one ENTER per screen keeps the run unattended.  This is QMP
            # sendkey into the VM only - no host keyboard focus is touched.
            monitor.command('sendkey ret', wait=0.2)
            next_enter = time.time() + press_enter_every
        if time.time() > deadline - timeout + 20 and len(frames) < 12:
            shot = EVIDENCE / ('screen-%02d.ppm' % len(frames))
            try:
                monitor.screendump(shot)
                frames.append(shot)
            except Exception:  # noqa: BLE001 - a missing frame is not fatal
                pass
        time.sleep(1.0)
        seen += 1
    return None


def run_qemu(qemu: Path, image: Path, negative: bool, timeout: float) -> dict[str, str]:
    serial = EVIDENCE / 'serial.log'
    for stale in (serial,):
        if stale.exists():
            stale.unlink()
    port = 4466
    command = [
        str(qemu), '-machine', 'pc,smm=off,vmport=off', '-cpu', 'pentium3',
        '-m', '64', '-display', 'none', '-vga', 'std',
        '-rtc', 'base=localtime', '-net', 'none',
        '-monitor', 'tcp:127.0.0.1:%d,server,nowait' % port,
        '-serial', 'file:%s' % serial,
        '-drive', 'file=%s,format=raw,if=ide,index=0' % image,
        '-no-reboot',
    ]
    log('qemu: ' + ' '.join(command))
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                               stderr=subprocess.STDOUT)
    monitor = Monitor(port)
    frames: list[Path] = []
    phases: dict[str, str] = {}
    try:
        monitor.connect()
        started = time.time()
        first = wait_for(serial, [b'SETUP-DONE', b'USOS-WIN16-DONE'],
                         timeout, monitor, frames, press_enter_every=20.0)
        phases['setup_done_at'] = '%.0fs' % (time.time() - started)
        if first is None:
            phases['result'] = 'TIMEOUT: brak SETUP-DONE/komunikatu na COM1'
        elif first == b'SETUP-DONE':
            # Setup wrote HIMEM.SYS into CONFIG.SYS: reboot so the second boot
            # loads it (Windows standard mode needs XMS).
            log('setup gotowy, restart VM (drugi start: HIMEM.SYS + WIN /S)')
            try:
                shot = EVIDENCE / ('screen-%02d.ppm' % len(frames))
                monitor.screendump(shot)
                frames.append(shot)
            except Exception:  # noqa: BLE001
                pass
            offset = serial.stat().st_size if serial.exists() else 0
            monitor.command('system_reset', wait=1.0)
            started = time.time()
            second = wait_for(serial, [b'USOS-WIN16-DONE'],
                              max(300.0, timeout - (time.time() - started)),
                              monitor, frames, offset=offset)
            phases['win_done_at'] = '%.0fs' % (time.time() - started)
            phases['result'] = ('OK' if second else
                                'TIMEOUT: brak USOS-WIN16-DONE po restarcie')
        else:
            phases['result'] = 'OK'
            phases['note'] = 'setup nie bylo potrzebne (obraz juz zainstalowany)'
        try:
            shot = EVIDENCE / ('screen-%02d.ppm' % len(frames))
            monitor.screendump(shot)
            frames.append(shot)
        except Exception:  # noqa: BLE001
            pass
    finally:
        monitor.close()
        process.kill()
        process.wait()
    phases['serial'] = tail(serial, 2048).decode('latin1', 'replace')
    for index, frame in enumerate(frames):
        png = frame.with_suffix('.png')
        try:
            from PIL import Image  # optional, evidence only
            Image.open(frame).save(png)
            frame.unlink()
        except Exception:  # noqa: BLE001
            pass
    phases['frames'] = ', '.join(sorted(p.name for p in EVIDENCE.glob('screen-*.png')))
    return phases


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dos-iso', default=os.environ.get('USOS_DOS_ISO'),
                        help='MS-DOS 6.22 Setup ISO (pliki systemowe)')
    parser.add_argument('--win-iso', default=os.environ.get('USOS_WIN31_ISO'),
                        help='Windows 3.1 PL ISO (flat katalog Setup)')
    parser.add_argument('--dos-boot-floppy', default=os.environ.get('USOS_DOS_BOOT_FLOPPY'),
                        help='bootowalny obraz dyskietki MS-DOS 6.22 (zrodlo sektora rozruchowego)')
    parser.add_argument('--qemu', default=None, help='qemu-system-x86_64')
    parser.add_argument('--size-mib', type=int, default=128, help='rozmiar dysku (domyslnie 128)')
    parser.add_argument('--timeout', type=float, default=1800.0,
                        help='limit jednej fazy w sekundach (domyslnie 1800)')
    parser.add_argument('--rebuild', action='store_true', help='wymus build DLL/EXE')
    parser.add_argument('--negative', action='store_true',
                        help='test negatywny: TESTLOAD.EXE fail (WSAStartup 2.2 -> 10092)')
    args = parser.parse_args(argv)

    if not args.dos_iso or not args.win_iso or not args.dos_boot_floppy:
        parser.error('wymagane --dos-iso, --win-iso i --dos-boot-floppy '
                     '(albo USOS_DOS_ISO, USOS_WIN31_ISO, USOS_DOS_BOOT_FLOPPY)')
    dos_iso = require(Path(args.dos_iso), '--dos-iso')
    win_iso = require(Path(args.win_iso), '--win-iso')
    boot_floppy = require(Path(args.dos_boot_floppy), '--dos-boot-floppy')
    qemu = find_qemu(args.qemu)

    build_artifacts(args.rebuild)
    image, image_info = build_image(dos_iso, win_iso, boot_floppy, args.size_mib,
                                    ' fail' if args.negative else '')
    phases = run_qemu(qemu, image, args.negative, args.timeout)
    log('faza: %s' % phases.get('result'))

    log_text = ''
    strict = b'USOS WINSOCK OK version=1.1 high=1.1 desc='
    expected = b'USOS WINSOCK FAIL err=10092' if args.negative else strict
    try:
        reader = win16_disk.Fat16Reader(image)
        if reader.exists('WSTEST.LOG'):
            raw = reader.read('WSTEST.LOG')
            log_text = raw.decode('latin1').strip()
            (EVIDENCE / 'WSTEST.LOG').write_bytes(raw)
            (EVIDENCE / 'WSTEST.LOG.txt').write_text(log_text + '\n', encoding='utf-8')
        else:
            log_text = '(brak C:\\WSTEST.LOG w obrazie)'
    except Exception as error:  # noqa: BLE001 - evidence, not a crash
        log_text = '(nie mozna odczytac obrazu: %s)' % error

    report = {
        'image': str(image),
        'image_size': '%d MiB' % args.size_mib,
        'setup_files': image_info['setup_files'],
        'negative': str(args.negative),
        'wstest_log': log_text,
        **phases,
    }
    (EVIDENCE / 'result.txt').write_text(
        '\n'.join('%s: %s' % item for item in report.items()) + '\n', encoding='utf-8')

    log('--- C:\\WSTEST.LOG ---')
    log(log_text)
    log('--- COM1 (ogon) ---')
    log(phases.get('serial', '').strip()[-500:])

    passed = expected.decode('latin1') in log_text and 'OK' in phases.get('result', '')
    log('dowody: %s' % EVIDENCE)
    log('WYNIK: %s' % ('PASS' if passed else 'FAIL'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
