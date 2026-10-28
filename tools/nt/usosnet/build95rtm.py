"""Build only the Windows 95 RTM / OSR1 usosnet (NDIS 3.0, USOSNET_W95RTM=1).

Same WDK 7.1 toolchain and flow as build351.py. Writes usosnet4.sys and
build.json to --out; copy them to bin/i386/win95-rtm/ (usosnet4.sys,
BUILD.json) by hand. All scratch stays in this checkout.

Requires an existing WDK7.1. Never removes a directory or overwrites a build.
The installed-Windows runtime is a separate test, not implied by this build.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wdk', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    if not out.is_relative_to(ROOT / 'artifacts') or out.exists():
        raise ValueError('Use a fresh output directory inside this checkout artifacts')
    wdk = args.wdk.resolve()
    if not (wdk / 'bin/setenv.bat').is_file():
        raise ValueError('Existing WDK7.1 required')
    # This legacy setenv.bat quotes %1 internally and rejects a quoted root.
    if not re.fullmatch(r'[A-Za-z0-9_:\\./-]+', str(wdk)):
        raise ValueError('Legacy WDK root must contain no spaces or shell metacharacters')
    out.mkdir(parents=True)
    tmp = out / 'tmp'
    tmp.mkdir()
    src = out / 'src'
    shutil.copytree(HERE / 'src', src)
    shutil.copy(HERE / 'src95rtm/sources', src / 'sources')
    # The PE runs on the 95 RTM NDIS.VXD; WDK headers are only compile-time definitions.
    script = out / 'build.cmd'
    script.write_text('@echo off\n'
        f'call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr\n'
        'if errorlevel 1 exit /b 2\n'
        f'cd /d "{src}"\n'
        'set "BUILD_ALT_DIR=fre"\n'
        'build -cZ\n'
        'if not exist objfre\\i386\\usosnet95r.sys exit /b 3\n', encoding='utf-8')
    env = dict(os.environ, TEMP=str(tmp), TMP=str(tmp), PYTHONDONTWRITEBYTECODE='1')
    completed = subprocess.run(['cmd', '/d', '/c', str(script)], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    (out / 'build-output.txt').write_text(completed.stdout.decode('mbcs', errors='replace'), encoding='utf-8')
    if completed.returncode:
        raise RuntimeError(f'Build failed; see {out / "build-output.txt"}')
    binary = out / 'usosnet4.sys'
    shutil.copy(src / 'objfre/i386/usosnet95r.sys', binary)
    subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'tools/nt4/pe_nt4_version.py'),
        '--version', '4.00', str(binary)], env=env, check=True, capture_output=True)
    manifest = {
        'scope': 'Windows 95 RTM / OSR1 (SETUP 4.0.0.950) only; this build has no runtime PASS',
        'binary': 'usosnet4.sys', 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'size': binary.stat().st_size, 'ndis_version': '3.0', 'characteristics_size': 60,
        'ethdb_offset': 216, 'driver_owned_timer': True,
        'timer': 'NdisMInitializeTimer + one-shot NdisSetTimer re-armed after each 20 ms callback; cancelled in Halt',
        'set_attributes': 'NdisMSetAttributes (four-argument NDIS 3.0 export)',
        'toolchain': 'WDK 7.1 build, fre x86 WXP, tools/nt/usosnet/src95rtm/sources',
        'runtime_pass': False,
        'source_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((HERE / 'src').glob('*')) if p.is_file()},
    }
    (out / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
