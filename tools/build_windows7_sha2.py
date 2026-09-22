"""Read the pinned, locally supplied Microsoft SHA-2 package; never download it."""
from pathlib import Path
import hashlib
import os
import subprocess

MSU_NAME = 'windows6.1-kb4474419-v3-x64_b5614c6cea5cb4e198717789633dca16308ef79c.msu'
MSU_SHA256 = '99312df792b376f02e25607d2eb3355725c47d124d8da253193195515fe90213'
CAB_NAME = 'Windows6.1-KB4474419-v3-x64.cab'
CAB_SHA256 = '806c8e31d55fa5861b772a42bec7a1880513b5239b516f9914422e3fd512e78f'

def read_cab(root: Path) -> bytes:
    source = root / 'media/Systems/Windows/Windows 7/Updates' / MSU_NAME
    if hashlib.sha256(source.read_bytes()).hexdigest() != MSU_SHA256:
        raise ValueError('SHA-2 MSU checksum mismatch')
    output = root / 'zig-out/windows7-sha2'
    output.mkdir(parents=True, exist_ok=True)
    cab = output / CAB_NAME
    if not cab.exists():
        env = dict(os.environ, TEMP=str(output), TMP=str(output))
        subprocess.run(['expand.exe', '-F:' + CAB_NAME, str(source), str(output)],
                       env=env, check=True, stdout=subprocess.DEVNULL)
    content = cab.read_bytes()
    if hashlib.sha256(content).hexdigest() != CAB_SHA256:
        raise ValueError('SHA-2 CAB checksum mismatch')
    return content
