"""Explicit helper-only variant of the pinned installed-NT35 harness."""
from pathlib import Path
import asyncio
import hashlib
import importlib.util
import json
import sys

ROOT=Path(__file__).resolve().parents[3]
PRIOR=ROOT.parent/'nt35-irq'
TAG='nt35-client-apply02'
BASE=Path(r'G:\USOS-Kolekcja\_vm\nt35-irq-usb01')
WORK=Path(r'G:\USOS-Kolekcja\_vm')/TAG
PROOF=ROOT/'artifacts/nt35-client/apply02/preparation.json'

def module():
    path=Path(__file__).with_name('boot_nt35_irq_fixed.py')
    source=path.read_text('utf-8')
    old="""    if proof.get('only_owned_sys_ranges_changed') is not True and proof.get('guest_contents_unchanged') is not True:
        raise ValueError('Only an owned-SYS change or unchanged guest is allowed')"""
    new="""    if proof.get('new_client_files') != ['USOS/NT3/CLNT35.EXE', 'USOS/NT3/CLNT35.ON']:
        raise ValueError('Exactly the two declared own client files required')
    if proof.get('original_files_unchanged') is not True or proof.get('actual_helper_imports_compatible') is not True:
        raise ValueError('Every original file unchanged and actual NT35 imports required')
    if proof.get('helper_sha256') != '4a927eecb1a6c602f92c0a92c14bd7b56f684238735d36f8218d5bfcb5e3204a':
        raise ValueError('Pinned helper required')"""
    if source.count(old)!=1:raise ValueError('Pinned helper guard transform mismatch')
    source=source.replace(old,new)
    old="""            async def consume():
                while data := await process.stdout.read(65536):
                    serial.write(data)
                    serial.flush()"""
    new="""            async def consume():
                tail=b''; completions=0
                while data := await process.stdout.read(65536):
                    serial.write(data)
                    serial.flush()
                    tail=(tail+data)[-131072:]
                    while b'USOS_CLIENT35_DONE=' in tail:
                        at=tail.index(b'USOS_CLIENT35_DONE=')
                        end=tail.find(b'\\n',at)
                        if end<0:break
                        token=tail[at:end].rstrip(b'\\r')
                        if token not in (b'USOS_CLIENT35_DONE=0',b'USOS_CLIENT35_DONE=3'):
                            raise ValueError('Malformed own policy completion')
                        completions+=1
                        final=OUT/('policy-done-%02d.json'%completions)
                        temp=final.with_suffix('.tmp')
                        temp.write_text(json.dumps(dict(completed=True,exit_code=int(token[-1:]),source='own GUI helper COM1 completion')),encoding='utf-8')
                        temp.replace(final)
                        tail=tail[end+1:]"""
    if source.count(old)!=1:raise ValueError('Pinned completion transform mismatch')
    source=source.replace(old,new)
    archive=PROOF.parent/'runtime-core.py'
    if archive.exists():raise ValueError('Fresh runtime archive required')
    archive.write_text(source,encoding='utf-8',newline='\n')
    spec=importlib.util.spec_from_loader('nt35_client_core',loader=None)
    core=importlib.util.module_from_spec(spec);core.__file__=str(path)
    exec(compile(source,str(archive),'exec'),core.__dict__)
    core.TAG=TAG;core.WORK=WORK;core.BASE=BASE
    core.SOURCE=PRIOR/'artifacts/coverage/vm/nt35-irq-usb01'
    core.OUT=ROOT/'artifacts/coverage/vm'/TAG
    core.SOURCE_COMMAND_SHA256=json.loads(PROOF.read_text())['source_command_sha256']
    core.PROOF_PATH=PROOF
    core.EXTRA_SOURCE_PATHS=(Path(__file__),archive,ROOT/'artifacts/nt35-client/build02/CLNT35.EXE')
    core.SCOPE='NT35 client service policy only; added own helper/marker, unchanged original files and SYS'
    return core

if __name__=='__main__':
    if not sys.stdin.isatty():
        raise SystemExit('Live operator PTY required before any VM start')
    raise SystemExit(asyncio.run(module().main()))
