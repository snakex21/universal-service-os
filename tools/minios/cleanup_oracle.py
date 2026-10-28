"""Delete only completed MiniOS oracle disk copies, preserving all evidence.

Only target.raw under inputs/<case> and the two named VHD copies are eligible.
The whole plan is checked, detached and exclusively opened before any unlink.
"""
from __future__ import annotations
import contextlib
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import stat
import subprocess

spec = importlib.util.spec_from_file_location("prep_verify", Path(__file__).with_name("verify_case.py"))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

def cleanup(only_case=None, receipt_tag=None):
    root = v.oracle_path(v.ORACLE / "inputs").parent
    if only_case is not None:
        import re
        if not re.fullmatch(r'[a-z0-9-]+',only_case): raise ValueError('Invalid case selection')
    suffix = ('-'+only_case) if only_case else ''
    if receipt_tag:
        import re
        if not re.fullmatch(r'[a-z0-9-]+',receipt_tag): raise ValueError('Invalid receipt tag')
        suffix += '-'+receipt_tag
    plan_path = root / ('cleanup-plan'+suffix+'.json')
    if plan_path.exists(): raise ValueError("Cleanup plan already exists")
    candidates = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in (".raw", ".vhd", ".qcow2", ".img", ".fd"): continue
        path = v.oracle_path(path)
        relative = path.relative_to(root)
        if only_case and not ((relative.parts[0]=='inputs' and len(relative.parts)==3 and relative.parts[1]==only_case) or (len(relative.parts)==2 and relative.parts[0]==only_case+'-windows01')): continue
        if path.name == "target.raw" and len(relative.parts) == 3 and relative.parts[0] == "inputs":
            pass
        elif path.name in ("readonly-copy.vhd", "converted-fixed.vhd") and len(relative.parts) == 2:
            result = json.loads((path.parent / "result.json").read_text(encoding="utf-8-sig"))
            if result.get("dismounted") is not True:
                raise ValueError("A VHD lacks successful dismount evidence: " + str(path))
            if result.get("temporary_dos_alias") and result.get("temporary_dos_alias_removed") is not True:
                raise ValueError("A VHD lacks exact alias cleanup evidence")
        elif path.name in ('base.raw','reference.qcow2') and len(relative.parts)==2 and relative.parts[0].startswith('control-'):
            result=json.loads((path.parent/'result.json').read_text(encoding='utf-8-sig'))
            if result.get('qemu_only') is not True or result.get('qemu_exit')!=0:
                raise ValueError('Reference generator lacks actual completion evidence')
        else:
            raise ValueError("Unrecognized image must be reviewed explicitly: " + str(path))
        candidates.append(path)
    files = []
    with contextlib.ExitStack() as locks:
        for path in sorted(candidates):
            stream = locks.enter_context(v.api.exclusive_read(path))
            import hashlib
            digest = hashlib.sha256(); size = 0
            while data := stream.read(1024 * 1024): digest.update(data); size += len(data)
            files.append({"path": str(path.relative_to(root)), "bytes": size, "sha256": digest.hexdigest()})
        v.write_json(plan_path, {"files": files, "total_bytes": sum(item["bytes"] for item in files), "state": "validated-plan"})
    # Get-DiskImage only inspects our exact VHD copies. It never mounts anything.
    shell = shutil.which("pwsh.exe")
    if not shell: raise ValueError("PowerShell 7 required to verify detached VHDs")
    check = "param([string]$Plan,[string]$Root) $ErrorActionPreference='Stop'; foreach($item in (Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json).files) { if([IO.Path]::GetExtension($item.path) -eq '.vhd') { $path=Join-Path $Root $item.path; $image=Get-DiskImage -ImagePath $path -ErrorAction Stop; if($image.Attached) { throw ('VHD still attached: '+$path) } } }"
    check_path = root / ("cleanup-detached-check"+suffix+".ps1")
    with check_path.open("x", encoding="utf-8") as f: f.write(check)
    subprocess.run([shell, "-NoLogo", "-NoProfile", "-File", str(check_path), str(plan_path), str(root)], check=True, capture_output=True, timeout=120)
    removed = []
    try:
        for item in files:
            path = v.oracle_path(root / item["path"])
            with v.api.exclusive_read(path): pass
            path.chmod(stat.S_IREAD | stat.S_IWRITE)
            path.unlink(); removed.append(item["path"])
    except BaseException as error:
        v.write_json(root / ("cleanup-failed"+suffix+".json"), {"removed": removed, "error": repr(error)})
        raise
    result = {"state": "complete", "removed": removed, "removed_bytes": sum(item["bytes"] for item in files), "images_count": len(files)}
    v.write_json(root / ("cleanup-completed"+suffix+".json"), result)
    return result

if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--workspace",type=Path,required=True)
    parser.add_argument("--only-case")
    parser.add_argument("--receipt-tag")
    args=parser.parse_args()
    v.ORACLE=args.workspace.resolve()
    print(json.dumps(cleanup(args.only_case,args.receipt_tag)))
