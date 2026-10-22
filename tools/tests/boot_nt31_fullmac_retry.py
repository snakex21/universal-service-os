"""Fixed R24b adapter: same single-guard runner, new retained own overlay."""
from pathlib import Path
import asyncio,importlib.util,json
ROOT=Path(__file__).resolve().parents[2]
TAG='r24b-nt31-image-entry'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
async def main():
    previous=ROOT/'artifacts/nt31-fullmac-runtime/vm/r24-nt31-intel-fullmac'
    if json.loads((previous/'completed.json').read_text(encoding='utf-8')).get('stopped') is not True:raise ValueError('R24 writer must be stopped')
    if json.loads((previous/'result.json').read_text(encoding='utf-8')).get('qemu_returncode')!=0:raise ValueError('R24 exit must be confirmed')
    boot=load('nt31_retry_runner',Path(__file__).with_name('boot_nt31_fullmac.py'))
    boot.TAG=TAG;boot.WORK=Path(r'G:\USOS-Kolekcja\_vm')/TAG
    boot.OUT=ROOT/'artifacts/nt31-fullmac-runtime/vm'/TAG
    boot.PREP=ROOT/'artifacts/nt31-fullmac-runtime/r24b-preparation.json'
    return await boot.main()
if __name__=='__main__':raise SystemExit(asyncio.run(main()))
