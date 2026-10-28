"""Remove only four completed pre-1b2 cases, after archiving their final report."""
from __future__ import annotations
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

def load(name, filename):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

old=load("preflight_atomic_cleanup","cleanup_scale.py")
evidence=load("preflight_cleanup_evidence","preflight_evidence.py")
runtime=old.runtime


def report_ready(root: Path):
    path=root/"validation/final-report-pre-cleanup.md"
    text=runtime.guarded(root,path).read_text(encoding="utf-8-sig")
    if "preflight przed 1b-2" not in text[:256] or "Status: RAPORT KOŃCOWY" not in text[:1024]:
        raise ValueError("A final preflight report, not a draft, must precede deletion")
    return runtime.artifact(root,path)


def candidates(root: Path, accepted_cases: list[dict]):
    selected=[]
    windows_dirs={row["name"]:(root/row["windows_receipt"]["path"]).parent for row in accepted_cases}
    for name,(_,memory,*_) in evidence.CASES.items():
        case=root/"cases"/name;run=case/f"run-{memory}m"
        selected += [case/n for n in ("esp-base.raw","target-base.raw")]
        selected += [run/n for n in ("esp.qcow2","target.qcow2","esp-closed.raw","entropy.bin")]
        if name.startswith("uefi-"):selected.append(run/"vars.fd")
        selected.append(root/"oracle/inputs"/name/"target.raw")
        selected += [windows_dirs[name]/n for n in ("converted-fixed.vhd","readonly-copy.vhd")]
    case=root/"cases/entropy-refusal-01";run=case/"run-2m"
    selected += [case/n for n in ("esp-base.raw","target-base.raw")]
    selected += [run/n for n in ("esp.qcow2","target.qcow2","esp-closed.raw","negative-target.raw")]
    for path in selected:
        runtime.guarded(root,path)
        if not path.is_file() or path.stat().st_nlink!=1:raise ValueError("Missing or hard-linked owned image")
    if len(set(selected))!=len(selected):raise ValueError("Overlapping image selections")
    return selected


def cleanup(root: Path):
    report=report_ready(root)
    accepted=evidence.collect(root)
    if accepted["cleanup"] is not None:raise ValueError("Cleanup has already completed")
    selected=candidates(root,accepted["cases"])
    for name in ("cleanup-preflight-plan.json","cleanup-preflight-completed.json"):
        if (root/name).exists():raise ValueError("Never overwrite a cleanup receipt")
    script=root/"cleanup-preflight-detached.ps1"
    with runtime.guarded(root,script).open("x",encoding="utf-8") as out:
        out.write("param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Images) $ErrorActionPreference='Stop'; foreach($path in $Images) { $image=Get-DiskImage -ImagePath $path -ErrorAction Stop; if($image.Attached) { throw ('Owned VHD is attached: '+$path) } }; 'ALL_SELECTED_VHDS_DETACHED'")
    shell=shutil.which("pwsh.exe")
    if not shell:raise ValueError("PowerShell7 is required for VHD detach checks")
    app_data=root/"cleanup-preflight-host-runtime";app_data.mkdir(exist_ok=False)
    env=dict(os.environ)
    for key in ("APPDATA","LOCALAPPDATA","TEMP","TMP"):env[key]=str(app_data)
    checked=subprocess.run([shell,"-NoLogo","-NoProfile","-NonInteractive","-File",str(script),
        *[str(p) for p in selected if p.suffix==".vhd"]],capture_output=True,text=True,
        check=True,timeout=120,env=env,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
    if "ALL_SELECTED_VHDS_DETACHED" not in checked.stdout:raise ValueError("Missing detach completion event")
    old.write_new(root,root/"cleanup-preflight-detached.json",{"returncode":checked.returncode,"all_detached":True,"stdout":checked.stdout})
    files=[];deleted=[]
    try:
        with contextlib.ExitStack() as stack:
            handles=[]
            for path in selected:
                image=stack.enter_context(old.AtomicImage(path));size,digest=image.digest()
                files.append({"path":path.relative_to(root).as_posix(),"bytes":size,"sha256":digest})
                handles.append(image)
            observed={row["path"]:row["sha256"] for row in files}
            for case in accepted["cases"]:
                name=case["name"]
                if observed[f"oracle/inputs/{name}/target.raw"]!=case["image_sha256"]:raise ValueError("Accepted image changed")
                windows=runtime.read(root,root/case["windows_receipt"]["path"])
                vhd_key=(Path(case["windows_receipt"]["path"]).parent/"readonly-copy.vhd").as_posix()
                if observed[vhd_key]!=windows["vhd_sha256_after"]:raise ValueError("Accepted VHD changed")
            negative=runtime.read(root,root/"cases/entropy-refusal-01/preflight-completed.json")
            for relative,digest in (("negative-target.raw",negative["target_sha256"]),("esp-closed.raw",negative["esp_sha256"])):
                if observed["cases/entropy-refusal-01/run-2m/"+relative]!=digest:raise ValueError("Negative control image changed")
            old.write_new(root,root/"cleanup-preflight-plan.json",{"stage":"pre1b2","state":"all-exclusively-open-and-hashed","files":files,"report_before_cleanup":report})
            for image,row in zip(handles,files):image.delete();deleted.append(row["path"])
        if any((root/name).exists() for name in deleted):raise ValueError("Image remained after exclusive handle close")
    except BaseException as error:
        old.write_new(root,root/"cleanup-preflight-failed.json",{"deleted":deleted,"error":repr(error)})
        raise
    result={"stage":"pre1b2","state":"complete","files_count":len(files),"deleted":deleted,
        "removed_bytes":sum(row["bytes"] for row in files),"deletion_by_same_exclusive_handle":True,
        "all_selected_vhds_detached":True,"logs_and_manifests_preserved":True,"report_before_cleanup":report}
    old.write_new(root,root/"cleanup-preflight-completed.json",result)
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--workspace",type=Path,required=True)
    a=p.parse_args();result=cleanup(a.workspace.resolve())
    print(json.dumps({"state":result["state"],"files_count":result["files_count"],"removed_bytes":result["removed_bytes"]}))

if __name__=="__main__":main()
