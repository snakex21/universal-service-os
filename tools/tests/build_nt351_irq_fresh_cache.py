"""Freeze R22 plus the already built canonical-IRQ SYS; no VM or rebuild.

The effective multi-layer tree is compared entry by entry. Only the own SYS
and its integrity sidecar may differ. All other cache files remain identical.
"""
from pathlib import Path
import gzip,hashlib,importlib.util,json,os,shutil,stat,subprocess,sys

ROOT=Path(__file__).resolve().parents[2]
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
BASE=COLLECTION/'_assets/B261020-200536-968CCBE8-nt351-net3'
OUT=COLLECTION/'_assets/B261020-200536-968CCBE8-nt351-irq-fresh01'
BASE_INITRD='f958da5146114f210d5a738a55f8711d56b204c0adcaf0957ebf03e810cb772c'
OLD_DRIVER='f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a'
DRIVER='f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf'
POST='d2c1115180d8daeb02421d23920584a95dd8aa082a42c566dec1e9ff836e1096'
LOGGER='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7'
ARTIFACT=ROOT/'artifacts/coverage/nt351-irq-fresh01/cache-manifest.json'
INITRD=Path('zig-out/micro-linux/initramfs-usos')
PAYLOAD='usr/lib/usos/nt3/USOSNET351.SYS'
SIDECAR='usr/lib/usos/nt3/USOSNET351.SHA256'

def sha(data):return hashlib.sha256(data).hexdigest()
def file_sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module
    spec.loader.exec_module(module);return module
def modules():
    layers=load('nt351_irq_layers',ROOT/'tools/tests/build_nt351_r21_cache.py')
    return layers,layers.cpio_module()
def compare(before,after,delta):
    if before.keys()!=after.keys():raise ValueError('Effective tree names changed')
    changed=[]
    for name,entry in before.items():
        expected=delta.get(name,entry)
        actual=after[name]
        if actual.mode!=expected.mode or actual.data!=expected.data or actual.link!=expected.link:
            raise ValueError('Effective entry differs: '+name)
        if actual.mode!=entry.mode or actual.data!=entry.data or actual.link!=entry.link:changed.append(name)
    if set(changed)!=set(delta):raise ValueError('Declared replacement did not change each exact entry')
    return sorted(changed)
def safe_cache(path):
    resolved=path.resolve()
    if not resolved.is_relative_to(COLLECTION/'_assets') or resolved==COLLECTION/'_assets':
        raise ValueError('Exact owned asset folder required')
    for p in [path,*path.rglob('*')] if path.exists() else [path]:
        if p.exists() and p.lstat().st_file_attributes&0x400:raise ValueError('Reparse cache entry refused')

def main():
    safe_cache(BASE);safe_cache(OUT)
    if not BASE.is_dir() or OUT.exists() or ARTIFACT.exists():raise FileExistsError('Existing immutable base and absent fresh output required')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('100GiB free reserve required')
    original=(BASE/INITRD).read_bytes()
    if sha(original)!=BASE_INITRD:raise ValueError('R22 initrd pin mismatch')
    layers,cpio=modules();entries,count=layers.effective_newc(gzip.decompress(original))
    for name,expected in ((PAYLOAD,OLD_DRIVER),('usr/lib/usos/nt3/USOSNT3.EXE',POST),('usr/lib/usos/nt3/USOSLOG351.EXE',LOGGER)):
        if sha(entries[name].data)!=expected:raise ValueError('R22 effective entry pin mismatch: '+name)
    if entries[SIDECAR].data!=(OLD_DRIVER+'  USOSNET351.SYS\n').encode('ascii'):
        raise ValueError('R22 integrity sidecar mismatch')
    driver=ROOT/'tools/nt/usosnet/bin/i386/usosnet351.sys';data=driver.read_bytes()
    if sha(data)!=DRIVER or len(data)!=17024:raise ValueError('Actual candidate pin mismatch')
    delta={PAYLOAD:cpio.Entry(PAYLOAD,entries[PAYLOAD].mode,data),
           SIDECAR:cpio.Entry(SIDECAR,entries[SIDECAR].mode,(DRIVER+'  USOSNET351.SYS\n').encode('ascii'))}
    overlay=gzip.compress(cpio.newc(delta),compresslevel=9,mtime=0)
    combined=original+b'\0'*(-len(original)%4)+overlay
    effective,newcount=layers.effective_newc(gzip.decompress(combined))
    changed=compare(entries,effective,delta)
    if newcount!=count+1 or combined[:len(original)]!=original:raise ValueError('Original layers/prefix changed')
    # The secondary VM-tool initrd must not override either own payload.
    tools,_=layers.effective_newc(gzip.decompress((BASE/'zig-out/micro-linux/qemu9x.cpio').read_bytes()))
    if set(delta)&tools.keys():raise ValueError('Secondary initrd overrides own candidate')
    files={str(p.relative_to(BASE)).replace('\\','/'):dict(bytes=p.stat().st_size,sha256=file_sha(p))
           for p in sorted(BASE.rglob('*')) if p.is_file()}
    report=dict(scope='Fresh normal USOS NT351-only IRQ qualification; no runtime PASS at cache creation',
        base=str(BASE),output=str(OUT),source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        r22_initrd_sha256=BASE_INITRD,initrd_sha256=sha(combined),overlay_sha256=sha(overlay),
        base_prefix_preserved=True,base_layers=count,final_layers=newcount,effective_entries=len(entries),
        changed_entries=[dict(entry=name,old_sha256=sha(entries[name].data),sha256=sha(effective[name].data),
                              bytes=len(effective[name].data),mode=effective[name].mode) for name in changed],
        unchanged_effective_entries=len(entries)-len(changed),secondary_initrd_overrides_candidate=False,
        source_cache_files=files,driver_sha256=DRIVER,driver_bytes=17024,post_sha256=POST,logger_sha256=LOGGER,
        package_functional_change='Only own SYS canonical ICR/IMS/IMC/IAM constants; SHA sidecar updated',
        old_cache_modified=False,physical_writes=False,runtime_pass=False)
    shutil.copytree(BASE,OUT)
    (OUT/INITRD).write_bytes(combined)
    output_files={str(p.relative_to(OUT)).replace('\\','/') for p in OUT.rglob('*') if p.is_file()}
    if output_files!=files.keys():raise ValueError('Unexpected copied cache files')
    for relative,info in files.items():
        expected=sha(combined) if relative==INITRD.as_posix() else info['sha256']
        if file_sha(OUT/relative)!=expected or file_sha(BASE/relative)!=info['sha256']:
            raise ValueError('Cache copy/readback/base immutability mismatch: '+relative)
    report.update(other_cache_files_identical=True,old_cache_unchanged_after_copy=True)
    ARTIFACT.parent.mkdir(parents=True,exist_ok=True)
    encoded=(json.dumps(report,indent=2)+'\n').encode('utf-8')
    ARTIFACT.write_bytes(encoded);(OUT/'nt351-irq-fresh-inputs.json').write_bytes(encoded)
    print(json.dumps({k:report[k] for k in ('output','initrd_sha256','driver_sha256','base_layers','final_layers','effective_entries','unchanged_effective_entries')},indent=2))

if __name__=='__main__':main()
