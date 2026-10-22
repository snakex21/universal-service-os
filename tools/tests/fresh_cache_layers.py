"""Append exactly three own replacements to frozen net2 for fresh NT351 R21.

No VM is launched; no existing cache or old runtime result is modified.
"""
from pathlib import Path
import gzip,hashlib,importlib.util,json,shutil,stat,subprocess,sys

ROOT=Path(__file__).resolve().parents[2]
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
BASE=COLLECTION/'_assets/B261020-200536-968CCBE8-nt351-net2'
OUT=COLLECTION/'_assets/B261020-200536-968CCBE8-nt351-net3'
BASE_INITRD='ea7c1f59537bc0c8ba7eb518bde5cbd41d327067529e417a6d4401d9efd13aca'
DRIVER='f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a'
POST='d2c1115180d8daeb02421d23920584a95dd8aa082a42c566dec1e9ff836e1096'
POST_SOURCE='e8e825c48f1392a08e55d498b76c8f3c9b1e36f490b2943d85c45cd8f6f5b678'
LOGGER='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7'
EFI='3dd8b4d2b8e42fd22859c82383aa3ecfaa5c5a91779591b89c4b32e7ea3ae90f'
ARTIFACT=ROOT/'artifacts/nt351-network/r21-cache-manifest.json'

def sha(data):return hashlib.sha256(data).hexdigest()

def cpio_module():
    spec=importlib.util.spec_from_file_location('nt351_r21_cpio',ROOT/'tools/build_micro_linux.py')
    module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module);return module

def effective_newc(data):
    """Read every explicit newc layer, preserving kernel override order."""
    if len(data)>1024**3:raise ValueError('Decompressed cache exceeds bound')
    cpio=cpio_module();offset=0;entries={};layers=0;members=0
    while offset<len(data):
        while offset<len(data) and data[offset]==0:offset+=1
        if offset==len(data):break
        start=offset;trailer=False
        while offset<len(data):
            if offset+110>len(data) or data[offset:offset+6]!=b'070701':raise ValueError('Unsupported bounded newc header')
            fields=[int(data[offset+6+i:offset+14+i],16) for i in range(0,104,8)]
            size,namesize=fields[6],fields[11]
            if not 1<=namesize<=4096:raise ValueError('Invalid cpio name bound')
            name_start=offset+110;name_end=name_start+namesize
            if name_end>len(data) or data[name_end-1]!=0:raise ValueError('Invalid cpio name')
            name=data[name_start:name_end-1].decode('utf-8');payload=(name_end+3)&~3
            if payload+size>len(data):raise ValueError('Truncated cpio payload')
            offset=(payload+size+3)&~3;members+=1
            if members>100000:raise ValueError('Cpio member bound exceeded')
            if name=='TRAILER!!!':
                if size:raise ValueError('Invalid cpio trailer')
                trailer=True;break
        if not trailer:raise ValueError('Explicit layer trailer required')
        layers+=1
        if layers>16:raise ValueError('Cpio layer bound exceeded')
        entries.update(cpio.parse_newc(data[start:offset]))
    if not layers:raise ValueError('No cache layers')
    return entries,layers
