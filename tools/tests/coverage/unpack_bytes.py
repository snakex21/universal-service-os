"""Seekable CAB/SZDD input without storing Microsoft files in the repo.

The Windows 7-Zip build does not implement CAB input on stdin. Its short-
lived input is kept in owned collection scratch; output stays in memory.
"""
from pathlib import Path
import subprocess
import tempfile

SCRATCH = Path(r'G:\USOS-Kolekcja\_cab')
SEVEN = Path(r'C:\Program Files\7-Zip\7z.exe')


def unpack(blob, member=None, *, scratch=SCRATCH):
    if not blob.startswith((b'MSCF',b'SZDD')):
        return blob
    if len(blob) > 128*1024**2:
        raise ValueError('CAB input exceeds audit bound')
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='input-',dir=scratch) as folder:
        source = Path(folder)/('input.cab' if blob[:4] == b'MSCF' else 'input.szdd')
        source.write_bytes(blob)
        command = [str(SEVEN),'x','-so',str(source)]
        if member is not None:
            command.append(member)
        result = subprocess.run(command,capture_output=True,timeout=120)
        if result.returncode:
            raise ValueError('CAB/SZDD extraction failed: '+result.stderr.decode(errors='replace')[:160])
        return result.stdout
