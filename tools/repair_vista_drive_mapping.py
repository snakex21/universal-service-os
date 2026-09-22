"""Prepare a minimal offline hive repair without moving or allocating cells.

The Microsoft image was captured on D:. Preserve that letter rather than
rewriting thousands of original component/COM/service paths. This program only
creates reviewed output copies; the guarded PowerShell wrapper deploys them.
"""
from pathlib import Path
import argparse, hashlib, io, json, struct, sys, uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/cache/registry-reader'))
from Registry import Registry


def inventory(reg):
    result = {}
    def walk(key, prefix=''):
        result[prefix] = {v.name(): (v.value_type(), v.raw_data()) for v in key.values()}
        for sub in key.subkeys():
            walk(sub, prefix + '\\' + sub.name())
    walk(reg.root())
    return result


def prepare(source, output):
    output.mkdir(parents=True, exist_ok=False)
    manifest = {}
    for name in ('SYSTEM', 'SOFTWARE'):
        original = (source / name).read_bytes()
        assert original[:4] == b'regf'
        seq1, seq2 = struct.unpack_from('<II', original, 4)
        assert seq1 == seq2, 'Dirty registry hive requires transaction-log recovery first'
        reg = Registry.Registry(io.BytesIO(original))
        before = inventory(reg)
        expected = {k: dict(v) for k, v in before.items()}
        data = bytearray(original)
        edits = []

        def rename(key, old, new):
            values = expected['\\' + key]
            assert old in values and new not in values
            vk = reg.open(key).value(old)._vkrecord
            encoding = 'cp1252' if vk.has_ascii_name() else 'utf-16le'
            a, b = old.encode(encoding), new.encode(encoding)
            offset = vk.absolute_offset(0x14)
            assert len(a) == len(b) and data[offset:offset+len(a)] == a
            data[offset:offset+len(a)] = b
            values[new] = values.pop(old)
            edits.append({'key': key, 'rename': [old, new]})

        def string(key, name, old, new):
            value = reg.open(key).value(name)
            assert value.value() == old and value.value_type() in (1, 2)
            raw = value.raw_data()
            a, b = old.encode('utf-16le'), new.encode('utf-16le')
            assert len(b) <= len(a) and raw == a + b'\0\0'
            vk = value._vkrecord
            assert 4 < vk.raw_data_length() < 0x3fd8
            offset = vk.data_offset() + 4
            assert data[offset:offset+len(raw)] == raw
            replacement = b + b'\0\0'
            data[offset:offset+len(raw)] = replacement.ljust(len(raw), b'\0')
            struct.pack_into('<I', data, vk.absolute_offset(0x4), len(replacement))
            expected['\\' + key][name] = (value.value_type(), replacement)
            edits.append({'key': key, 'value': name, 'old': old, 'new': new})

        if name == 'SYSTEM':
            mounted = reg.open('MountedDevices')
            identity = b'DMIO:ID:' + uuid.UUID('73dbde99-8026-4759-a19a-fd943e891d09').bytes_le
            assert mounted.value('\\DosDevices\\C:').value() == identity
            assert b'C\x00d\x00R\x00o\x00m\x00' in mounted.value('\\DosDevices\\D:').value()
            rename('MountedDevices', '\\DosDevices\\D:', '\\DosDevices\\E:')
            rename('MountedDevices', '\\DosDevices\\C:', '\\DosDevices\\D:')
            string('Setup', 'WorkingDirectory', 'C:\\Windows\\Panther', 'D:\\Windows\\Panther')
            assert reg.open('Setup').value('CmdLine').value() == 'oobe\\windeploy.exe'
            assert reg.open('Setup').value('SetupPhase').value() == 4
        else:
            key = 'Microsoft\\Windows NT\\CurrentVersion'
            assert reg.open(key).value('CurrentVersion').value() == '6.0'
            assert reg.open(key).value('CurrentBuildNumber').value() == '6002'
            string(key, 'SystemRoot', 'C:\\Windows', 'D:\\Windows')
            string('Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion', 'SystemRoot', 'C:\\Windows', 'D:\\Windows')
            string('Microsoft\\Windows\\CurrentVersion\\Setup', 'BootDir', 'C:\\', 'D:\\')
            string(key+'\\Winlogon', 'Userinit', 'C:\\Windows\\system32\\userinit.exe,D:\\Windows\\system32\\userinit.exe,', 'D:\\Windows\\system32\\userinit.exe,')
            assert reg.open(key).value('PathName').value() == 'D:\\Windows'
            assert reg.open('Microsoft\\Windows\\CurrentVersion').value('ProgramFilesDir').value() == 'D:\\Program Files'

        # Mark both sequences clean at the new revision; old transaction logs
        # remain backed up and cannot be newer than this committed primary hive.
        struct.pack_into('<II', data, 4, seq1 + 1, seq1 + 1)
        checksum = 0
        for word in struct.unpack_from('<127I', data, 0):
            checksum ^= word
        if checksum == 0: checksum = 1
        elif checksum == 0xffffffff: checksum = 0xfffffffe
        struct.pack_into('<I', data, 0x1fc, checksum)
        after = inventory(Registry.Registry(io.BytesIO(data)))
        assert after == expected, 'Unexpected registry difference'
        assert len(data) == len(original)
        (output / (name + '.original')).write_bytes(original)
        (output / name).write_bytes(data)
        manifest[name] = {'original_sha256': hashlib.sha256(original).hexdigest(),
                          'patched_sha256': hashlib.sha256(data).hexdigest(),
                          'edits': edits, 'all_registry_values_verified': True}
    (output / 'repair.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print('PREPARED_AND_ALL_VALUES_VERIFIED', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(args.source, args.output)
