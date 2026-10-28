"""Bound and verify a private DATA/Drivers input; never install on the host."""
from pathlib import Path, PurePosixPath
import hashlib
import io
import re
import zipfile

ASSETS=Path(r'G:\USOS-Kolekcja\_assets')


def load(path,expected,*,allowed=ASSETS):
    path=path.resolve()
    if not path.is_relative_to(allowed.resolve()) or path.suffix.lower()!='.zip':
        raise ValueError('Driver ZIP must belong to the private collection assets')
    if not re.fullmatch('[a-f0-9]{64}',expected or '') or path.stat().st_size>64*1024**2:
        raise ValueError('An exact SHA-256 and bounded driver ZIP are required')
    with path.open('rb') as source:blob=source.read(64*1024**2+1)
    if len(blob)>64*1024**2:raise ValueError('Driver ZIP exceeds the read bound')
    if hashlib.sha256(blob).hexdigest()!=expected:raise ValueError('Driver ZIP hash mismatch')
    files={};identities=set();total=0
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        if len(archive.infolist())>1024:raise ValueError('Too many driver ZIP entries')
        for item in archive.infolist():
            name=item.filename
            relative=PurePosixPath(name.rstrip('/'))
            if ('\\' in name or relative.is_absolute() or len(relative.parts)<2 or relative.parts[0]!='Other'
                or any(part in ('.','..') or not re.fullmatch('[A-Za-z0-9_. -]+',part)
                       or part.endswith(('.', ' ')) for part in relative.parts)
                or any(re.fullmatch(r'(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?',part) for part in relative.parts)
                or item.flag_bits&1
                or (item.external_attr>>16)&0o170000==0o120000):
                raise ValueError('Unsafe private driver ZIP member')
            identity=relative.as_posix().casefold()
            if identity in identities:raise ValueError('Driver ZIP path collision')
            identities.add(identity)
            if item.is_dir():continue
            total+=item.file_size
            if item.file_size>32*1024**2 or total>256*1024**2:raise ValueError('Driver ZIP expands beyond bound')
            files[relative.as_posix()]=archive.read(item)
    if not any(name.lower().endswith('.inf') for name in files):raise ValueError('No INF in private driver ZIP')
    return dict(source=str(path),sha256=expected,files=files,bytes=total)


def stage(bundle,destination,owned_root):
    destination=destination.resolve()
    if not destination.is_relative_to(owned_root.resolve()) or destination.exists():
        raise ValueError('New owned fixture driver directory required')
    destination.mkdir(parents=True)
    for name,data in bundle['files'].items():
        output=destination/Path(name)
        if not output.resolve().is_relative_to(destination):raise ValueError('Driver ZIP escaped the fixture')
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_bytes(data)


def metadata(bundle):
    return dict(source=bundle['source'],sha256=bundle['sha256'],bytes=bundle['bytes'],
        files={name:hashlib.sha256(data).hexdigest() for name,data in bundle['files'].items()})
