"""Unit tests for the release forbidden-content scanner and zip writer
(tools/release/scan_release.py, tools/release/assemble_release.py)."""
from pathlib import Path
import gzip, io, sys, zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'release'))
import scan_release  # noqa: E402
import assemble_release  # noqa: E402

KEY = b'BCDFG-HJKMP-QRTVW-XY234-6789B'


def newc(entries):
    out = b''
    for name, data in list(entries.items()) + [('TRAILER!!!', b'')]:
        n = name.encode() + b'\0'
        header = b'070701' + b''.join(b'%08X' % v for v in (0, 0o100644, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0))
        out += header + n
        out += b'\0' * (-len(out) % 4) + data
        out += b'\0' * (-len(out) % 4)
    return out


def run(tmp_path, files, allowed=()):
    for name, data in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return scan_release.scan(tmp_path, allowed_iso_sha256=allowed)


def test_clean_folder_passes(tmp_path):
    assert run(tmp_path, {'README.md': b'Product key format XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, never shipped.'}) == []


def test_product_key_in_nested_initramfs(tmp_path):
    init = gzip.compress(newc({'etc/winnt.sif': b'[UserData]\r\nProductKey=' + KEY + b'\r\n'}), mtime=0)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr('EFI/USOS-XP/initramfs-xp', init)
    findings = run(tmp_path, {'pkg.zip': buf.getvalue()})
    assert any('product-key pattern' in f for f in findings)
    assert any('filled answer field' in f and 'winnt.sif' in f for f in findings)


def test_private_key_and_key_store(tmp_path):
    findings = run(tmp_path, {'a.txt': b'-----BEGIN RSA PRIVATE KEY-----\nMII\n', 'LICENSES/x/mok.pfx': b'\x30\x82'})
    assert any('PEM private key' in f for f in findings)
    assert any('key-store file name' in f for f in findings)


def test_iso_needs_allowlist(tmp_path):
    iso = b'\0' * 0x8001 + b'CD001' + b'\0' * 100
    assert any('not on the allowlist' in f for f in run(tmp_path, {'disk.bin': iso}))
    allowed = {scan_release.sha256(iso)}
    assert run(tmp_path, {'disk.bin': iso}, allowed) == []


def test_empty_answer_profile_passes(tmp_path):
    ini = b'[user]\r\nuser=\r\npassword=\r\nkey=\r\n'
    assert run(tmp_path, {'Profiles/vista.ini': ini}) == []
    assert any('filled answer field' in f for f in run(tmp_path, {'Profiles/vista.ini': b'password=Secret1\r\n'}))


def test_zip_is_deterministic(tmp_path):
    src = tmp_path / 'f.bin'
    src.write_bytes(b'abc' * 1000)
    digests = []
    for i in range(2):
        z = assemble_release.Zip(tmp_path / f'{i}.zip', 1790623834)
        z.add_text('README.txt', 'line\n')
        z.add_file('a/f.bin', src)
        z.close()
        digests.append(scan_release.sha256((tmp_path / f'{i}.zip').read_bytes()))
    assert digests[0] == digests[1]
    with zipfile.ZipFile(tmp_path / '0.zip') as z:
        assert z.namelist() == ['README.txt', 'a/f.bin']
        assert z.read('README.txt') == b'line\r\n'


def test_trusted_archive_is_not_scanned(tmp_path):
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, 'w') as z:
        z.writestr('go/src/crypto/tls/testdata/key.pem', b'-----BEGIN RSA PRIVATE KEY-----' + b'A' * 5000)
    archive = inner.getvalue()
    outer = io.BytesIO()
    with zipfile.ZipFile(outer, 'w') as z:
        z.writestr('toolchains/go.zip', archive)
    (tmp_path / 'kit.zip').write_bytes(outer.getvalue())
    assert any('PEM private key' in f for f in scan_release.scan(tmp_path))
    scan_release.TRUSTED_ARCHIVES.add(scan_release.sha256(archive))
    try:
        assert scan_release.scan(tmp_path) == []
    finally:
        scan_release.TRUSTED_ARCHIVES.discard(scan_release.sha256(archive))
