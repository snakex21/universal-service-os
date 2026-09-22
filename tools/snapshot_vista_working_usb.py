"""Freeze the exact v11 hardware-success payload; never modify a target disk."""
from pathlib import Path
import datetime
import hashlib
import json
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def main():
    helpers = ROOT / 'zig-out/vista/firstboot'
    package = ROOT / 'zig-out/vista/local-catalog'
    community = ROOT / 'zig-out/vista/community-usb'
    expected = {
        'usos-vista-firstboot.exe': '07e7c37da805eaee08c95fbbcb15348f74e00f17f35d96c99b47a3f24514519e',
        'usos-vista-trust.exe': '8d7bf2a6cc58affbb2f72fc0ab528ca99a124796adb7281b93caf547083ea3a5',
        'usb.exe': '3a959651e861d013d22a86ed559f342ffb02126f03f7e4587f0e60edfd178f2d',
    }
    for name, digest in expected.items():
        if sha(helpers / name) != digest:
            raise RuntimeError('Not the hardware-tested v11 binary: ' + name)
    local_manifest = json.loads((package / 'manifest.json').read_text())
    community_manifest = json.loads((community / 'deployment-manifest.json').read_text())
    if local_manifest['version'] != 10 or local_manifest['publisher_ca']:
        raise RuntimeError('Expected separate v10 CA and publisher')
    files = {}
    for name in (*expected, 'usos-vista-kmdf.exe'):
        files['payload/USOS/' + (name if name == 'usb.exe' else 'Vista/' + name)] = helpers / name
    for name in ('USBXHCI.inf', 'USBXHCI.cat', 'usbxhci.sys', 'usbhub3.sys', 'ucx01000.sys', 'usbd8.sys'):
        path = package / 'driver' / name
        if sha(path) != local_manifest['files'][name]:
            raise RuntimeError('Driver hash mismatch: ' + name)
        files['payload/USOS/Vista/Drivers/LocalTestVista/' + name] = path
    cab = community / 'kb/Windows6.0-KB2864202-x64.cab'
    if sha(cab) != community_manifest['cab_sha256']:
        raise RuntimeError('KB2864202 hash mismatch')
    files['payload/USOS/Vista/Updates/' + cab.name] = cab
    files['payload/USOS/Vista/local-driver-manifest.json'] = package / 'manifest.json'
    files['payload/USOS/Vista/community-driver-manifest.json'] = community / 'deployment-manifest.json'
    for name in ('windows_vista_firstboot.c', 'windows_vista_usb_bootstrap.c',
                 'windows_vista_kmdf.c', 'build_windows_vista_firstboot.py'):
        files['source/tools/' + name] = ROOT / 'tools' / name
    for name in ('vista_local_certs.h', 'vista_community_certs.h', 'vista_kmdf_cab_hash.h'):
        files['source/headers/' + name] = community / name
    files['evidence/history.md'] = ROOT / 'docs/windows-vista-community-usb-2026-09-20.md'
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    out = ROOT / 'artifacts/vista' / ('hardware-success-v11-' + stamp)
    out.mkdir(parents=True, exist_ok=False)
    hashes = {}
    for name, src in files.items():
        dst = out / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        hashes[name] = sha(dst)
        if hashes[name] != sha(src):
            raise RuntimeError('Snapshot readback mismatch: ' + name)
    (out / 'manifest.json').write_text(json.dumps({
        'version': 11,
        'evidence': 'User reports working USB mouse/keyboard and Vista desktop after v11 physical boot',
        'hardware': 'Ryzen 7 5700X / ASRock X470 Master SLI-ac / RX 560 / Intel SSD',
        'conditions': 'Vista Ultimate SP2 x64 build 6002; CSM enabled; test signing enabled',
        'limits': ['Not a complete USB installer', 'No clean reinstallation verified',
                   'OOBE performance assessment required user interruption/recovery',
                   'CBS transaction completion and RAM consumption not verified'],
        'sha256': hashes,
    }, indent=2), encoding='utf-8')
    (out / 'README.txt').write_text(
        'USOS Vista USB v11: preserved hardware-success payload.\n'
        'This archive is NOT a bootable installer or a complete system backup.\n'
        'Do not run helpers on the technician OS or re-arm Setup on the working installation.\n'
        'Fresh deployment still needs image application, correct drive mapping, BCD and pre-Setup hook.\n'
        'Payload contains public certificates in the helpers, drivers and the KMDF CAB.\n'
        'Private keys, passwords, registry hives and user files are excluded.\n'
        'Source/header snapshots are reference material; compiler and build layout are not bundled.\n', encoding='utf-8')
    archive = out.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=1) as z:
        for path in out.rglob('*'):
            if path.is_file():
                z.write(path, path.relative_to(out).as_posix())
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None:
            raise RuntimeError('Archive CRC check failed')
    print('VISTA_V11_SNAPSHOT_OK', archive)
    print('SHA256', sha(archive))
    print('PAYLOAD_FILES', len(files), 'NO_TARGET_DISK_WRITES')


if __name__ == '__main__':
    main()
