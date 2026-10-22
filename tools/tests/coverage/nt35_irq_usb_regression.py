"""Prepare or run one unchanged stopped-overlay USB regression for IRQ-fixed NT35."""
from pathlib import Path
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[3]
BASE = Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-fixed01')
WORK = Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-usb01')
SOURCE = ROOT / 'artifacts/coverage/vm/nt35-irq-fixed01'
OUT = ROOT / 'artifacts/nt35-irq-usb'
BASE_SHA256 = '10020a0db9f57ab2b0029a9d292b0f6f055bd82747d1f20dd2609163aaa48603'
DRIVER = 'd94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
COMMAND = '4e366fc32ee4d6fc71fd3fe5f6f8d2797cb087a0018a0fabe17bf781883be848'


def load_runner():
    path = Path(__file__).with_name('boot_nt35_irq_fixed.py')
    spec = importlib.util.spec_from_file_location('nt35_irq_usb_core', path)
    core = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core)
    return core


def prepare():
    core = load_runner()
    result = json.loads((SOURCE / 'result.json').read_text('utf-8'))
    completed = json.loads((SOURCE / 'completed.json').read_text('utf-8'))
    readback = json.loads((ROOT / 'artifacts/nt35-irq/stopped-readback/readback.json').read_text('utf-8'))
    meta = json.loads((BASE / 'fixture.json').read_text('utf-8'))
    if result.get('qemu_returncode') != 0 or completed.get('stopped') is not True:
        raise ValueError('Completed fixed01 writer required')
    if meta.get('private_profile') is not False or meta.get('folder') != 'Windows NT 3.5':
        raise ValueError('Explicit keyless NT35 required')
    if readback.get('target_sha256') != BASE_SHA256 or readback.get('installed_candidate_sha256') != DRIVER or readback.get('i8042prt_start') != 4:
        raise ValueError('Exact fixed01 candidate and Start4 readback required')
    if core.digest(BASE / 'target.qcow2') != BASE_SHA256 or core.digest(SOURCE / 'command.json') != COMMAND:
        raise ValueError('Pinned fixed01 input changed')
    if WORK.resolve().parent != Path(r'G:\USOS-Kolekcja\_vm') or WORK.exists() or OUT.exists():
        raise ValueError('Fresh exact owned paths required')
    WORK.mkdir()
    OUT.mkdir(parents=True)
    env = dict(os.environ, TEMP=str(WORK), TMP=str(WORK), APPDATA=str(WORK), LOCALAPPDATA=str(WORK))
    qimg = core.QEMU.with_name('qemu-img.exe')
    target = WORK / 'target.qcow2'
    subprocess.run([str(qimg), 'create', '-q', '-f', 'qcow2', '-F', 'qcow2', '-b', str(BASE / 'target.qcow2'), str(target)], env=env, check=True)
    subprocess.run([str(qimg), 'compare', '-f', 'qcow2', '-F', 'qcow2', str(BASE / 'target.qcow2'), str(target)], env=env, check=True)
    if core.digest(BASE / 'target.qcow2') != BASE_SHA256:
        raise ValueError('Stopped parent changed')
    meta.update(stopped_parent=str(BASE / 'target.qcow2'), diagnostic_only=True,
                only_guest_file_change=None, usb_regression_only=True)
    (WORK / 'fixture.json').write_text(json.dumps(meta, indent=2), encoding='utf-8')
    proof = dict(base=str(BASE / 'target.qcow2'), base_sha256=BASE_SHA256, base_unchanged=True,
        overlay=str(target), overlay_sha256=core.digest(target), guest_contents_unchanged=True,
        effective_disk_compare_pass=True, system_unchanged=True, usb_unchanged=True,
        candidate_sha256=DRIVER, candidate_bytes=16384, i8042prt_start=4,
        system_sha256=readback['system_sha256'], usb_sha256=readback['usb_sha256'],
        source_command_sha256=COMMAND, source_start4_readback_sha256=core.digest(ROOT / 'artifacts/nt35-irq/stopped-readback/readback.json'),
        vm_started=False, scope='Unchanged stopped fixed01 overlay; no new guest file or registry modification')
    (OUT / 'preparation.json').write_text(json.dumps(proof, indent=2), encoding='utf-8')
    print(json.dumps(proof, indent=2), flush=True)


async def run():
    core = load_runner()
    core.TAG = WORK.name
    core.WORK = WORK
    core.BASE = BASE
    core.SOURCE = SOURCE
    core.OUT = ROOT / 'artifacts/coverage/vm' / WORK.name
    core.SOURCE_COMMAND_SHA256 = COMMAND
    core.PROOF_PATH = OUT / 'preparation.json'
    core.EXTRA_SOURCE_PATHS = (Path(__file__),)
    core.SCOPE = 'USB regression of the installed IRQ-fixed NT35 candidate; no fresh installation or new LAN qualification'
    return await core.main()


def readback():
    path = Path(__file__).with_name('readback_nt35_irq_fixed.py')
    spec = importlib.util.spec_from_file_location('nt35_irq_usb_stopped', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.WORK = WORK
    module.BASE = BASE / 'target.qcow2'
    module.CASE = ROOT / 'artifacts/coverage/vm' / WORK.name
    module.OUT = OUT / 'stopped-readback'
    module.PROOF_PATH = OUT / 'preparation.json'
    module.main()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('prepare', 'run', 'readback'))
    args = parser.parse_args()
    if args.mode == 'prepare':
        prepare()
    elif args.mode == 'run':
        raise SystemExit(asyncio.run(run()))
    else:
        readback()
