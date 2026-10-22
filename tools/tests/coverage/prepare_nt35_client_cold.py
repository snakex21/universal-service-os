"""Prepare one byte-identical cold-check COW of completed NT35 apply03.

No VM starts, guest file changes, registry writes or new-file claims.
"""
from pathlib import Path
import importlib.util,json,os,shutil,subprocess
ROOT=Path(__file__).resolve().parents[3]
PARENT=Path(r'G:\USOS-Kolekcja\_vm\nt35-client-apply03')
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt35-client-cold01')
SOURCE=ROOT/'artifacts/coverage/vm/nt35-client-apply03'
APPLY=ROOT/'artifacts/nt35-client/apply03'
OUT=ROOT/'artifacts/nt35-client/cold01'
def main():
    spec=importlib.util.spec_from_file_location('nt35_client_readback_contract',Path(__file__).with_name('readback_nt35_client.py'))
    contract=importlib.util.module_from_spec(spec);spec.loader.exec_module(contract)
    read=contract.read;sha=contract.sha
    for p in (PARENT,PARENT/'target.qcow2',WORK,OUT):contract.exact(p)
    if WORK.exists() or OUT.exists() or WORK.parent!=contract.COLLECTION/'_vm':raise FileExistsError('Fresh exact cold fixture required')
    if read(SOURCE/'completed.json').get('stopped') is not True or read(SOURCE/'result.json').get('qemu_returncode')!=0:raise ValueError('Closed apply03 required')
    observed=read(APPLY/'readback.json');assessment=read(APPLY/'evaluation.json');proof=read(APPLY/'preparation.json')
    if assessment.get('policy_apply')!='PASS' or assessment.get('cold_boot_policy')!='NOT_TESTED':raise ValueError('Completed apply only; cold not yet qualified')
    if observed['helper_sha256']!=contract.HELPER or observed['installed_candidate_sha256']!=contract.CANDIDATE or observed['usb_sha256']!=contract.USB:
        raise ValueError('Actual apply03 candidate pins mismatch')
    source_hash=sha(PARENT/'target.qcow2');command_hash=sha(SOURCE/'command.json')
    if source_hash!=observed['target_sha256'] or command_hash!=observed['source_command_sha256'] or sha(contract.PARENT)!=contract.PARENT_SHA:
        raise ValueError('Completed source/command/original parent changed')
    meta=read(PARENT/'fixture.json')
    if meta.get('private_profile') is not False or meta.get('folder')!='Windows NT 3.5':raise ValueError('Exact keyless NT35 required')
    if proof.get('actual_helper_imports_compatible') is not True or proof.get('actual_helper_imports')!=contract.IMPORTS:raise ValueError('Pinned import proof absent')
    if shutil.disk_usage(WORK.parent).free<100*1024**3:raise ValueError('100GiB disk reserve required')
    helper=contract.load('nt35_cold_fat_tools',Path(__file__).with_name('prepare_nt35_usb_isolated.py'))
    WORK.mkdir();OUT.mkdir(parents=True);target=WORK/'target.qcow2'
    env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
    subprocess.run([str(helper.h.QIMG),'create','-q','-f','qcow2','-F','qcow2','-b',str(PARENT/'target.qcow2'),str(target)],env=env,check=True)
    compare=subprocess.run([str(helper.h.QIMG),'compare','-f','qcow2','-F','qcow2',str(PARENT/'target.qcow2'),str(target)],env=env,check=True,capture_output=True,text=True)
    if sha(PARENT/'target.qcow2')!=source_hash or sha(contract.PARENT)!=contract.PARENT_SHA:raise ValueError('Readonly backing changed during preparation')
    for key in ('new_client_files','usb_regression_only','only_guest_file_change'):meta.pop(key,None)
    meta.update(stopped_parent=str(PARENT/'target.qcow2'),diagnostic_only=True,guest_contents_unchanged=True,
        cold_policy_check_only=True,preparation='Byte-identical COW of completed client apply03; no guest file changes')
    (WORK/'fixture.json').write_bytes((json.dumps(meta,indent=2)+'\n').encode('utf-8'))
    record=dict(case=WORK.name,base=str(PARENT/'target.qcow2'),base_sha256=source_hash,base_unchanged=True,
        original_usb_parent_sha256=contract.PARENT_SHA,original_usb_parent_unchanged=True,
        overlay=str(target),overlay_sha256=sha(target),guest_contents_unchanged=True,
        system_unchanged=True,usb_unchanged=True,effective_disk_compare_pass=True,
        raw_overlay_qemu_compare_pass=True,qemu_img_compare_output=compare.stdout.strip(),
        source_command=str(SOURCE/'command.json'),source_command_sha256=command_hash,
        source_readback_sha256=sha(APPLY/'readback.json'),source_evaluation_sha256=sha(APPLY/'evaluation.json'),
        helper_sha256=contract.HELPER,helper_bytes=5632,actual_helper_imports_compatible=True,
        actual_helper_imports=contract.IMPORTS,source_import_proof_sha256=sha(APPLY/'preparation.json'),
        candidate_sha256=contract.CANDIDATE,usb_sha256=contract.USB,i8042prt_start=4,
        current_default=1,service_start=observed['service_start'],system_sha256=observed['system_sha256'],
        private_profile=False,folder='Windows NT 3.5',vm_started=False,cold_runtime_pass=False,
        scope='Empty COW of closed apply03 for a separate readonly native /check cold boot; no new-files claim')
    (OUT/'preparation.json').write_bytes((json.dumps(record,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(record,indent=2),flush=True)

if __name__=='__main__':main()
