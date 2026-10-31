#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Small file-only native Windows oracle for REGF and BCD (no hive mounting).

python-registry reads an original while an open handle denies every writer.
Additional RegLoadAppKeyW(KEY_READ) checks use separate writable copies because
Windows requests write access to the file even for read-only registry access.
Neither RegLoadKey nor host registry locations are used. WMI creates separate
reference stores with synthetic identities; real bcdboot comparison is separate.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import io
from importlib.metadata import version
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil

REPO = Path(__file__).resolve().parents[2]
GUID_BOOTMGR = '{9dea862c-5cdd-4e70-acc1-f32b344d4795}'
GUID_LOADER = '{cbd971bf-b7b8-4885-951a-fa03044f5d71}'
DISK = '{00112233-4455-4677-8899-aabbccddeeff}'
WIN = '{10213243-5465-4677-8899-aabbccddeeff}'
ESP = '{20314253-6475-4677-8899-aabbccddeeff}'


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def independent_read(path):
    """Third-party parser, original file locked against writing or deletion."""
    from Registry import Registry
    path = path.resolve(strict=True)
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError('Bounded regular hive required')
    k = C.WinDLL('kernel32', use_last_error=True)
    k.CreateFileW.argtypes = [W.LPCWSTR, W.DWORD, W.DWORD, C.c_void_p, W.DWORD, W.DWORD, W.HANDLE]
    k.CreateFileW.restype = W.HANDLE
    k.CloseHandle.argtypes = [W.HANDLE]
    lock = k.CreateFileW(str(path), 0x80000000, 1, None, 3, 0x80, None)
    if lock == C.c_void_p(-1).value:
        raise C.WinError(C.get_last_error())
    try:
        before = sha(path)
        registry = Registry.Registry(io.BytesIO(path.read_bytes()))
        result = {}

        def visit(key, rel, depth):
            if depth > 512 or len(result) > 100000:
                raise ValueError('Oversized key tree')
            values = result[rel.lower()] = {}
            for value in key.values():
                record = value._vkrecord
                length = record.raw_data_length()
                # python-registry raw_data() assumes an external cell for an
                # inline REG_DWORD_BIG_ENDIAN and drops empty MULTI_SZ bytes.
                # Its own low-level VK accessor exposes the correct raw field.
                if length & 0x80000000:
                    length &= 0x7fffffff
                    if length > 4:
                        raise ValueError('Oversized inline value')
                    data = record.unpack_binary(8, length)
                else:
                    data = value.raw_data()
                name = value.name().lower() if value.name() != '(default)' else ''
                values[name] = (value.value_type(), data)
            for child in key.subkeys():
                visit(child, rel + '\\' + child.name() if rel else child.name(), depth + 1)
        visit(registry.root(), '', 0)
        if sha(path) != before:
            raise ValueError('Read-only source hive changed')
        return result
    finally:
        k.CloseHandle(lock)


def native_read(path):
    """Native load acceptance on an isolated writable copy, KEY_READ keys."""
    if os.name != 'nt':
        raise RuntimeError('Native Windows oracle required')
    path = path.resolve(strict=True)
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError('Bounded regular hive required')
    a = C.WinDLL('advapi32', use_last_error=True)
    a.RegLoadAppKeyW.argtypes = [W.LPCWSTR, C.POINTER(W.HKEY), W.DWORD, W.DWORD, W.DWORD]
    a.RegCloseKey.argtypes = [W.HKEY]
    a.RegOpenKeyExW.argtypes = [W.HKEY, W.LPCWSTR, W.DWORD, W.DWORD, C.POINTER(W.HKEY)]
    a.RegEnumKeyExW.argtypes = [W.HKEY, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD), C.c_void_p, W.LPWSTR, C.POINTER(W.DWORD), C.c_void_p]
    a.RegEnumValueW.argtypes = [W.HKEY, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD), C.c_void_p, C.POINTER(W.DWORD), C.c_void_p, C.POINTER(W.DWORD)]
    root = W.HKEY()
    result = {}
    try:
        status = a.RegLoadAppKeyW(str(path), C.byref(root), 0x20019, 0, 0)
        if status:
            raise OSError(status, 'RegLoadAppKeyW(KEY_READ)')

        def visit(key, rel, depth):
            if depth > 512 or len(result) > 100000:
                raise ValueError('Oversized native key tree')
            values = result[rel.lower()] = {}
            index = 0
            while True:
                name = C.create_unicode_buffer(16384)
                length, kind, size = W.DWORD(16384), W.DWORD(), W.DWORD(256 * 1024)
                data = C.create_string_buffer(size.value)
                status = a.RegEnumValueW(key, index, name, C.byref(length), None, C.byref(kind), data, C.byref(size))
                if status == 259:
                    break
                if status == 234:
                    if size.value > 16 * 1024 * 1024:
                        raise ValueError('Oversized native value')
                    data = C.create_string_buffer(size.value)
                    length.value = 16384
                    status = a.RegEnumValueW(key, index, name, C.byref(length), None, C.byref(kind), data, C.byref(size))
                if status:
                    raise OSError(status, 'RegEnumValueW')
                values[name.value.lower()] = (kind.value, data.raw[:size.value])
                index += 1
            index = 0
            while True:
                name, length = C.create_unicode_buffer(256), W.DWORD(256)
                status = a.RegEnumKeyExW(key, index, name, C.byref(length), None, None, None, None)
                if status == 259:
                    break
                if status:
                    raise OSError(status, 'RegEnumKeyExW')
                child = W.HKEY()
                status = a.RegOpenKeyExW(key, name.value, 0, 0x20019, C.byref(child))
                if status:
                    raise OSError(status, 'RegOpenKeyExW')
                try:
                    visit(child, rel + '\\' + name.value if rel else name.value, depth + 1)
                finally:
                    a.RegCloseKey(child)
                index += 1
        visit(root, '', 0)
    finally:
        if root.value:
            a.RegCloseKey(root)
    return result


def verify_both(path, out):
    tree = independent_read(path)
    copies = out / 'native-copies'
    copies.mkdir(exist_ok=True)
    copy = copies / (str(len(list(copies.glob('*.hiv')))) + '-' + path.name + '.hiv')
    shutil.copyfile(path, copy)
    assert native_read(copy) == tree
    return tree


def manifest(tree):
    return {key: {name: dict(type=kind, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                            hex=data.hex() if len(data) < 128 else None)
                  for name, (kind, data) in values.items()} for key, values in tree.items()}


def element(tree, obj, code):
    return tree[f'objects\\{obj}\\elements\\{code}'.lower()]['element']


def command(args, out, name, head, dirty):
    target = out / name
    with target.open('xb') as log:
        log.write(f'HEAD {head}\nWORKTREE_DIRTY {dirty}\n'.encode())
        log.flush()
        p = subprocess.run(list(map(str, args)), cwd=REPO, stdout=log, stderr=subprocess.STDOUT,
                           creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS if os.name == 'nt' else 0)
        log.write(f'EXIT {p.returncode}\n'.encode())
    if p.returncode:
        raise RuntimeError(f'{name}: exit {p.returncode}')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--pwsh', type=Path, required=True)
    p.add_argument('--template', type=Path)
    p.add_argument('--require-clean', action='store_true')
    args = p.parse_args()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    dirty = len(subprocess.check_output(['git', 'status', '--porcelain=v1', '-uall'], cwd=REPO, text=True).splitlines())
    print(f'HEAD {head}\nWORKTREE_DIRTY {dirty}', flush=True)
    if args.require_clean and dirty:
        raise ValueError('Final evidence requires clean tree')
    out = args.out.resolve()
    if out.exists() or str(out).startswith('\\\\'):
        raise ValueError('New regular evidence directory required')
    out.mkdir(parents=True)
    exe = args.exe.resolve(strict=True)
    command([exe, 'fixture', out / 'fixtures'], out, 'fixture.log', head, dirty)
    fresh = verify_both(out / 'fixtures' / 'fresh.hiv', out)
    values = fresh['alltypes\\zażółć']
    for kind in range(12):
        raw = bytes([kind, 1, 2, 3, 4, 5, 6, 7])
        assert values['type' + chr(ord('a') + kind)] == (kind, raw[:4] if kind in (4,5) else raw)
    assert values['big'] == (3, bytes((i * 31) & 255 for i in range(131129)))
    assert values[''] == (0, b'')
    assert values['inline'] == (4, bytes.fromhex('78563412'))
    edited = verify_both(out / 'fixtures' / 'edited.hiv', out)
    expected = {key: dict(value) for key, value in fresh.items()}
    expected['alltypes\\zażółć']['big'] = (3, b'replacement')
    expected['added'] = {}
    expected['added\\child'] = {'value': (11, b'01234567')}
    assert edited == expected
    (out / 'fresh-native.json').write_text(json.dumps(manifest(fresh), indent=2), encoding='utf-8')
    (out / 'edited-native.json').write_text(json.dumps(manifest(edited), indent=2), encoding='utf-8')
    modes = [('uefi', 'gpt', DISK, WIN, ESP), ('bios', 'mbr', '0x12345678', '1048576', '1048576')]
    for mode, style, disk, win, system in modes:
        store = out / f'BCD-{mode}'
        command([exe, 'bcd', store, mode, style, disk, win, system, 'pl-PL', 'Windows MiniOS'], out, f'{mode}-write.log', head, dirty)
        tree = verify_both(store, out)
        assert element(tree, GUID_LOADER, '12000002') == (1, f'\\Windows\\system32\\winload.{"efi" if mode == "uefi" else "exe"}\0'.encode('utf-16le'))
        assert element(tree, GUID_LOADER, '12000005') == (1, 'pl-PL\0'.encode('utf-16le'))
        assert element(tree, GUID_LOADER, '26000022') == (3, b'\0')
        (out / f'{mode}-native.json').write_text(json.dumps(manifest(tree), indent=2), encoding='utf-8')
        reference = out / f'BCD-native-device-{mode}'
        command([args.pwsh, '-NoProfile', '-File', REPO / 'tools/minios/bcd_qualified_reference.ps1',
                 '-Store', reference, '-Style', style.upper(), '-Disk', disk if style == 'gpt' else '305419896',
                 '-Partition', win], out, f'{mode}-native-reference.log', head, dirty)
        ref = verify_both(reference, out)
        assert element(tree, GUID_LOADER, '11000001') == element(ref, GUID_BOOTMGR, '11000001')
        assert element(tree, GUID_LOADER, '21000001') == element(ref, GUID_BOOTMGR, '11000001')
        enum_copy = out / f'BCD-enum-copy-{mode}'
        shutil.copyfile(store, enum_copy)
        command(['bcdedit.exe', '/store', enum_copy, '/enum', 'all', '/v'], out, f'{mode}-bcdedit-enum.log', head, dirty)
        enum_tree = independent_read(enum_copy)
        # BCDEdit's offline store open removes this runtime classification.
        # Preserve the writer's source; allow exactly that one copy-side edit.
        enum_expected = {key: dict(value) for key, value in tree.items()}
        enum_expected['description'].pop('treatassystem')
        assert enum_tree in (tree, enum_expected)
    if args.template:
        template = args.template.resolve(strict=True)
        before = independent_read(template)
        target = out / 'edited-template.hiv'
        command([exe, 'edit', template, target], out, 'template-edit.log', head, dirty)
        after = verify_both(target, out)
        expected = {key: dict(value) for key, value in before.items()}
        expected['miniosproof'] = {}
        expected['miniosproof\\added'] = {'proof': (3, b'offline-editor')}
        assert after == expected
        (out / 'template-native.json').write_text(json.dumps(manifest(after), indent=2), encoding='utf-8')
    head_after = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    dirty_after = len(subprocess.check_output(['git', 'status', '--porcelain=v1', '-uall'], cwd=REPO, text=True).splitlines())
    if args.require_clean and (head_after != head or dirty_after):
        raise ValueError('Tree changed during evidence gate')
    files = {str(x.relative_to(out)): {'bytes': x.stat().st_size, 'sha256': sha(x)}
             for x in sorted(out.rglob('*')) if x.is_file()}
    receipt = dict(head=head, dirty=dirty, after_head=head_after, after_dirty=dirty_after,
                   executable_sha256=sha(exe), python_registry_version=version('python-registry'),
                   independent_readonly_regf='PASS', native_copy_regf='PASS', native_gpt_mbr_device='PASS', bcdedit_copy='PASS',
                   native_copy_note='BCDEdit may remove Description/TreatAsSystem on its own copy; original remains read-only',
                   bcdboot_comparison='PENDING_REAL_LAYOUT', files=files)
    (out / 'result.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print('REGF_BCD_NATIVE PASS; real-layout BCDBOOT gate pending')


if __name__ == '__main__':
    main()
