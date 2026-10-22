"""Read only a completed installed-NT35 qualification disk; never start a VM."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
WORK = Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-fixed01')
BASE = Path(r'G:\USOS-Kolekcja\_vm\r20b-nt35-usb-isolation\target.qcow2')
CASE = ROOT / 'artifacts/coverage/vm/nt35-irq-fixed01'
OUT = ROOT / 'artifacts/nt35-irq/stopped-readback'
PROOF_PATH = ROOT / 'artifacts/nt35-irq/preparation.json'
CANDIDATE = 'd94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
USB = '2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1'
TEXTS = ('NET35.STATUS', 'NET35.ON', 'USABILITY.TXT', 'POST.LOG', 'USOSNET35.SHA256', 'IRQPOST.LOG')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    result = json.loads((CASE / 'result.json').read_text('utf-8'))
    completed = json.loads((CASE / 'completed.json').read_text('utf-8'))
    proof = json.loads(PROOF_PATH.read_text('utf-8'))
    meta = json.loads((WORK / 'fixture.json').read_text('utf-8'))
    if completed.get('stopped') is not True or result.get('qemu_returncode') != 0:
        raise ValueError('Completed writer exit0 required')
    if meta.get('private_profile') is not False or meta.get('folder') != 'Windows NT 3.5':
        raise ValueError('Explicit keyless NT35 required')
    allowed = (Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-fixed01'),
               Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-usb01'))
    if OUT.exists() or WORK.resolve() not in allowed:
        raise ValueError('Fresh exact owned readback required')
    if digest(BASE) != proof['base_sha256']:
        raise ValueError('Retained R20b backing changed')
    spec = importlib.util.spec_from_file_location('nt35_irq_readback_h', Path(__file__).with_name('prepare_nt35_usb_isolated.py'))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    h = helper.h
    raw = WORK / 'readback-stopped.raw'
    target = WORK / 'target.qcow2'
    if raw.exists():
        raise FileExistsError('Fresh whole-disk scratch required')
    target_hash = digest(target)
    env = dict(os.environ, TEMP=str(WORK), TMP=str(WORK), APPDATA=str(WORK), LOCALAPPDATA=str(WORK))
    subprocess.run([str(h.QIMG), 'convert', '-f', 'qcow2', '-O', 'raw', str(target), str(raw)], env=env, check=True)
    fs = h.BoundedFat(raw)
    own = {}
    try:
        if fs.fat32 or fs.base != 32256 or fs.bps != 512:
            raise ValueError('Exact retained FAT16 layout required')
        driver, _ = h.file_data(fs, 'WINNT/SYSTEM32/DRIVERS/usosnet35.sys', 16384)
        usb, _ = h.file_data(fs, 'WINNT/SYSTEM32/DRIVERS/usosusb.sys', 32128)
        system, _ = h.file_data(fs, 'WINNT/SYSTEM32/CONFIG/SYSTEM', 4 * 1024**2)
        if len(driver) != 16384 or hashlib.sha256(driver).hexdigest() != CANDIDATE:
            raise ValueError('Installed own IRQ candidate differs')
        if len(usb) != 32128 or hashlib.sha256(usb).hexdigest() != USB:
            raise ValueError('Frozen own USB differs')
        for name in TEXTS:
            data, _ = h.file_data(fs, 'USOS/NT3/' + name, 256 * 1024)
            if b'\0' in data:
                raise ValueError('NUL in own text evidence')
            data.decode('utf-8')
            own[name] = data
    finally:
        fs.f.close()
    values, _, version = helper.read_hive(system)
    if version != (1, 2) or values['select']['current'] != (4, struct.pack('<I', 1)) or values['select']['default'] != values['select']['current']:
        raise ValueError('Measured REGF1.2/CurrentDefault1 required')
    if values['controlset001\\services\\i8042prt'].get('start') != (4, struct.pack('<I', 4)):
        raise ValueError('USB isolation Start4 changed')
    if digest(target) != target_hash or digest(BASE) != proof['base_sha256']:
        raise ValueError('A stopped disk changed during readback')
    OUT.mkdir(parents=True)
    for name, data in own.items():
        (OUT / name).write_bytes(data)
    record = dict(stopped=True, qemu_returncode=0, installed_candidate_sha256=CANDIDATE,
        installed_candidate_bytes=16384, usb_sha256=USB, i8042prt_start=4,
        hive_version=version, current_default=1, target_sha256=target_hash,
        base_sha256=proof['base_sha256'], base_unchanged=True,
        system_sha256=hashlib.sha256(system).hexdigest(),
        files={name: dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest()) for name, data in own.items()},
        old_staging_manifest_scope='NET35 metadata and USOSNET35.SHA256 remain the historical R20 source; actual installed SYS is measured independently',
        ms_hive_or_driver_exported=False, windows_runtime_pass=False,
        scope='Stopped exact SYS/USB/isolation and bounded own text readback; manual native screenshots and completed network capture determine runtime')
    if raw.resolve().parent != WORK.resolve() or raw.name != 'readback-stopped.raw':
        raise ValueError('Unexpected disposable whole-disk scratch')
    raw.unlink()
    record['scratch_raw_removed'] = True
    (OUT / 'readback.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(json.dumps(record, indent=2), flush=True)


if __name__ == '__main__':
    main()
