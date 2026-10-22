"""Prepare a stopped NT35 overlay changing only the owned LAN SYS file.

This does not start QEMU or alter the retained R20b. Microsoft contents remain
in RAM or the whole-disk scratch on G:. No host registry APIs are used.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
PRIOR = Path(r'C:\Users\ASRock\usos-work\nt35-net')
COLLECTION = Path(r'G:\USOS-Kolekcja').resolve()
BASE = COLLECTION / '_vm/r20b-nt35-usb-isolation/target.qcow2'
WORK = COLLECTION / '_vm/nt35-irq-fixed01'
OUT = ROOT / 'artifacts/nt35-irq/preparation.json'
CANDIDATE = ROOT / 'tools/nt/usosnet/bin/i386/usosnet35.sys'
BASE_HASH = 'e8edf8907be529bfa84454661bffea50b1ec20a51231572a3bd47a43046cb446'
OLD_DRIVER = 'e1aa69a3ec8e3da802013131abbb6fefc9f466da6f4eeb66fe15ec47e60421c5'
NEW_DRIVER = 'd94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
USB_HASH = '2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def outside_digest(path, ranges):
    """Hash every whole-disk byte except the exact owned SYS file ranges."""
    result = hashlib.sha256()
    with path.open('rb') as stream:
        at = 0
        for first, size in sorted(ranges) + [(path.stat().st_size, 0)]:
            if first < at or size <= 0 and first != path.stat().st_size:
                raise ValueError('Invalid or overlapping owned file ranges')
            remaining = first - at
            while remaining:
                part = stream.read(min(1024 * 1024, remaining))
                if not part:
                    raise ValueError('Short whole-disk read')
                result.update(part)
                remaining -= len(part)
            stream.seek(size, 1)
            at = first + size
    return result.hexdigest()


def main():
    if BASE.resolve() != COLLECTION / '_vm/r20b-nt35-usb-isolation/target.qcow2':
        raise ValueError('Unexpected stopped target path')
    if WORK.resolve().parent != COLLECTION / '_vm' or WORK.exists() or OUT.exists():
        raise ValueError('Fresh exact owned destination required')
    prior = PRIOR / 'artifacts/coverage/vm/r20b-nt35-usb-isolation'
    result = json.loads((prior / 'result.json').read_text('utf-8'))
    completed = json.loads((prior / 'completed.json').read_text('utf-8'))
    if result.get('qemu_returncode') != 0 or completed.get('stopped') is not True:
        raise ValueError('Retained writer completion required')
    meta = json.loads((BASE.parent / 'fixture.json').read_text('utf-8'))
    if meta.get('private_profile') is not False or meta.get('folder') != 'Windows NT 3.5':
        raise ValueError('Explicit keyless NT35 target required')
    if digest(BASE) != BASE_HASH or digest(CANDIDATE) != NEW_DRIVER:
        raise ValueError('Pinned base or owned candidate differs')
    candidate = CANDIDATE.read_bytes()
    if len(candidate) != 16384:
        raise ValueError('Exact existing file size required')
    if shutil.disk_usage(COLLECTION).free < 100 * 1024**3:
        raise ValueError('Less than100GiB free')
    helper = load('nt35_irq_stopped', Path(__file__).with_name('prepare_nt35_usb_isolated.py'))
    h = helper.h
    WORK.mkdir()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    raw = WORK / 'scratch-stopped.raw'
    overlay = WORK / 'target.qcow2'
    env = dict(os.environ, TEMP=str(WORK), TMP=str(WORK), APPDATA=str(WORK), LOCALAPPDATA=str(WORK))
    subprocess.run([str(h.QIMG), 'convert', '-f', 'qcow2', '-O', 'raw', str(BASE), str(raw)], env=env, check=True)
    fs = h.BoundedFat(raw)
    try:
        if fs.fat32 or fs.base != 32256 or fs.bps != 512:
            raise ValueError('Expected retained NT35 FAT16 layout')
        original, offsets = h.file_data(fs, 'WINNT/SYSTEM32/DRIVERS/usosnet35.sys', 16384)
        system, _ = h.file_data(fs, 'WINNT/SYSTEM32/CONFIG/SYSTEM', 4 * 1024**2)
        usb, _ = h.file_data(fs, 'WINNT/SYSTEM32/DRIVERS/usosusb.sys', 32128)
        if len(original) != 16384 or hashlib.sha256(original).hexdigest() != OLD_DRIVER:
            raise ValueError('Retained own SYS differs')
        if len(usb) != 32128 or hashlib.sha256(usb).hexdigest() != USB_HASH:
            raise ValueError('Frozen USB differs')
        cluster_size = fs.csize
    finally:
        fs.f.close()
    values, _, version = helper.read_hive(system)
    if version != (1, 2) or values['select']['current'] != (4, struct.pack('<I', 1)) or values['select']['default'] != values['select']['current']:
        raise ValueError('Measured REGF1.2/CurrentDefault1 required')
    if values['controlset001\\services\\i8042prt'].get('start') != (4, struct.pack('<I', 4)):
        raise ValueError('Existing USB isolation Start4 required')
    if values['controlset001\\services\\ndisloop'].get('imagepath') != (2, '\\SystemRoot\\System32\\drivers\\usosnet35.sys'.encode('utf-16le') + b'\0\0'):
        raise ValueError('Retained service must already point to the owned SYS')
    ranges = [(at, len(candidate[index * cluster_size:(index + 1) * cluster_size])) for index, at in enumerate(offsets)]
    before = outside_digest(raw, ranges)
    with raw.open('r+b') as stream:
        for index, at in enumerate(offsets):
            stream.seek(at)
            stream.write(candidate[index * cluster_size:(index + 1) * cluster_size])
        stream.flush()
    if outside_digest(raw, ranges) != before:
        raise ValueError('A byte outside the exact owned SYS ranges changed')
    fs = h.BoundedFat(raw)
    try:
        for path, expected in (('WINNT/SYSTEM32/DRIVERS/usosnet35.sys', candidate),
                               ('WINNT/SYSTEM32/CONFIG/SYSTEM', system),
                               ('WINNT/SYSTEM32/DRIVERS/usosusb.sys', usb)):
            if h.file_data(fs, path, len(expected))[0] != expected:
                raise ValueError('Stopped readback differs')
    finally:
        fs.f.close()
    subprocess.run([str(h.QIMG), 'convert', '-f', 'raw', '-O', 'qcow2', '-B', str(BASE), '-F', 'qcow2', str(raw), str(overlay)], env=env, check=True)
    subprocess.run([str(h.QIMG), 'compare', '-f', 'raw', '-F', 'qcow2', str(raw), str(overlay)], env=env, check=True)
    if digest(BASE) != BASE_HASH:
        raise ValueError('Retained backing changed')
    meta.update(stopped_parent=str(BASE), diagnostic_only=True, owned_lan_sha256=NEW_DRIVER,
                only_guest_file_change='WINNT/SYSTEM32/DRIVERS/usosnet35.sys')
    (WORK / 'fixture.json').write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')
    record = dict(base=str(BASE), base_sha256=BASE_HASH, base_unchanged=True,
        overlay=str(overlay), overlay_sha256=digest(overlay), candidate_sha256=NEW_DRIVER,
        previous_driver_sha256=OLD_DRIVER, candidate_bytes=16384, usb_sha256=USB_HASH,
        system_sha256=hashlib.sha256(system).hexdigest(), hive_version=version,
        current_default=1, i8042prt_start=4, system_unchanged=True, usb_unchanged=True,
        only_owned_sys_ranges_changed=True, outside_owned_sys_sha256=before,
        raw_overlay_qemu_compare_pass=True, ms_files_exported=False, vm_started=False,
        scope='Diagnostic stopped NT35 overlay only; no Windows runtime PASS')
    if raw.resolve().parent != WORK.resolve() or raw.name != 'scratch-stopped.raw':
        raise ValueError('Unexpected disposable whole-disk scratch')
    raw.unlink()
    record['scratch_raw_removed'] = True
    OUT.write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(record, indent=2), flush=True)


if __name__ == '__main__':
    main()
