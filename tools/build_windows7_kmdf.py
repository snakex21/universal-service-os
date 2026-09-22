"""Package the pinned Microsoft KMDF dependency for the Win7 USB stack."""
from pathlib import Path
import hashlib
import os
import subprocess

MSU_NAME = 'windows6.1-kb2685811-x64_191e09df632b70fd4f4b27d4cb9227f7c5a1c98c.msu'
MSU_SHA256 = 'c1aa0a453e4a886d7670da2209872737323baa9e36145ea838c9f8ffd7e7d7e7'
CAB_NAME = 'Windows6.1-KB2685811-x64.cab'
CAB_SHA256 = '605d9434709367ea390c0051f97b77cb1a9a55b27eb46e57cc44bd9791c703bc'

def read_cab(root: Path) -> bytes:
    source = root / 'tools/vendor/windows7-kmdf' / MSU_NAME
    if hashlib.sha256(source.read_bytes()).hexdigest() != MSU_SHA256:
        raise ValueError('KMDF MSU checksum mismatch')
    output = root / 'zig-out/windows7-kmdf'
    output.mkdir(parents=True, exist_ok=True)
    cab = output / CAB_NAME
    if not cab.exists():
        env = dict(os.environ, TEMP=str(output), TMP=str(output))
        subprocess.run(['expand.exe', '-F:' + CAB_NAME, str(source), str(output)],
                       env=env, check=True, stdout=subprocess.DEVNULL)
    content = cab.read_bytes()
    if hashlib.sha256(content).hexdigest() != CAB_SHA256:
        raise ValueError('KMDF CAB checksum mismatch')
    return content
