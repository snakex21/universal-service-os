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

def main():
    if OUT.exists() or ARTIFACT.exists():raise FileExistsError('Fresh cache/artifact required')
    if not BASE.resolve().is_relative_to(COLLECTION/'_assets') or not OUT.resolve().is_relative_to(COLLECTION/'_assets'):raise ValueError('Owned assets only')
    if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT).strip():raise ValueError('Commit reviewed sources before freezing cache')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('Less than100GiB free')
    original=(BASE/'zig-out/micro-linux/initramfs-usos').read_bytes()
    if sha(original)!=BASE_INITRD:raise ValueError('Exact frozen net2 required')
    entries,layers=effective_newc(gzip.decompress(original));cpio=cpio_module()
    target=entries['usr/lib/usos/nt4_csmwrap_target.sh'].data
    if b'if (k == "Greenwich") return "(GMT) Monrovia, Casablanca"' not in target:raise ValueError('Final NT351 UTC alias absent')
    expected_old={'USOSNET351.SYS':'dc8827954e6fe75ee8264c7382e87899cc9761890998198c126c7ea8aa5c55b6',
                  'USOSNT3.EXE':'285ac43a0499aff6b810542365551978d2a3bbc24fdf6662f9074d1f456fd705',
                  'USOSLOG351.EXE':LOGGER}
    for leaf,digest in expected_old.items():
        if sha(entries['usr/lib/usos/nt3/'+leaf].data)!=digest:raise ValueError('Unexpected frozen base payload '+leaf)
    driver=ROOT/'tools/nt/usosnet/bin/i386/usosnet351.sys'
    post=ROOT/'artifacts/nt351-network/marker-gate-post-01/USOSNT3.EXE'
    if sha(driver.read_bytes())!=DRIVER or sha(post.read_bytes())!=POST:raise ValueError('Actual driver/helper pin mismatch')
    if sha((ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_bytes())!=POST_SOURCE:raise ValueError('Marker helper source changed')
    import pefile
    def pe(data):
        p=pefile.PE(data=data)
        imports=sorted((m.dll.decode('ascii').lower(),i.name.decode('ascii') if i.name else '#'+str(i.ordinal)) for m in p.DIRECTORY_ENTRY_IMPORT for i in m.imports)
        return p,imports
    helper,imports=pe(post.read_bytes());old,old_imports=pe(entries['usr/lib/usos/nt3/USOSNT3.EXE'].data)
    if helper.FILE_HEADER.Machine!=0x14c or (helper.OPTIONAL_HEADER.MajorSubsystemVersion,helper.OPTIONAL_HEADER.MinorSubsystemVersion)!=(3,10) or imports!=old_imports:raise ValueError('Helper PE/import contract changed')
    replacements={'USOSNET351.SYS':driver.read_bytes(),'USOSNET351.SHA256':(DRIVER+'  USOSNET351.SYS\n').encode('ascii'),'USOSNT3.EXE':post.read_bytes()}
    delta={}
    for leaf,data in replacements.items():
        name='usr/lib/usos/nt3/'+leaf;delta[name]=cpio.Entry(name,entries[name].mode,data)
    overlay=gzip.compress(cpio.newc(delta),compresslevel=9,mtime=0)
    combined=original+b'\0'*(-len(original)%4)+overlay
    effective,new_layers=effective_newc(gzip.decompress(combined))
    if effective.keys()!=entries.keys() or new_layers!=layers+1:raise ValueError('Unexpected effective cache tree')
    for name,entry in entries.items():
        expected=delta.get(name,entry)
        if effective[name].mode!=expected.mode or effective[name].data!=expected.data:raise ValueError('Effective cache mismatch '+name)
    if sha((BASE/'zig-out/bin/usos-x86_64.efi').read_bytes())!=EFI:raise ValueError('Frozen renderer changed')
    report=dict(scope='Fresh NT351-only experimental fixture; not Windows PASS or complete USOS release',
        base=str(BASE),output=str(OUT),source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        base_initrd_sha256=BASE_INITRD,initrd_sha256=sha(combined),overlay_sha256=sha(overlay),base_prefix_preserved=combined[:len(original)]==original,
        base_layers=layers,final_layers=new_layers,effective_entries=len(effective),changed_entries=[dict(entry=name,sha256=sha(entry.data),bytes=len(entry.data)) for name,entry in delta.items()],
        driver_sha256=DRIVER,post_sha256=POST,post_source_sha256=POST_SOURCE,post_source_commit='87f599b1',post_imports_identical=True,post_import_count=len(imports),
        logger_sha256=LOGGER,efi_sha256=EFI,unchanged_scripts={name:sha(entry.data) for name,entry in entries.items() if name.startswith('usr/lib/usos/') and name.endswith('.sh')},
        utc_alias='Greenwich -> (GMT) Monrovia, Casablanca',other_base_files_unchanged=True,nt35_r20_modified=False,r18f_result_modified=False,runtime_pass=False,
        qualification='Installed USB isolation is R18f; R21 fresh install permits PS/2 and requires desktop plus actual guest DHCP/ping/DNS')
    shutil.copytree(BASE,OUT)
    initrd=OUT/'zig-out/micro-linux/initramfs-usos';initrd.write_bytes(combined)
    if sha(initrd.read_bytes())!=report['initrd_sha256']:raise ValueError('Written cache readback differs')
    for path in BASE.rglob('*'):
        if path.is_file() and path.relative_to(BASE)!=Path('zig-out/micro-linux/initramfs-usos'):
            if sha(path.read_bytes())!=sha((OUT/path.relative_to(BASE)).read_bytes()):raise ValueError('Unchanged cache file mismatch')
    (OUT/'nt351-r21-inputs.json').write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    ARTIFACT.write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    print(json.dumps({k:report[k] for k in ('output','initrd_sha256','driver_sha256','post_sha256','base_layers','final_layers','effective_entries')},indent=2))

if __name__=='__main__':main()
