"""Put the committed USOS Legacy Stage 1 and Core slot on a disposable GPT
test image, the way the installer's legacyboot step does it:
Stage 1 = the first 440 bytes of the protective MBR (partition table and
signature kept), Core slot = 512 sectors at LBA 64 (must be zero before).

Source: installer/internal/payload/legacy_boot_generated.go (SHA-256 checked).
Test tool for docs/design/bios-via-csmwrap.md; image files only.
"""
from pathlib import Path
import argparse, base64, hashlib, re, struct

ROOT = Path(__file__).resolve().parents[3]
GENERATED = ROOT / 'installer/internal/payload/legacy_boot_generated.go'
SECTOR, CORE_LBA, CORE_SECTORS = 512, 64, 512


def payload():
    text = GENERATED.read_text(encoding='utf-8')
    const = lambda name: re.search(r'const %s = "([^"]+)"' % name, text).group(1)
    stage1 = base64.b64decode(const('legacyStage1Base64'))
    core = base64.b64decode(const('legacyCoreBase64'))
    assert hashlib.sha256(stage1).hexdigest().upper() == const('legacyStage1SHA256')
    assert hashlib.sha256(core).hexdigest().upper() == const('legacyCoreSHA256')
    assert len(stage1) == 440 and len(core) == CORE_SECTORS * SECTOR and core[:8] == b'USOSCORE'
    return stage1, core


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--image', type=Path, required=True)
    p.add_argument('--core-slot', type=Path, help='a freshly built zig-out/<dir>/core-slot.bin instead of the committed Core')
    p.add_argument('--replace', action='store_true', help='the image already carries a USOS Core slot: replace it')
    a = p.parse_args()
    stage1, core = payload()
    if a.core_slot:
        core = a.core_slot.read_bytes()
        assert len(core) == CORE_SECTORS * SECTOR and core[:8] == b'USOSCORE'
        print('[CORE] prototype', a.core_slot, hashlib.sha256(core).hexdigest())
    with a.image.open('r+b') as f:
        mbr = bytearray(f.read(SECTOR))
        assert mbr[510:512] == b'\x55\xaa', 'no MBR signature'
        types = [mbr[446 + 16 * i + 4] for i in range(4)]
        assert types.count(0xEE) == 1 and all(t in (0, 0xEE) for t in types), 'not a protective MBR'
        gpt = f.read(SECTOR)
        assert gpt[:8] == b'EFI PART'
        entries_lba, count, size = struct.unpack_from('<QII', gpt, 72)
        assert entries_lba + (count * size + SECTOR - 1) // SECTOR <= CORE_LBA, 'GPT entries overlap the Core slot'
        f.seek(entries_lba * SECTOR)
        entries = f.read(count * size)
        starts = [struct.unpack_from('<Q', entries, i * size + 32)[0] for i in range(count) if entries[i * size:i * size + 16] != b'\0' * 16]
        assert min(starts) >= CORE_LBA + CORE_SECTORS, 'a partition overlaps the Core slot'
        f.seek(CORE_LBA * SECTOR)
        before = f.read(len(core))
        assert before == b'\0' * len(core) or (a.replace and before[:8] == b'USOSCORE'), 'Core slot is not empty'
        mbr[:440] = stage1
        f.seek(0); f.write(mbr)
        f.seek(CORE_LBA * SECTOR); f.write(core)
        f.flush()
        f.seek(0); assert f.read(440) == stage1
        f.seek(CORE_LBA * SECTOR); assert f.read(len(core)) == core
    print('[PASS] Legacy Stage 1 + Core slot written and read back:', a.image)


if __name__ == '__main__':
    main()
