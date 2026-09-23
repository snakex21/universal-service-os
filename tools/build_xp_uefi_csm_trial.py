"""Build an isolated UEFI -> Linux staging -> firmware CSM XP experiment.

Never modifies production BIOS scripts, initramfs or ISO files. Does not boot a VM.
"""
from pathlib import Path
import argparse, gzip, hashlib, json, os, shutil, stat, struct, subprocess
from build_micro_linux import parse_newc, newc, Entry, put
from xp_driver_overlay import build_driver_overlay

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'zig-out/xp-uefi-csm'
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def replace_once(text, old, new):
    if text.count(old)!=1: raise ValueError('Experimental overlay anchor changed: '+old[:90])
    return text.replace(old,new)

def update_ui(entries):
    prefix='usr/lib/usos/'
    put(entries,Entry('usr/bin/usos-fb-ui',stat.S_IFREG|0o755,(ROOT/'zig-out/micro-linux/usos-fb-ui').read_bytes()))
    put(entries,Entry(prefix+'xp_menu_ui.sh',stat.S_IFREG|0o755,(ROOT/'tools/xp_menu_ui.sh').read_bytes()))
    # Shared UI library: per-path stage labels/totals for the renderer above.
    put(entries,Entry(prefix+'micro_linux_ui.sh',stat.S_IFREG|0o755,(ROOT/'tools/micro_linux_ui.sh').read_bytes()))
    init=entries['usos-init'].data.decode()
    marker='export USOS_XP_TRACE_DIR=/mnt/esp/EFI/USOS-XP'
    if marker not in init:
        init=replace_once(init,'mkdir -p /mnt/esp/EFI/USOS-XP\n', '''mkdir -p /mnt/esp/EFI/USOS-XP
export USOS_XP_TRACE_DIR=/mnt/esp/EFI/USOS-XP
# Preserve the preceding attempt, then reset this attempt's diagnostics.
for trace_name in menu-events.log menu-state.txt menu-hardware.txt legacy-xp-staging-last-error.txt; do
    if [ -f "$USOS_XP_TRACE_DIR/$trace_name" ]; then
        mv "$USOS_XP_TRACE_DIR/$trace_name" "$USOS_XP_TRACE_DIR/$trace_name.previous"
    fi
done
printf 'phase=init-mounted\\nboot_id=%s\\n' "$(cat /proc/sys/kernel/random/boot_id)" > "$USOS_XP_TRACE_DIR/menu-events.log"
sync
''')
        put(entries,Entry('usos-init',stat.S_IFREG|0o755,init.encode()))
    return entries

def rebuild_ui():
    path=OUT/'manifest.json';metadata=json.loads(path.read_text())
    for name,expected in metadata['sha256'].items():
        if digest(OUT/name)!=expected:raise ValueError('Existing package hash mismatch: '+name)
    init=OUT/'initramfs-xp'
    init.write_bytes(gzip.compress(newc(update_ui(parse_newc(gzip.decompress(init.read_bytes())))),compresslevel=6,mtime=0))
    metadata['sha256']['initramfs-xp']=digest(init)
    metadata['ui_revision']='20260923-pointer-latency'
    path.write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_UI_OVERLAY_BUILT; driver payload unchanged; no VM/E2E',flush=True)

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
    result=gzip.compress(newc(entries),compresslevel=6,mtime=0)
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
PAE_FLOW_ENTRIES=('prepare_xp_ntfs_target.sh','xp_selected_partition.sif','xp-pae.exe','xp_verify_target.sh')

def overlay_prepare(prepare):
    """Derive the experimental NTFS preparer from the production script."""
    prepare=replace_once(prepare,'sh "$SCRIPT_DIR/prepare_xp_local_source.sh"','sh "$SCRIPT_DIR/prepare_xp_local_source.sh"\nsh "$SCRIPT_DIR/xp_driver_stage.sh" apply || fail \'XP driver integration failed\'')
    return replace_once(prepare,'sync\numount "$work/volume"; mounted=no\n', '''mkdir -p "$work/volume/USOS/XP"
cp "$SCRIPT_DIR/xp-pae.exe" "$work/volume/USOS/XP/pae.exe"
cp "$SCRIPT_DIR/xp-pae-LICENSE.txt" "$work/volume/USOS/XP/LICENSE.txt"
cmp -s "$SCRIPT_DIR/xp-pae.exe" "$work/volume/USOS/XP/pae.exe" || fail 'PAE helper readback mismatch'
# Installer-chosen language (only that one is on the ESP); pae.exe falls back to English.
if [ -f /mnt/esp/EFI/USOS/lang-xp.ini ]; then
cp /mnt/esp/EFI/USOS/lang-xp.ini "$work/volume/USOS/XP/pae-strings.ini"
cmp -s /mnt/esp/EFI/USOS/lang-xp.ini "$work/volume/USOS/XP/pae-strings.ini" || fail 'PAE strings readback mismatch'
printf '[XP_PAE] strings=lang-xp.ini
'
else
printf '[XP_PAE] strings=built-in English (no lang-xp.ini on ESP)
'
fi
sync
umount "$work/volume"; mounted=no
blockdev --flushbufs "$TARGET_DEVICE" || fail 'cannot flush target disk buffers'
# Read-only remount: refuse zero-filled staged files, then flush again.
sh "$SCRIPT_DIR/xp_verify_target.sh" "$node" "$SCRIPT_DIR/xp-pae.exe" || fail 'post-write read-only verification failed'
''')

def overlay_sif(sif):
    sif=sif.rstrip()+'\n'+PAE_SETUP_END+'[GuiRunOnce]\n'+PAE_GUI_RUN_ONCE+'\n'
    return replace_once(sif,'[Unattended]','[Unattended]\nDriverSigningPolicy=Ignore\nNonDriverSigningPolicy=Ignore')

def put_pae_flow(entries,base_entries,helper):
    prefix='usr/lib/usos/'
    put(entries,Entry(prefix+'prepare_xp_ntfs_target.sh',stat.S_IFREG|0o755,overlay_prepare(base_entries[prefix+'prepare_xp_ntfs_target.sh'].data.decode()).encode()))
    put(entries,Entry(prefix+'xp_selected_partition.sif',stat.S_IFREG|0o644,overlay_sif(base_entries[prefix+'xp_selected_partition.sif'].data.decode()).encode()))
    put(entries,Entry(prefix+'xp-pae.exe',stat.S_IFREG|0o644,helper.read_bytes()))
    put(entries,Entry(prefix+'xp_verify_target.sh',stat.S_IFREG|0o755,(ROOT/'tools/xp_verify_target.sh').read_bytes()))

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
    result=gzip.compress(newc(entries),compresslevel=6,mtime=0)
    checked=parse_newc(gzip.decompress(result))
    after={n:(e.mode,e.data) for n,e in checked.items() if n not in owned}
    assert after==before,('Unrelated payload changed',[n for n in before.keys()|after.keys() if before.get(n)!=after.get(n)])
    assert checked['usr/lib/usos/xp-pae.exe'].data==helper.read_bytes()
    init.write_bytes(result)
    metadata['sha256']['initramfs-xp']=digest(init);metadata['sha256']['pae.exe']=digest(helper)
    metadata['pae_flow_revision']='20260923-setup-end-pae-firstlogon-fallback-i18n-crashdump-off'
    manifest_path.write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_PAE_FLOW_REFRESHED; silent helper; PAE default timeout=0; read-only zero-file verification; other entries unchanged; no VM/E2E',flush=True)

def overlay(base, helper, driver_bundles):
    entries=parse_newc(gzip.decompress(base.read_bytes()))
    prefix='usr/lib/usos/'
    # Derive from a complete production image, but only emit an independent copy.
    stage=entries[prefix+'legacy_xp_staging.sh'].data.decode()
    start=stage.index('    TARGET_SIZE_FOR_BIOS=')
    end=stage.index('    # Validate and mount the selected source',start)
    stage=stage[:start]+'''    [ -d /sys/firmware/efi ] || stop 'This experiment requires UEFI preparation'
    [ -z "$XP_WINNT_SIF" ] || stop 'Experimental XP does not accept custom SIF files'
    [ ! -f "$TEST_INI" ] || stop 'Test auto-confirm is forbidden in this experiment'
    TARGET_SIZE_FOR_BIOS=$(usos_disk_size "$TARGET_DEVICE")
    # Canonical on-disk geometry, NOT a claim about firmware AH08 geometry.
    # The verified NT52 NTFS reader uses EDD; firmware CSM is used after poweroff.
    XP_BIOS_DRIVE=80
    XP_BIOS_CYLINDERS=1024
    XP_BIOS_HEADS=255
    XP_BIOS_SPT=63
    printf '[XP_UEFI_CSM] geometry=canonical-255-63; NT52=EDD-only; future-CSM-geometry=unknown\\n'

'''+stage[end:]
    # Experimental logs/state cannot collide with a working BIOS XP session.
    stage=stage.replace('/mnt/esp/EFI/USOS/', '/mnt/esp/EFI/USOS-XP/')
    stage=stage.replace('DEVICE_INI=/mnt/esp/EFI/USOS-XP/usos-device.ini','DEVICE_INI=/mnt/esp/EFI/USOS/usos-device.ini')
    stage=replace_once(stage,'    . /usr/lib/usos/nt5_profile.sh','    mkdir -p /mnt/esp/EFI/USOS-XP\n    . /usr/lib/usos/nt5_profile.sh')
    stage=replace_once(stage,"    XP_SOURCE_OPEN=yes",'''    . /usr/lib/usos/xp_driver_stage.sh
    usos_xp_driver_preflight || stop 'XP driver preflight failed; no target write occurred'
    XP_SOURCE_OPEN=yes''')
    put(entries,Entry(prefix+'legacy_xp_staging.sh',stat.S_IFREG|0o755,stage.encode()))
    ntfs=entries[prefix+'xp-nt52-ntfs.bin'].data
    if ntfs[212:221]!=bytes.fromhex('663B06200090909090'):raise ValueError('EDD-only NT52 template not present')
    put_pae_flow(entries,base_entries=entries,helper=helper)
    put(entries,Entry(prefix+'xp_driver_stage.sh',stat.S_IFREG|0o755,(ROOT/'tools/xp_driver_stage.sh').read_bytes()))
    for bundle_id,bundle in driver_bundles:
        for path in bundle.rglob('*'):
            if path.is_file():put(entries,Entry(prefix+'xp-drivers/'+bundle_id+'/'+path.relative_to(bundle).as_posix(),stat.S_IFREG|0o644,path.read_bytes()))
    vendor=ROOT/'tools/vendor/patchpae3/3e1d3b65f5c3c1ec0c4759f707d3017e51113103'
    credit=b'USOS XP PAE: adapted from evgen-b/PatchPAE3, commit 3e1d3b65f5c3c1ec0c4759f707d3017e51113103.\nhttps://github.com/evgen-b/PatchPAE3\nPatterns by evgen_b, based on wj32 and XP64G. USOS adds strict checks and separate output/boot entries.\n\n'
    put(entries,Entry(prefix+'xp-pae-LICENSE.txt',stat.S_IFREG|0o644,credit+(vendor/'LICENSE').read_bytes()))
    # No automatic test hooks from previous physical/VM test sessions.
    init=entries['usos-init'].data.decode()
    init=replace_once(init,'mount -t vfat -o rw,noatime "$ESP_PATH" /mnt/esp || stop \'cannot mount ESP\'', '''mount -t vfat -o rw,noatime "$ESP_PATH" /mnt/esp || stop 'cannot mount ESP'
[ "$LEGACY_ACTION" = xp-staging ] || stop 'Unexpected experimental action'
[ -d /sys/firmware/efi ] || stop 'UEFI required'
mkdir -p /mnt/esp/EFI/USOS-XP
''')
    init=init.replace('/mnt/esp/EFI/USOS/legacy-xp-staging-last-error.txt','/mnt/esp/EFI/USOS-XP/legacy-xp-staging-last-error.txt')
    put(entries,Entry('usos-init',stat.S_IFREG|0o755,init.encode()))
    return gzip.compress(newc(update_ui(entries)),compresslevel=6,mtime=0)

def rebuild_launchers():
    """Recompile launcher UI without rebuilding or changing the driver payload."""
    manifest_path=OUT/'manifest.json'
    metadata=json.loads(manifest_path.read_text())
    for name,expected in metadata['sha256'].items():
        if digest(OUT/name)!=expected:raise ValueError('Existing package hash mismatch: '+name)
    env=dict(os.environ,TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
    for index,name in enumerate(metadata['launchers']):
        source=OUT/f'build-{index}'
        # Config contains the ISO and ESP identity from the original build.
        if not (source/'xp_trial_config.zig').is_file():raise ValueError('Missing original launcher config')
        shutil.copyfile(ROOT/'tools/xp_uefi_csm_launcher.zig',source/'launcher.zig')
        subprocess.run([str(ROOT/'tools/zig/zig.exe'),'build-exe','-target','x86_64-uefi','-O','ReleaseSmall',str(source/'launcher.zig'),'-femit-bin='+str(OUT/name)],env=env,check=True)
        metadata['sha256'][name]=digest(OUT/name)
    metadata['launcher_ui']='automatic handoff to graphical disk selection; no console Enter prompt'
    manifest_path.write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_LAUNCHERS_BUILT; driver payload unchanged; no VM/E2E',flush=True)

def is_sp3(iso):
    # Microsoft names it "..._with_service_pack_3_...", others "SP3".
    name=iso.name.lower()
    return 'sp3' in name or 'service_pack_3' in name

def build(esp, data):
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'tmp').mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
    zig=str(ROOT/'tools/zig/zig.exe');helper=compile_helper(env)
    base=esp/'EFI/USOS/micro-linux/initramfs-usos';kernel=esp/'EFI/USOS/micro-linux/vmlinuz-virt'
    images=sorted((data/'Systems/Windows/Windows XP/Images').glob('*.iso'))
    if not images:raise ValueError('No XP ISO on DATA')
    # SP2 remains visible for historical compatibility but is refused before
    # any target write by the new runtime preflight. First hardware trial: SP3.
    supported=[p for p in images if is_sp3(p)]
    if not supported:raise ValueError('XP SP3 source required for modern driver integration')
    # One work folder per source ISO content (not per list position), so a
    # bundle always rebuilds from, and is checked against, its own source.
    sources=[{'name':p.name,'sha256':digest(p),'size':p.stat().st_size} for p in supported]
    driver_bundles=[build_driver_overlay(p,OUT/'drivers'/s['sha256']) for p,s in zip(supported,sources)]
    for s,(bundle_id,_) in zip(sources,driver_bundles):s['bundle']=bundle_id
    init=OUT/'initramfs-xp';init.write_bytes(overlay(base,helper,driver_bundles))
    shutil.copyfile(kernel,OUT/'vmlinuz.efi')
    config={}
    for line in (esp/'EFI/USOS/usos-device.ini').read_text().splitlines():
        if '=' in line:
            k,v=line.split('=',1);config[k]=v
    uuid=config['esp_partuuid']; assert len(uuid)==36 and all(c in '0123456789abcdefABCDEF-' for c in uuid)
    images=sorted((data/'Systems/Windows/Windows XP/Images').glob('*.iso'))
    if not images:raise ValueError('No XP ISO on DATA')
    launchers=[]
    for index,iso in enumerate(images):
        # No filename interpolation into shell; Linux receives hex UTF-8.
        options='initrd=\\EFI\\USOS-XP\\initramfs-xp rdinit=/usos-init usos.esp_partuuid='+uuid+' usos.legacy_action=xp-staging usos.legacy_image_hex='+iso.name.encode().hex()+' console=tty0 console=ttyS0,115200n8 rw quiet loglevel=1 fbcon=nodefer vt.global_cursor_default=0'
        source=OUT/f'build-{index}';source.mkdir(exist_ok=True)
        shutil.copyfile(ROOT/'tools/xp_uefi_csm_launcher.zig',source/'launcher.zig')
        (source/'xp_trial_config.zig').write_text('pub const options = '+json.dumps(options)+';\npub const description = '+json.dumps('Source: '+iso.name+'\r\n')+';\n',encoding='ascii')
        name=('XP-SP3-NiKKA' if 'NiKKA' in iso.name else 'XP-SP3' if is_sp3(iso) else 'XP-SP2')+'-UEFI-CSM-PAE.efi'
        if name in launchers:raise ValueError('Ambiguous trial launcher name')
        subprocess.run([zig,'build-exe','-target','x86_64-uefi','-O','ReleaseSmall',str(source/'launcher.zig'),'-femit-bin='+str(OUT/name)],env=env,check=True)
        launchers.append(name)
    metadata={'experimental':True,'driver_bundles':[n for n,_ in driver_bundles],'driver_supported_sources':[p.name for p in supported],'driver_sources':sources,'firmware':'UEFI preparation; XP through firmware CSM','hardware_verified':False,'base_initramfs_sha256':digest(base),'base_kernel_sha256':digest(kernel),'launchers':launchers,'iso_names':[i.name for i in images],'sha256':{p.name:digest(p) for p in [init,OUT/'vmlinuz.efi',helper,*[OUT/n for n in launchers]]}}
    (OUT/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print('XP_UEFI_CSM_TRIAL_BUILT; isolated initramfs; BIOS artifacts untouched; no VM/E2E',flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--esp',type=Path,default=Path('J:/'));p.add_argument('--data',type=Path,default=Path('L:/'));mode=p.add_mutually_exclusive_group();mode.add_argument('--menu-only',action='store_true');mode.add_argument('--launchers-only',action='store_true');mode.add_argument('--ui-only',action='store_true');mode.add_argument('--add-source',type=Path);mode.add_argument('--refresh-pae-flow',action='store_true');a=p.parse_args()
    if a.menu_only:
        env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'))
        subprocess.run([str(ROOT/'tools/zig/zig.exe'),'build','usos-x86_64','framebuffer-ui','test','-Doptimize=ReleaseFast','--cache-dir',str(ROOT/'tools/cache/zig')],cwd=ROOT,env=env,check=True)
        print('PASS: Zig UEFI menu build and Zig tests; no BIOS build or VM/E2E')
    elif a.launchers_only:rebuild_launchers()
    elif a.ui_only:rebuild_ui()
    elif a.add_source:add_driver_source(a.add_source)
    elif a.refresh_pae_flow:refresh_pae_flow(a.esp)
    else:build(a.esp,a.data)
