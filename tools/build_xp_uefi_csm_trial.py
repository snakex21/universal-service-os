"""Build the XP UEFI-CSM package: UEFI -> micro-Linux staging -> firmware CSM.

Since refactor M4 the package is the production micro-Linux base PLUS the
PAE helper and the source-bound driver bundles; the scripts are the base's
own, byte for byte (the UEFI-CSM differences are branches on
USOS_PLAN_PROFILE=xp-x86-sp3-uefi-csm, set by pipeline step 100). Never
modifies production files or ISOs. Does not boot a VM.

  python tools/build_xp_uefi_csm_trial.py [--micro-linux zig-out/micro-linux] [--data L:/] [--out DIR] [--release]
  python tools/build_xp_uefi_csm_trial.py --data DIR --bundles-from OLD_PACKAGE --out DIR

--bundles-from rebuilds a package with the sources (and order) of OLD_PACKAGE
when not every source ISO is at hand (the stick's DATA is not plugged in):
each source whose ISO is in --data is rebuilt and its bundle must be
byte-identical to OLD_PACKAGE's (reproducibility); the others reuse
OLD_PACKAGE/drivers/<sha256>/bundle as it is.
"""
from pathlib import Path
import argparse, gzip, hashlib, json, os, shutil, stat, struct, subprocess
from build_micro_linux import parse_newc, newc, Entry, put, pad_initrd
from xp_driver_overlay import build_driver_overlay

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'zig-out/xp-uefi-csm'
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def add_driver_source(iso,out_dir=None):
    """Add a source-bound overlay without rebuilding working boot/UI payloads."""
    iso=iso.resolve()
    if not iso.is_file() or iso.suffix.lower()!='.iso':raise ValueError('Expected an existing XP ISO')
    manifest_path=OUT/'manifest.json'
    metadata=json.loads(manifest_path.read_text())
    for name,expected in metadata['sha256'].items():
        if digest(OUT/name)!=expected:raise ValueError('Existing package hash mismatch: '+name)
    source_hash=digest(iso)
    # out_dir lets the original build's bundle (drivers/0) be rebuilt in place.
    bundle_id,bundle=build_driver_overlay(iso,out_dir or OUT/'drivers'/source_hash)
    init=OUT/'initramfs-xp'
    entries=parse_newc(gzip.decompress(init.read_bytes()))
    prefix='usr/lib/usos/xp-drivers/'+bundle_id+'/'
    def unrelated(n):return n!=prefix.rstrip('/') and not n.startswith(prefix)
    before={n:(e.mode,e.data) for n,e in entries.items() if unrelated(n)}
    for path in bundle.rglob('*'):
        if path.is_file():put(entries,Entry(prefix+path.relative_to(bundle).as_posix(),stat.S_IFREG|0o644,path.read_bytes()))
    result=pad_initrd(gzip.compress(newc(entries),compresslevel=6,mtime=0))
    checked=parse_newc(gzip.decompress(result))
    after={n:(e.mode,e.data) for n,e in checked.items() if unrelated(n)}
    assert after==before,('Unrelated payload changed',[n for n in before.keys()|after.keys() if before.get(n)!=after.get(n)])
    for path in bundle.rglob('*'):
        if path.is_file():assert checked[prefix+path.relative_to(bundle).as_posix()].data==path.read_bytes()
    init.write_bytes(result)
    metadata['sha256']['initramfs-xp']=digest(init)
    for key,value in [('driver_bundles',bundle_id),('driver_supported_sources',iso.name),('iso_names',iso.name)]:
        if value not in metadata[key]:metadata[key].append(value)
    metadata['added_source']={'name':iso.name,'sha256':source_hash,'size':iso.stat().st_size,'bundle':bundle_id}
    metadata['driver_sources']=[s for s in metadata.get('driver_sources',[]) if s['name']!=iso.name]+[metadata['added_source']]
    metadata['hardware_verified']=False
    manifest_path.write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_SOURCE_ADDED',iso.name,'BUNDLE',bundle_id,flush=True)
    print('PASS: archive roundtrip; new overlay byte verification; every existing boot/UI/helper payload unchanged; no VM/E2E',flush=True)

# PAE is enabled at the END of GUI setup ([SetupParams] UserExecute, SYSTEM
# context, GUI-subsystem helper: no window), so the reboot that ends setup
# already boots the PAE entry. The flow always installs XP to C:. No argument:
# the helper's default mode is the silent setup-end path.
PAE_SETUP_END='[SetupParams]\nUserExecute="C:\\USOS\\XP\\pae.exe"\n'
# First logon: silent check; only if setup-end did not enable PAE does it apply
# it and ask (Yes/No, in the installer-chosen language from pae-strings.ini,
# English fallback) for the one restart it then needs.
PAE_GUI_RUN_ONCE='Command0="%SystemDrive%\\USOS\\XP\\pae.exe /firstlogon"'
# Entries owned by the PAE/finalization part of the flow (see refresh_pae_flow).
PAE_FLOW_ENTRIES=('xp-pae.exe',)

def put_pae_flow(entries,base_entries,helper):
    put(entries,Entry('usr/lib/usos/xp-pae.exe',stat.S_IFREG|0o644,helper.read_bytes()))

def compile_helper(env):
    zig=str(ROOT/'tools/zig/zig.exe');helper=OUT/'pae.exe'
    subprocess.run([zig,'cc','-target','x86-windows-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(ROOT/'tools/zig/lib/libc/include/any-windows-any'),str(ROOT/'tools/windows_xp_pae.c'),'-Wl,--entry,entry','-lkernel32','-luser32','-ladvapi32','-lversion','-o',str(helper)],env=env,check=True)
    # Zig's current linker defaults target newer Windows. This helper only uses
    # XP-era APIs; publish the matching PE subsystem/OS minimum explicitly.
    binary=bytearray(helper.read_bytes());pe=struct.unpack_from('<I',binary,60)[0];optional=pe+24
    assert binary[pe:pe+4]==b'PE\0\0' and struct.unpack_from('<H',binary,pe+4)[0]==0x14c
    struct.pack_into('<HH',binary,optional+40,5,1)
    struct.pack_into('<HH',binary,optional+48,5,1)
    struct.pack_into('<I',binary,optional+64,0)
    # Windows GUI subsystem: no console window when GuiRunOnce starts it.
    assert struct.unpack_from('<H',binary,optional+68)[0] in (2,3)
    struct.pack_into('<H',binary,optional+68,2)
    helper.write_bytes(binary)
    return helper

def refresh_pae_flow(esp):
    """Rebuild pae.exe and the PAE/finalization scripts in the existing package.
    Driver bundles, UI, kernel and every other entry stay byte-identical."""
    manifest_path=OUT/'manifest.json';metadata=json.loads(manifest_path.read_text())
    for name,expected in metadata['sha256'].items():
        if digest(OUT/name)!=expected:raise ValueError('Existing package hash mismatch: '+name)
    base_path=esp/'EFI/USOS/micro-linux/initramfs-usos'
    if digest(base_path)!=metadata['base_initramfs_sha256']:raise ValueError('Production base changed after trial build')
    base=parse_newc(gzip.decompress(base_path.read_bytes()))
    env=dict(os.environ,TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
    (OUT/'tmp').mkdir(exist_ok=True)
    helper=compile_helper(env)
    init=OUT/'initramfs-xp'
    entries=parse_newc(gzip.decompress(init.read_bytes()))
    owned={'usr/lib/usos/'+n for n in PAE_FLOW_ENTRIES}
    before={n:(e.mode,e.data) for n,e in entries.items() if n not in owned}
    put_pae_flow(entries,base_entries=base,helper=helper)
    result=pad_initrd(gzip.compress(newc(entries),compresslevel=6,mtime=0))
    checked=parse_newc(gzip.decompress(result))
    after={n:(e.mode,e.data) for n,e in checked.items() if n not in owned}
    assert after==before,('Unrelated payload changed',[n for n in before.keys()|after.keys() if before.get(n)!=after.get(n)])
    assert checked['usr/lib/usos/xp-pae.exe'].data==helper.read_bytes()
    init.write_bytes(result)
    metadata['sha256']['initramfs-xp']=digest(init);metadata['sha256']['pae.exe']=digest(helper)
    metadata['pae_flow_revision']='20260923-setup-end-pae-firstlogon-fallback-i18n-crashdump-off'
    manifest_path.write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_PAE_FLOW_REFRESHED; silent helper; PAE default timeout=0; read-only zero-file verification; other entries unchanged; no VM/E2E',flush=True)

# Entries the package adds to the production base (refactor M4): the PAE
# helper and its notice, and the source-bound driver bundles. Every other
# entry, scripts included, is the base's own, byte for byte: the UEFI-CSM
# differences are profile branches in the scripts (USOS_PLAN_PROFILE).
PACKAGE_ENTRIES=('usr/lib/usos/xp-pae.exe','usr/lib/usos/xp-pae-LICENSE.txt')
PACKAGE_PREFIXES=('usr/lib/usos/xp-drivers/','usr/lib/usos/nt5-storage/')

# NT 5.2 (Server 2003 x86, XP x64) AHCI: GenAHCI 6.3.0.1 x86/x64 on the
# system's own StorPort (tools/nt5_storage_stage.sh). Pinned archive.
GENAHCI_ARCHIVE=ROOT/'tools/vendor/xp-modern/2026-09-21/GenAHCI_6.3.0.1.7z'
GENAHCI_SHA256='f8dd54123934c176a2b6315df7b4a1dfe2ff6761fa3bc27cecfeedbe421b279f'

def nt5_storage_files():
    if digest(GENAHCI_ARCHIVE)!=GENAHCI_SHA256:raise ValueError('GenAHCI archive hash mismatch')
    def member(name):
        return subprocess.run(['C:/Program Files/7-Zip/7z.exe','e','-so',str(GENAHCI_ARCHIVE),name],check=True,capture_output=True).stdout
    note=(b'GenAHCI 6.3.0.1 (x86 and x64 builds, unmodified), https://github.com/GeorgeK1ng/GenAHCI\n'
          b'archive GenAHCI_6.3.0.1.7z sha256 '+GENAHCI_SHA256.encode()+b'; licence: gpl.txt of the archive.\n'
          b'USOS uses it only for Windows Server 2003 x86 and XP x64 (NT 5.2) text-mode Setup.\n')
    files={'x86/genahci.sys':member('x86/genahci.sys'),'amd64/genahci.sys':member('x64/genahci.sys'),'gpl.txt':member('gpl.txt'),'SOURCE.txt':note}
    for name,data in files.items():
        if not data:raise ValueError('GenAHCI member missing: '+name)
    return files

def is_package_entry(name):
    return name in PACKAGE_ENTRIES or name=='usr/lib/usos/xp-drivers' or name.startswith(PACKAGE_PREFIXES)

def overlay(base, helper, driver_bundles):
    entries=parse_newc(gzip.decompress(base.read_bytes()))
    prefix='usr/lib/usos/'
    before={n:(e.mode,e.data) for n,e in entries.items()}
    for required in ('xp_driver_stage.sh','xp_verify_target.sh','xp_selected_partition_uefi_csm.sif','pipeline/steps/100_nt5_staging.sh'):
        if prefix+required not in entries:raise ValueError('micro-Linux base predates the M4 UEFI-CSM profile: '+required)
    ntfs=entries[prefix+'xp-nt52-ntfs.bin'].data
    if ntfs[212:221]!=bytes.fromhex('663B06200090909090'):raise ValueError('EDD-only NT52 template not present')
    put(entries,Entry(prefix+'xp-pae.exe',stat.S_IFREG|0o644,helper.read_bytes()))
    for bundle_id,bundle in driver_bundles:
        for path in bundle.rglob('*'):
            if path.is_file():put(entries,Entry(prefix+'xp-drivers/'+bundle_id+'/'+path.relative_to(bundle).as_posix(),stat.S_IFREG|0o644,path.read_bytes()))
    vendor=ROOT/'tools/vendor/patchpae3/3e1d3b65f5c3c1ec0c4759f707d3017e51113103'
    credit=b'USOS XP PAE: adapted from evgen-b/PatchPAE3, commit 3e1d3b65f5c3c1ec0c4759f707d3017e51113103.\nhttps://github.com/evgen-b/PatchPAE3\nPatterns by evgen_b, based on wj32 and XP64G. USOS adds strict checks and separate output/boot entries.\n\n'
    put(entries,Entry(prefix+'xp-pae-LICENSE.txt',stat.S_IFREG|0o644,credit+(vendor/'LICENSE').read_bytes()))
    for name,data in nt5_storage_files().items():put(entries,Entry(prefix+'nt5-storage/'+name,stat.S_IFREG|0o644,data))
    changed=[n for n in before if not is_package_entry(n) and (entries[n].mode,entries[n].data)!=before[n]]
    if changed:raise ValueError('package would change base entries: '+', '.join(changed))
    return pad_initrd(gzip.compress(newc(entries),compresslevel=6,mtime=0))

def is_sp3(iso):
    # Microsoft names it "..._with_service_pack_3_...", others "SP3".
    name=iso.name.lower()
    return 'sp3' in name or 'service_pack_3' in name

# --release: only these original Microsoft sources get a driver bundle; any
# other ISO on DATA (e.g. third-party images) is skipped. Stick builds keep
# taking every SP3 ISO on DATA.
RELEASE_SOURCES={
    'bd3234250a6e2f68fbacf0a46cf42a7d711811e428210c0d60649a054f28ff0b':'pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso',
    '62b6c91563bad6cd12a352aa018627c314cfc5162d8e9f8af0756a642e602a46':'en_windows_xp_professional_with_service_pack_3_x86_cd_x14-80428.iso',
}

def release_selection(supported,hashes):
    """Allowlisted sources in DATA order; every allowlisted source is required."""
    chosen=[p for p in supported if hashes[p] in RELEASE_SOURCES]
    for p in supported:
        if p not in chosen:print('XP release: skipping source not on the allowlist:',p.name,flush=True)
    missing=sorted(set(RELEASE_SOURCES)-{hashes[p] for p in chosen})
    if missing:raise ValueError('XP release: allowlisted source missing on DATA: '+', '.join(RELEASE_SOURCES[h] for h in missing))
    return chosen

def same_tree(a, b):
    files = lambda root: {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob('*') if p.is_file()}
    return files(a) == files(b)

def build_from_old(micro, data, old):
    """The stick package of `old` (same sources, same order) on a new base."""
    old = old.resolve()
    old_meta = json.loads((old/'manifest.json').read_text())
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'tmp').mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
    helper=compile_helper(env)
    base=micro/'initramfs-usos';kernel=micro/'vmlinuz-virt'
    local={p.name:p for p in (data/'Systems/Windows/Windows XP/Images').glob('*.iso')} if data.exists() else {}
    driver_bundles=[];sources=[]
    for source in old_meta['driver_sources']:
        old_bundle=old/'drivers'/source['sha256']/'bundle'
        iso=local.get(source['name'])
        if iso is not None:
            if digest(iso)!=source['sha256']:raise ValueError('ISO differs from the old package source: '+iso.name)
            bundle_id,bundle=build_driver_overlay(iso,OUT/'drivers'/source['sha256'])
            if bundle_id!=source['bundle']:raise ValueError('driver bundle id differs: '+iso.name)
            # Cabinet/hive timestamps may differ; compare_xp_packages.py judges the content.
            print('XP_BUNDLE_REBUILT',iso.name,bundle_id,'identical' if same_tree(bundle,old_bundle) else 'bytes differ (see compare_xp_packages)',flush=True)
        else:
            # The whole work folder (the checks read its original/ files too).
            target=OUT/'drivers'/source['sha256']
            if target.resolve()!=old_bundle.parent:
                shutil.rmtree(target,ignore_errors=True);shutil.copytree(old_bundle.parent,target)
            bundle_id,bundle=source['bundle'],target/'bundle'
            print('XP_BUNDLE_REUSED',source['name'],bundle_id,flush=True)
        driver_bundles.append((bundle_id,bundle));sources.append(dict(source))
    init=OUT/'initramfs-xp';init.write_bytes(overlay(base,helper,driver_bundles))
    shutil.copyfile(kernel,OUT/'vmlinuz.efi')
    metadata=dict(old_meta)
    metadata.update({'driver_bundles':[n for n,_ in driver_bundles],'driver_sources':sources,'base_initramfs_sha256':digest(base),'base_kernel_sha256':digest(kernel),'hardware_verified':False,'sha256':{p.name:digest(p) for p in [init,OUT/'vmlinuz.efi',helper]}})
    metadata.pop('added_source',None)
    (OUT/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_UEFI_CSM_PACKAGE_REBUILT from',old.name,'; base scripts unchanged (profile xp-x86-sp3-uefi-csm); no VM/E2E',flush=True)

def build(micro, data, release=False):
    """Full package from a micro-Linux build (default zig-out/micro-linux) and
    the XP ISOs of a DATA folder (read only). No stick is read: the per-ISO
    launchers that needed the stick's ESP identity are gone (the UEFI menu
    starts the package itself, src/platform/uefi/xp_preparation.zig)."""
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'tmp').mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
    helper=compile_helper(env)
    base=micro/'initramfs-usos';kernel=micro/'vmlinuz-virt'
    images=sorted((data/'Systems/Windows/Windows XP/Images').glob('*.iso'))
    if not images:raise ValueError('No XP ISO on DATA')
    # SP2 remains visible for historical compatibility but is refused before
    # any target write by the new runtime preflight. First hardware trial: SP3.
    supported=[p for p in images if is_sp3(p)]
    if not supported:raise ValueError('XP SP3 source required for modern driver integration')
    # One work folder per source ISO content (not per list position), so a
    # bundle always rebuilds from, and is checked against, its own source.
    hashes={p:digest(p) for p in supported}
    if release:supported=release_selection(supported,hashes)
    sources=[{'name':p.name,'sha256':hashes[p],'size':p.stat().st_size} for p in supported]
    driver_bundles=[build_driver_overlay(p,OUT/'drivers'/s['sha256']) for p,s in zip(supported,sources)]
    for s,(bundle_id,_) in zip(sources,driver_bundles):s['bundle']=bundle_id
    init=OUT/'initramfs-xp';init.write_bytes(overlay(base,helper,driver_bundles))
    shutil.copyfile(kernel,OUT/'vmlinuz.efi')
    for stale in OUT.glob('XP-SP*-UEFI-CSM-PAE.efi'):stale.unlink()
    metadata={'experimental':True,'driver_bundles':[n for n,_ in driver_bundles],'driver_supported_sources':[p.name for p in supported],'driver_sources':sources,'firmware':'UEFI preparation; XP through firmware CSM','hardware_verified':False,'base_initramfs_sha256':digest(base),'base_kernel_sha256':digest(kernel),'launchers':[],'iso_names':[i.name for i in (supported if release else images)],'profile':'xp-x86-sp3-uefi-csm','sha256':{p.name:digest(p) for p in [init,OUT/'vmlinuz.efi',helper]}}
    if release:metadata['release']=True
    (OUT/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_UEFI_CSM_TRIAL_BUILT; base scripts unchanged (profile xp-x86-sp3-uefi-csm); no VM/E2E',flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--micro-linux',type=Path,default=ROOT/'zig-out/micro-linux',help='micro-Linux build the package is derived from')
    p.add_argument('--data',type=Path,default=Path('L:/'),help='DATA folder with Systems/Windows/Windows XP/Images (read only)')
    p.add_argument('--out',type=Path,default=OUT,help='package folder (default zig-out/xp-uefi-csm)')
    p.add_argument('--esp',type=Path,default=Path('J:/'),help='--refresh-pae-flow only: ESP whose base the package was built from')
    p.add_argument('--release',action='store_true',help='release package: only the RELEASE_SOURCES SHA-256 allowlist (original PL x14-80476 and EN x14-80428)')
    p.add_argument('--bundles-from',type=Path,help='rebuild with the sources of this package; ISOs missing in --data reuse its driver bundles')
    mode=p.add_mutually_exclusive_group();mode.add_argument('--menu-only',action='store_true');mode.add_argument('--add-source',type=Path);mode.add_argument('--refresh-pae-flow',action='store_true');a=p.parse_args()
    OUT=a.out.resolve()
    if a.menu_only:
        env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'))
        subprocess.run([str(ROOT/'tools/zig/zig.exe'),'build','usos-x86_64','framebuffer-ui','test','-Doptimize=ReleaseFast','--cache-dir',str(ROOT/'tools/cache/zig')],cwd=ROOT,env=env,check=True)
        print('PASS: Zig UEFI menu build and Zig tests; no BIOS build or VM/E2E')
    elif a.add_source:add_driver_source(a.add_source)
    elif a.refresh_pae_flow:refresh_pae_flow(a.esp)
    elif a.bundles_from:build_from_old(a.micro_linux.resolve(),a.data,a.bundles_from)
    else:build(a.micro_linux.resolve(),a.data,a.release)
