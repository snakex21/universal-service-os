"""Check own rebuilt POST against original DLL exports in stopped NT35.

Microsoft bytes stay in RAM / a fresh approved whole scratch disk on G.
Never export DLLs, hives, keys or values. The pinned baseline is read-only.
"""
from pathlib import Path
import hashlib
import argparse
import importlib.util
import json
import os
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT.parent/'nt35-fresh'
TARGET = Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-fresh01\target-retained.qcow2')
PIN = '3b76f15ac5eeb410ee3ca21711ef4a8f34729e3a9082427b3e849fb9586e4c6b'
HERE = ROOT/'artifacts/nt35-client-auto'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class MemoryFile:
    def __init__(self, data, name): self.data, self.name = data, name
    def read_bytes(self): return self.data
    def __repr__(self): return self.name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--attempt', choices=('02', '03'), default='02')
    args = parser.parse_args()
    WORK = Path(r'G:\USOS-Kolekcja\_audit')/('nt35-client-auto-post'+args.attempt)
    output = HERE/('post-original-preflight'+args.attempt+'.json')
    if output.exists() or WORK.exists(): raise FileExistsError('Fresh proof/scratch required')
    closed = json.loads((OLD/'artifacts/coverage/vm/nt35-irq-fresh01/result.json').read_text(encoding='utf-8'))
    parent = json.loads((OLD/'artifacts/coverage/nt35-irq-fresh01/process-exit.json').read_text(encoding='utf-8'))
    if closed['qemu_returncode'] != 0 or parent['returncode'] != 0:
        raise ValueError('Completed baseline required')
    for p in (TARGET, TARGET.parent, WORK, WORK.parent):
        if p.resolve() != p or (p.exists() and p.lstat().st_file_attributes & 0x400):
            raise ValueError('Literal non-reparse paths required')
    if sha(TARGET) != PIN: raise ValueError('Stopped NT35 baseline pin mismatch')
    build = json.loads((HERE/('build'+args.attempt)/'build.json').read_text(encoding='utf-8'))
    own = Path(build['binary'])
    if sha(own) != build['sha256']: raise ValueError('Own binary changed')
    sys.path.insert(0, str(ROOT/'tools/tests'))
    from check_nt52_driver_imports import pe
    imports = pe(own)[1]
    header = own.read_bytes()
    opt = struct.unpack_from('<I', header, 60)[0] + 24
    if struct.unpack_from('<HH', header, opt+48) != (3, 10):
        raise ValueError('Own PE subsystem must be3.10')
    h = load('nt35_client_bounded_fat', ROOT/'tools/tests/coverage/prepare_nt351_debug.py')
    WORK.mkdir()
    raw = WORK/'stopped-whole-disk.raw'
    env = dict(os.environ, TEMP=str(WORK), TMP=str(WORK), APPDATA=str(WORK), LOCALAPPDATA=str(WORK))
    modules, tables = {}, {}
    try:
        subprocess.run([str(h.QIMG), 'convert', '-f', 'qcow2', '-O', 'raw', str(TARGET), str(raw)],
                       env=env, check=True)
        fs = h.BoundedFat(raw)
        try:
            if fs.fat32 or fs.base != 32256: raise ValueError('Pinned FAT16 layout required')
            for name in ('kernel32.dll', 'advapi32.dll'):
                data, _ = h.file_data(fs, 'WINNT/SYSTEM32/'+name, 4*1024**2)
                exports = pe(MemoryFile(data, name))[0]
                tables[name] = exports
                modules[name] = dict(sha256=hashlib.sha256(data).hexdigest(),
                                     bytes=len(data), exports=len(exports))
        finally:
            fs.f.close()
        missing = [(m, n) for m, n in imports if m not in tables or n not in tables[m]]
        if missing: raise ValueError('Actual original imports missing: '+repr(missing))
        if sha(TARGET) != PIN: raise ValueError('Stopped baseline changed')
        result = dict(binary_sha256=build['sha256'], binary_bytes=own.stat().st_size,
                      subsystem=[3,10], imports=len(imports), missing=missing, modules=modules,
                      target=str(TARGET), target_sha256=PIN, target_unchanged=True,
                      ms_modules_ram_only=True, standalone_ms_exports=False, runtime_pass=False)
    finally:
        if raw.exists():
            if raw.resolve().parent != WORK or raw.name != 'stopped-whole-disk.raw':
                raise ValueError('Invalid exact scratch cleanup')
            raw.unlink()
    result['scratch_whole_disk_removed'] = True
    output.write_bytes((json.dumps(result, indent=2)+'\n').encode('utf-8'))
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
