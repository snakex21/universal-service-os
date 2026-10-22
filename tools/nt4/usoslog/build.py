"""Isolated own NT4 logger build. No downloads or NT3/9x payload changes."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--watcom',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--measure',action='store_true',help='Measure a deliberately updated own source before pinning its reproducible hash')
    args=parser.parse_args()
    out=args.out.resolve();ow=args.watcom.resolve()
    if not out.is_relative_to(ROOT/'artifacts') or out.exists():raise ValueError('Use fresh owned artifacts output')
    if ow.name!='ow-bac354f3c75f':raise ValueError('Use the already installed pinned compiler')
    for file in ('binnt64/wcc386.exe','binnt64/wlink.exe','lib386/nt/kernel32.lib'):
        if not (ow/file).is_file():raise ValueError('Incomplete existing compiler')
    metadata=json.loads((HERE/'source.json').read_text(encoding='utf-8'))
    for name,sha in metadata['files'].items():
        if hashlib.sha256((HERE/'src'/name).read_bytes()).hexdigest()!=sha:raise ValueError('Source snapshot hash differs')
    out.mkdir(parents=True);tmp=out/'tmp';tmp.mkdir()
    env=dict(os.environ,WATCOM=str(ow),INCLUDE=f'{ow / "h/nt"};{ow / "h"}',
        PATH=str(ow/'binnt64')+os.pathsep+os.environ.get('PATH',''),TEMP=str(tmp),TMP=str(tmp))
    obj=out/'usoslog.obj';exe=out/'USOSLOG.EXE'
    subprocess.run([str(ow/'binnt64/wcc386.exe'),'-q','-bt=nt','-zl','-s','-5r','-os','-zp4',
        '-w3','-we','-dUSOS_NT3_RAW_ICMP=1','-fo='+str(obj),str(HERE/'src/usoslog.c')],env=env,cwd=out,check=True)
    subprocess.run([str(ow/'binnt64/wlink.exe'),'@'+str(HERE/'src/usoslog.lnk'),'file',str(obj),
        'name',str(exe),'option','map='+str(out/'usoslog.map')],env=env,cwd=out,check=True)
    spec=importlib.util.spec_from_file_location('pe310',ROOT/'tools/nt4/pe_nt4_version.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    raw=bytearray(exe.read_bytes());pe=int.from_bytes(raw[0x3c:0x40],'little');raw[pe+8:pe+12]=b'\0'*4
    exe.write_bytes(module.set_nt4(bytes(raw),3,10))
    digest=hashlib.sha256(exe.read_bytes()).hexdigest()
    if not args.measure and digest!=metadata['binary_sha256']:
        raise ValueError('Rebuilt logger differs from the approved exact source/binary pair')
    (out/'build.json').write_text(json.dumps({'sha256':digest,'source_commit':metadata['source_commit'],
        'reproducible_pin_verified':not args.measure,
        'scope':'Reproducible isolated host build; no NT4 runtime PASS'},indent=2)+'\n',encoding='utf-8')
    print(str(exe))


if __name__=='__main__':main()
