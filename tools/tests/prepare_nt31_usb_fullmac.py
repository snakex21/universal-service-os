"""Empty COW of clean R24c: unchanged full-MAC/USB/network coexistence test."""
from pathlib import Path
import hashlib,importlib.util,json,shutil,subprocess
ROOT=Path(__file__).resolve().parents[2]
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
TAG='r24d-nt31-usb-fullmac'
BASE=COLLECTION/'_vm/r24c-nt31-registermac-order/target.qcow2'
BASE_SHA='05638a08cfd41460d5d1b96b3735859ac7b1ac33ed97b2bfa0951a5124a4de1d'
DRIVER_SHA='b49f2445a2e48dbf75b50f426ccc1cef09943a84e779d351747d4cbc8df27a8d'
USB_SHA='f5373eb3bf829d585651bc0da7ea5b1ca9b0cf2b20a1fe74ccb5054955f3ef05'
WORK=COLLECTION/'_vm'/TAG
RUNTIME=ROOT/'artifacts/nt31-fullmac-runtime'
OUT=RUNTIME/'r24d-preparation.json'

def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def validate(done,result,fixture,readback):
    if done.get('stopped') is not True or result.get('qemu_returncode')!=0:raise ValueError('R24c writer must be completed')
    if fixture.get('private_profile') is not False or fixture.get('folder')!='Windows NT 3.1':raise ValueError('Explicit keyless NT31 only')
    if readback.get('target_sha256')!=BASE_SHA or readback.get('target_unchanged') is not True:raise ValueError('Actual stopped readback required')
    if readback['files']['USNET31.SYS']['sha256']!=DRIVER_SHA or readback['files']['USOSUSB.SYS']['sha256']!=USB_SHA:raise ValueError('Pinned own drivers required')
    if readback['services']['i8042prt'].get('start')!=4 or readback['services']['usosusb'].get('start')!=0:raise ValueError('USB isolation must remain unchanged')

def main():
    if WORK.exists() or OUT.exists():raise FileExistsError('Never overwrite a prepared run')
    if not WORK.is_relative_to(COLLECTION/'_vm') or sha(BASE)!=BASE_SHA:raise ValueError('Pinned owned base required')
    prior=RUNTIME/'vm/r24c-nt31-registermac-order'
    read=lambda p:json.loads(p.read_text(encoding='utf-8'))
    fixture=read(BASE.parent/'fixture.json')
    validate(read(prior/'completed.json'),read(prior/'result.json'),fixture,read(RUNTIME/'r24c-stopped-readback/readback.json'))
    old=read(RUNTIME/'r24c-preparation.json')
    if old['driver_sha256']!=DRIVER_SHA:raise ValueError('Candidate mismatch')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('100GiB reserve required')
    spec=importlib.util.spec_from_file_location('nt31_usb_fat',ROOT.parent/'nt351-net/tools/tests/coverage/prepare_nt351_debug.py')
    fat=importlib.util.module_from_spec(spec);spec.loader.exec_module(fat)
    WORK.mkdir()
    for leaf in ('target.qcow2','stick.qcow2'):
        subprocess.run([str(fat.QIMG),'create','-q','-f','qcow2','-F','qcow2','-b',str(BASE.parent/leaf),str(WORK/leaf)],check=True,capture_output=True)
        subprocess.run([str(fat.QIMG),'compare','-f','qcow2','-F','qcow2',str(BASE.parent/leaf),str(WORK/leaf)],check=True,capture_output=True)
    shutil.copyfile(BASE.parent/'vars.fd',WORK/'vars.fd')
    fixture.update(preparation='R24d unchanged-binary USB/full-MAC regression',manifest=str(OUT))
    (WORK/'fixture.json').write_bytes((json.dumps(fixture,indent=2)+'\n').encode('utf-8'))
    result=dict(scope='Empty COW of completed R24c; no NCPA, binary or network changes',tag=TAG,base=str(BASE),base_sha256=BASE_SHA,
        overlay=str(WORK/'target.qcow2'),overlay_sha256=sha(WORK/'target.qcow2'),vars_sha256=sha(WORK/'vars.fd'),stick_sha256=sha(WORK/'stick.qcow2'),
        driver_sha256=DRIVER_SHA,driver_size=16384,helper_sha256=old['helper_sha256'],logger_sha256=old['logger_sha256'],
        original_archive_sha256=old['original_archive_sha256'],original_iso_sha256=old['original_iso_sha256'],bdf=old['bdf'],mac=old['mac'],
        runtime_pass=False,private_profile=False,staged_readback_pass=True,logical_base_identity_verified=True,
        changed_guest_files=[],old_logs_inherited=True,base_unchanged=sha(BASE)==BASE_SHA)
    if not result['base_unchanged']:raise ValueError('Readonly base changed')
    OUT.write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
