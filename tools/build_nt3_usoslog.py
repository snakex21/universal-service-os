"""Build the own GUI logger for NT3, using an existing pinned Watcom runtime."""
from pathlib import Path
import argparse
import hashlib
import json
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import build_win9x_support as build
import build_win3_usb_keyboard as compiler


def main(args):
    out=args.out.resolve()
    if not out.is_relative_to(ROOT):raise ValueError('Keep this build inside its own worktree')
    if args.watcom_root:
        tool=args.watcom_root.resolve()
        if tool.name!='ow-'+compiler.OW_SNAPSHOT['sha256'][:12]:
            raise ValueError('The existing compiler must be the pinned snapshot')
        for name in ('binnt64/wcc386.exe','binnt64/wlink.exe','lib386/nt/kernel32.lib'):
            if not (tool/name).is_file():raise ValueError('Existing compiler is incomplete')
        compiler.openwatcom=lambda:tool
    out.mkdir(parents=True,exist_ok=False)
    work=out/'work';work.mkdir()
    exe=build.build_usoslog(out,work,nt3=True)
    metadata=dict(exe=str(exe),sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
        pe_os_subsystem='3.10',scope='Build only; no NT3 runtime or network PASS')
    (out/'build.json').write_text(json.dumps(metadata,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(metadata),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'zig-out/nt3-usoslog')
    parser.add_argument('--watcom-root',type=Path)
    main(parser.parse_args())
