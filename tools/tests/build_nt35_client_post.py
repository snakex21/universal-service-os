"""Canonical own POST-only build, portable caches; never run resulting EXE."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--attempt', choices=('02', '03'), default='02')
    args = parser.parse_args()
    out = ROOT/('artifacts/nt35-client-auto/build'+args.attempt)
    if out.exists(): raise FileExistsError('Fresh owned build directory required')
    sys.path.insert(0, str(ROOT/'tools'))
    from build_windows_usos_res import build_nt3
    sys.path.insert(0, str(ROOT/'tools/tests'))
    from check_nt52_driver_imports import pe
    exe = build_nt3(ROOT, out)
    record = dict(binary=str(exe), bytes=exe.stat().st_size,
                  sha256=hashlib.sha256(exe.read_bytes()).hexdigest(), imports=pe(exe)[1],
                  source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                  source_sha256=hashlib.sha256((ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_bytes()).hexdigest(),
                  header_sha256=hashlib.sha256((ROOT/'tools/nt3/usosnt3/src/client35_prepare.h').read_bytes()).hexdigest(),
                  canonical_builder='tools/build_windows_usos_res.py:build_nt3',
                  runtime_pass=False, host_execution=False)
    (out/'build.json').write_bytes((json.dumps(record,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(record,indent=2))


if __name__ == '__main__': main()
