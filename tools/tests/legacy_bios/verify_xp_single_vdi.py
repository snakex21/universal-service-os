"""Read-only verification of the installed, powered-off single-volume XP guest."""
import argparse
import json
import struct


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('vdi')
    args = parser.parse_args()
    with open(args.vdi, 'rb') as handle:
        header = handle.read(512)
        assert struct.unpack_from('<I', header, 64)[0] == 0xbeda107f
        map_offset, data_offset = struct.unpack_from('<II', header, 340)
        block_size, extra = struct.unpack_from('<II', header, 376)

        def read(offset, length):
            result = bytearray()
            while length:
                block, inside = divmod(offset, block_size)
                count = min(length, block_size - inside)
                handle.seek(map_offset + block * 4)
                index = struct.unpack('<I', handle.read(4))[0]
                assert index < 0xfffffffe, 'Required metadata block is unallocated'
                handle.seek(data_offset + index * (block_size + extra) + extra + inside)
                result.extend(handle.read(count))
                offset += count
                length -= count
            return bytes(result)

        mbr = read(0, 512)
        assert mbr[510:] == b'\x55\xaa'
        entries = [mbr[446 + i * 16:462 + i * 16] for i in range(4)]
        occupied = [entry for entry in entries if entry != bytes(16)]
        assert len(occupied) == 1, 'A helper partition remains'
        entry = occupied[0]
        assert entry[0] == 0x80 and entry[4] == 7
        start, sectors = struct.unpack_from('<II', entry, 8)
        assert start == 2048 and sectors >= 16777216
        boot = read(start * 512, 512)
        assert boot[3:11] == b'NTFS    ', 'Installed volume is not NTFS'
        assert boot[510:] == b'\x55\xaa'
        assert struct.unpack_from('<H', boot, 11)[0] == 512
        assert boot[13] == 8, 'Expected 4 KiB NTFS clusters'
        assert struct.unpack_from('<I', boot, 28)[0] == start
        assert struct.unpack_from('<HH', boot, 24) == (63, 240)
        ntfs_sectors = struct.unpack_from('<Q', boot, 40)[0]
        assert ntfs_sectors <= sectors
        print(json.dumps(dict(result='PASS', partitions=1, active=True, filesystem='NTFS',
                              cluster_bytes=4096, start_lba=start, partition_sectors=sectors,
                              ntfs_sectors=ntfs_sectors, bios_heads=240, bios_spt=63)))


if __name__ == '__main__':
    main()
