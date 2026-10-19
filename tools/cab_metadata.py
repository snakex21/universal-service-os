"""Read complete, bounded setup metadata CAB members through 7-Zip.

A missing adjacent cabinet may make 7-Zip return a warning. Only a requested
member whose bytes match its CAB-declared size is accepted; this does not
validate the entire cabinet set. No member is retained on disk.
"""
import pathlib
import struct
import subprocess
import tempfile
import warnings


def files(data, wanted, seven, cache):
    if not 36 <= len(data) <= 8 * 1024 * 1024 or data[:4] != b'MSCF':
        raise ValueError('Expected a small CAB')
    if not set(wanted) <= {'setuppp.inf', 'setupx.dll', 'suwin.exe', 'layout.inf'}:
        raise ValueError('Only setup metadata members are permitted')
    offset = struct.unpack_from('<I', data, 16)[0]
    count = struct.unpack_from('<H', data, 28)[0]
    declared = {}
    for _ in range(count):
        if offset + 16 > len(data):
            raise ValueError('Truncated CAB member table')
        size = struct.unpack_from('<I', data, offset)[0]
        end = data.find(b'\0', offset + 16)
        if end < 0:
            raise ValueError('Truncated CAB member name')
        name = data[offset + 16:end].decode('cp1252').lower()
        if name in declared:
            raise ValueError('Duplicate CAB member')
        declared[name] = size
        offset = end + 1
    cache = pathlib.Path(cache).resolve()
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cab-metadata-', dir=cache) as directory:
        directory = pathlib.Path(directory).resolve()
        if not directory.is_relative_to(cache):
            raise ValueError('Scratch directory escaped its cache')
        source = directory / 'metadata.cab'
        source.write_bytes(data)
        result = {}
        for name in sorted(set(wanted) & declared.keys()):
            if declared[name] > 2 * 1024 * 1024:
                raise ValueError('Setup metadata member exceeded its bound')
            p = subprocess.run([str(seven), 'x', '-so', str(source), name], capture_output=True, timeout=30)
            if len(p.stdout) != declared[name]:
                raise ValueError('Incomplete CAB metadata member: ' + name)
            if p.returncode:
                warnings.warn('7-Zip reported a cabinet-set warning; only the complete member size was checked: ' + name)
            result[name] = p.stdout
        return result
