"""Fetch one Apple recovery with the pinned local OpenCore recovery tool.

All new data is kept in the explicitly authorized collection directory.
The tool checks the chunklist signature and each image chunk. A recovery is
an online-install environment, not the full offline installer or an ISO.
"""
from pathlib import Path
from types import SimpleNamespace
import contextlib
import datetime
import hashlib
import importlib.util
import json
import shutil

TOOL = Path(r'C:\Users\ASRock\usos-work\macos-dlc-local\recovery-tool\macrecovery.py')
EXPECTED = '3023a9b4ca79a5255d93c00f25ab5df37e6f938b729b797d9ecea56184b17aff'
ROOT = Path(r'G:\USOS-Kolekcja\macOS\Recovery-Sonoma')


def main():
    if hashlib.sha256(TOOL.read_bytes()).hexdigest() != EXPECTED:
        raise SystemExit('Recovery tool checksum differs from the pinned version')
    if shutil.disk_usage(ROOT.anchor).free < 100*1024**3:
        raise SystemExit('Less than 100 GiB free')
    ROOT.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('coverage_recovery_tool', TOOL)
    recovery = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recovery)
    original = recovery.get_image_info
    source = {}

    def information(*args, **kwargs):
        result = original(*args, **kwargs)
        for name in ('INFO_PRODUCT', 'INFO_IMAGE_LINK', 'INFO_SIGN_LINK'):
            key = getattr(recovery, name)
            source[name] = result[key]
        return result

    recovery.get_image_info = information
    args = SimpleNamespace(board_id='Mac-827FAC58A8FDFA22',
        mlb='00000000000000000', os_type='default', diagnostics=False,
        basename='BaseSystem', outdir=str(ROOT), verbose=False)
    error = None
    with (ROOT/'download.log').open('w', encoding='utf-8') as log, contextlib.redirect_stdout(log):
        try:
            code = recovery.action_download(args)
        except Exception as exception:
            code, error = 1, f'{type(exception).__name__}: {exception}'
    files = []
    for name in ('BaseSystem.dmg', 'BaseSystem.chunklist'):
        path = ROOT/name
        if not path.exists():
            continue
        if code:
            path.unlink()  # Only files in this newly created directory.
            continue
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        files.append(dict(name=name, bytes=path.stat().st_size, sha256=digest))
    result = dict(kind='online-recovery', requested_family='Sonoma',
        version_status='inspect downloaded SystemVersion.plist before claiming exact version',
        verified=code == 0, verification='OpenCore chunklist RSA signature and per-chunk SHA-256',
        board_id=args.board_id, tool_sha256=EXPECTED, source=source, files=files,
        date=datetime.datetime.now(datetime.timezone.utc).isoformat(), error=error)
    (ROOT/'manifest.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({'recovery_verified':result['verified'], 'files':len(files), 'error':error}), flush=True)
    raise SystemExit(code)


if __name__ == '__main__':
    main()
