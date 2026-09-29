"""Option B prototype of docs/design/bios-via-csmwrap.md: give a DOS /
Windows 3.x target disk prepared by the USOS BIOS path (MBR, one active FAT16
partition from LBA 2048, the rest unallocated) the same end-of-disk CSMWrap
ESP as the XP/Vista CSMWrap paths (tools/xp_csmwrap_esp.sh): 64 MiB FAT16,
MBR type 0xEF in the first free slot, start = the XP tail rule, with
\\EFI\\BOOT\\BOOTX64.EFI = CSMWrap and \\EFI\\BOOT\\CSMWRAP.INI.

The prepared image is only read: the result is a new qcow2 overlay.

  python add_csmwrap_esp_to_dos_target.py --prepared T.qcow2 --output T-esp.qcow2 \
      [--csmwrap-efi tools/vendor/csmwrap/3.1.2-usos2-proto/csmwrapx64.efi] [--verbose true]

Test tool only; disposable images only.
"""
from pathlib import Path
import argparse, hashlib, json, struct, subprocess, sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_csmwrap_xp_ovmf as xp  # noqa: E402  (FAT16 builder, qcow2 window writer)

ESP_SECTORS = 131072          # 64 MiB, as tools/xp_csmwrap_esp.sh
TAIL_SECTORS = 133120         # USOS_XP_ESP_TAIL_SECTORS
SECTOR = 512


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--prepared', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--csmwrap-efi', type=Path, default=xp.CSMWRAP_DIR / 'csmwrapx64.efi')
    p.add_argument('--verbose', choices=('true', 'false'), default='true')
    a = p.parse_args()
    out = a.output.resolve()
    out.unlink(missing_ok=True)
    xp.run([xp.QEMU_IMG, 'create', '-q', '-f', 'qcow2', '-F', 'qcow2', '-b', a.prepared.resolve(), out])
    size = int(json.loads(subprocess.run([str(xp.QEMU_IMG), 'info', '--output=json', str(out)],
                                         capture_output=True, check=True, text=True).stdout)['virtual-size'])
    total = size // SECTOR
    start = (total - TAIL_SECTORS + 2047) // 2048 * 2048
    assert start + ESP_SECTORS <= total
    mbr_file = out.with_suffix('.mbr')
    mbr_file.unlink(missing_ok=True)
    xp.run([xp.QEMU_IMG, 'dd', '-f', 'qcow2', '-O', 'raw', f'if={out}', f'of={mbr_file}', 'bs=512', 'count=1'])
    mbr = bytearray(mbr_file.read_bytes())
    assert mbr[510:512] == b'\x55\xaa', 'target MBR has no signature'
    free = None
    for slot in range(4):
        e = mbr[446 + 16 * slot:462 + 16 * slot]
        first, count = struct.unpack_from('<II', e, 8)
        if e[4] == 0:
            free = slot if free is None else free
            continue
        assert e[4] != 0xEF, 'target already has an ESP'
        assert first + count <= start, f'partition {slot + 1} overlaps the ESP tail area'
    assert free is not None, 'no free MBR slot'
    mbr[446 + 16 * free:462 + 16 * free] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0xEF, b'\xfe\xff\xff', start, ESP_SECTORS)
    mbr_file.write_bytes(mbr)
    efi = a.csmwrap_efi.read_bytes()
    ini = f'serial = true\nserial_port = 0x3f8\nverbose = {a.verbose}\n'
    xp.ESP_SECTORS = ESP_SECTORS
    part = out.with_suffix('.esp')
    part.write_bytes(xp.build_fat16({'EFI/BOOT/BOOTX64.EFI': efi, 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, start))
    xp.write_window(out, mbr_file, 0, SECTOR)
    xp.write_window(out, part, start * SECTOR, ESP_SECTORS * SECTOR)
    part.unlink()
    mbr_file.unlink()
    print(f'[PASS] CSMWrap ESP slot {free + 1} LBA {start} +{ESP_SECTORS} ({a.csmwrap_efi.name} '
          f'{hashlib.sha256(efi).hexdigest()[:16]}...) -> {out}')


if __name__ == '__main__':
    main()
