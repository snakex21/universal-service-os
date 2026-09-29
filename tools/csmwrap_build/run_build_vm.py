"""Host half of tools/build_csmwrap.ps1: boots the pinned Alpine virt ISO in
QEMU (WHPX, falling back to TCG), logs in on the serial console as root (the
live ISO has no password), runs guest_build.sh and collects its output tar.

  python tools/csmwrap_build/run_build_vm.py --work zig-out/csmwrap-build [--accel whpx|tcg]

Disks: vda = input tar (guest script, lock.env, patches), vdb = output tar.
Needs network (apk and github.com through QEMU user networking), unless
--offline MIRROR is given: the build kit's partial Alpine mirror is then
served to the guest over HTTP from the host (10.0.2.2) and the source comes
from tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz (no git).
Builds nothing on the host; touches no physical disk.
"""
from pathlib import Path
import argparse, functools, hashlib, http.server, io, json, shlex, socket, subprocess, sys, tarfile, threading, time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
QEMU = ROOT / 'tools/qemu/qemu-system-x86_64.exe'
OUT_DISK_BYTES = 256 * 1024 * 1024


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def lock_env(lock, mirror=None):
    c = lock['csmwrap']
    env = {
        'ALPINE_MIRROR': mirror or lock['alpine_mirror'],
        'ALPINE_BRANCH': lock['alpine_branch'],
        'APK_PACKAGES': ' '.join(lock['apk_packages']),
        'CSMWRAP_URL': c['url'],
        'CSMWRAP_COMMIT': c['commit'],
        'SUBMODULES': ' '.join(f'{k}={v}' for k, v in sorted(c['submodules'].items())),
        'SRC_DIR': lock['source_dir'],
        'SOURCE_EPOCH': str(lock['source_epoch']),
        'UPSTREAM_VERSION': lock['upstream_version'],
        'USOS_VERSION': lock['usos_version'],
    }
    return ''.join(f'{k}={shlex.quote(v)}\n' for k, v in env.items())


def input_tar(lock, patches, mirror=None, source=None):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.USTAR_FORMAT) as t:
        def add(name, data, mode=0o644):
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(data), mode, 0
            t.addfile(info, io.BytesIO(data))
        add('guest_build.sh', (HERE / 'guest_build.sh').read_bytes().replace(b'\r\n', b'\n'), 0o755)
        add('lock.env', lock_env(lock, mirror).encode())
        if source is not None:
            add('source.tar.xz', source.read_bytes())
        for p in patches:
            add('patches/' + p.name, p.read_bytes().replace(b'\r\n', b'\n'))
    data = buf.getvalue()
    return data + b'\0' * (-len(data) % (1 << 20))


class Serial:
    def __init__(self, port, log):
        self.log = open(log, 'ab')
        for _ in range(100):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=1)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError('cannot connect to the QEMU serial port')
        self.s.settimeout(0.5)
        self.buf = b''

    def pump(self):
        try:
            data = self.s.recv(65536)
        except socket.timeout:
            return
        if not data:
            raise EOFError('serial closed (QEMU exited)')
        self.log.write(data)
        self.log.flush()
        sys.stdout.write(data.decode('ascii', 'replace').encode('ascii', 'replace').decode())
        sys.stdout.flush()
        self.buf = (self.buf + data)[-65536:]

    def wait(self, *needles, timeout):
        end = time.time() + timeout
        while time.time() < end:
            for n in needles:
                if n in self.buf:
                    self.buf = self.buf[self.buf.index(n) + len(n):]
                    return n
            self.pump()
        raise TimeoutError(f'waiting for {needles}')

    def send(self, text):
        self.s.sendall(text.encode())


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--iso', type=Path, help='default: lock alpine_iso.file (repository or main-checkout cache)')
    p.add_argument('--accel', default='whpx')
    p.add_argument('--timeout-minutes', type=float, default=60)
    p.add_argument('--offline', type=Path, help='partial Alpine mirror (build kit csmwrap-vm/apk): no network needed')
    p.add_argument('--patches', type=Path, help='prototype patch folder instead of 3.1.2-usos1/patches (e.g. 3.1.2-usos2-proto/patches)')
    p.add_argument('--usos-version', help='BUILD_VERSION of the patched build (default: lock usos_version)')
    a = p.parse_args()
    lock = json.loads((HERE / 'lock.json').read_text(encoding='utf-8'))
    if a.usos_version:
        lock['usos_version'] = a.usos_version
    work = a.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    iso = a.iso or ROOT / lock['alpine_iso']['file']
    if not iso.exists():
        raise SystemExit(f'Alpine ISO missing: {iso} (download {lock["alpine_iso"]["url"]})')
    if sha256(iso) != lock['alpine_iso']['sha256']:
        raise SystemExit(f'Alpine ISO hash mismatch: {iso}')
    patches = sorted(((a.patches or ROOT / 'tools/vendor/csmwrap/3.1.2-usos1/patches')).glob('*.patch'))
    if not a.patches and len(patches) != 3:
        raise SystemExit(f'expected 3 patches, found {len(patches)}')
    in_disk, out_disk = work / 'input.tar.img', work / 'output.tar.img'
    mirror = source = None
    if a.offline:
        mirror_root = a.offline.resolve()
        if not (mirror_root / lock['alpine_branch'] / 'main/x86_64/APKINDEX.tar.gz').is_file():
            raise SystemExit(f'no Alpine {lock["alpine_branch"]} mirror in {mirror_root}')
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(mirror_root))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        mirror = f'http://10.0.2.2:{server.server_address[1]}'
        source = ROOT / 'tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz'
        print('offline: Alpine mirror', mirror_root, 'as', mirror, '; source', source, flush=True)
    in_disk.write_bytes(input_tar(lock, patches, mirror, source))
    with open(out_disk, 'wb') as f:
        f.truncate(OUT_DISK_BYTES)
    serial_log = work / 'serial.log'
    serial_log.unlink(missing_ok=True)
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    accel = ['-accel', 'whpx', '-accel', 'tcg,thread=multi'] if a.accel == 'whpx' else ['-accel', 'tcg,thread=multi']
    cmd = [str(QEMU), '-machine', 'q35', *accel, '-cpu', 'qemu64,-xsave' if a.accel == 'whpx' else 'max',
           '-smp', '4', '-m', '4096', '-display', 'none', '-no-reboot',
           '-serial', f'tcp:127.0.0.1:{port},server=on,wait=off', '-monitor', 'none',
           '-cdrom', str(iso), '-boot', 'd',
           '-drive', f'if=virtio,format=raw,file={in_disk}',
           '-drive', f'if=virtio,format=raw,file={out_disk}',
           '-nic', 'user,model=virtio-net-pci']
    print(' '.join(cmd), flush=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(work / 'qemu-stderr.log', 'wb'))
    result = 'FAIL'
    try:
        time.sleep(1)
        ser = Serial(port, serial_log)
        ser.wait(b'login:', timeout=300)
        ser.send('root\n')
        ser.wait(b'# ', timeout=60)
        ser.send('mkdir -p /w && tar -xf /dev/vda -C /w && sh /w/guest_build.sh; echo USOS-BUILD-""EXIT=$?\n')
        ser.wait(b'USOS-BUILD-EXIT=', timeout=a.timeout_minutes * 60)
        ser.pump()
        if b'USOS-BUILD-EXIT=0' in serial_log.read_bytes() and b'GUEST-BUILD-PASS' in serial_log.read_bytes():
            result = 'PASS'
        ser.send('poweroff\n')
        proc.wait(60)
    finally:
        if proc.poll() is None:
            proc.kill()
    if result != 'PASS':
        raise SystemExit('guest build FAILED; see ' + str(serial_log))
    out = work / 'out'
    out.mkdir(exist_ok=True)
    with tarfile.open(out_disk) as t:
        t.extractall(out, filter='data')
    sums = dict(reversed(l.split(None, 1)) for l in (out / 'SHA256SUMS').read_text().splitlines())
    for name, digest in sums.items():
        name = name.lstrip('*')
        assert sha256(out / name) == digest, name
    print(json.dumps({'result': result, 'out': str(out)}, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
