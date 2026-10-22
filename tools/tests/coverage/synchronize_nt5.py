"""Create a private, synchronized NT5 fixture from frozen production inputs.

Production packages use the micro-Linux base plus package-specific payloads
(build_xp_uefi_csm_trial.py). Copy those payloads unchanged from the older
package, including all source-bound drivers. Do not compile or change them.
This is a separate test input, never a release or an edit to the old cache.
"""
from pathlib import Path
import argparse
import gzip
import hashlib
import importlib.util
import json
import shutil

ROOT=Path(__file__).resolve().parents[3]
COLLECTION=Path('G:/USOS-Kolekcja').resolve()
spec=importlib.util.spec_from_file_location('cpio',ROOT/'tools/build_micro_linux.py')
cpio=importlib.util.module_from_spec(spec);spec.loader.exec_module(cpio)
ENTRIES={'usr/lib/usos/xp-pae.exe','usr/lib/usos/xp-pae-LICENSE.txt'}
PREFIXES=('usr/lib/usos/xp-drivers','usr/lib/usos/nt5-storage',
          'usr/lib/usos/nt52-usb','usr/lib/usos/w2k-drivers')


def package_entry(name):
    return name in ENTRIES or any(name==p or name.startswith(p+'/') for p in PREFIXES)


def combine(base,old):
    if 'usr/lib/usos/xp_user_settings.sh' not in base:
        raise ValueError('Missing base settings parser')
    if not ENTRIES.issubset(old):raise ValueError('Missing unchanged package helper')
    result=dict(base)
    result.update({name:value for name,value in old.items() if package_entry(name)})
    return result


def fingerprint(entry):
    return entry.mode,hashlib.sha256(entry.data).hexdigest()


def main(args):
    source=args.source.resolve();out=args.out.resolve()
    allowed=COLLECTION/'_assets'
    if not source.is_relative_to(allowed) or not out.is_relative_to(allowed):
        raise ValueError('Both caches must be inside the owned _assets directory')
    if out.exists():raise FileExistsError('Refusing an existing output cache')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise RuntimeError('Less than 100 GiB free')
    basepath=source/'zig-out/micro-linux/initramfs-usos'
    oldpath=source/'zig-out/xp-uefi-csm/initramfs-xp'
    base=cpio.parse_newc(gzip.decompress(basepath.read_bytes()))
    old=cpio.parse_newc(gzip.decompress(oldpath.read_bytes()))
    entries=combine(base,old)
    packed=cpio.pad_initrd(gzip.compress(cpio.newc(entries),compresslevel=6,mtime=0))
    checked=cpio.parse_newc(gzip.decompress(packed))
    if {n:fingerprint(e) for n,e in checked.items()}!={n:fingerprint(e) for n,e in entries.items()}:
        raise ValueError('Archive round-trip changed content or modes')
    shutil.copytree(source,out)
    target=out/'zig-out/xp-uefi-csm'
    (target/'initramfs-xp').write_bytes(packed)
    shutil.copyfile(source/'zig-out/micro-linux/vmlinuz-virt',target/'vmlinuz.efi')
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    manifest=target/'manifest.json'
    data=json.loads(manifest.read_text(encoding='utf-8'))
    data['base_initramfs_sha256']=digest(basepath)
    data['base_kernel_sha256']=digest(source/'zig-out/micro-linux/vmlinuz-virt')
    data['sha256']['initramfs-xp']=digest(target/'initramfs-xp')
    data['sha256']['vmlinuz.efi']=digest(target/'vmlinuz.efi')
    data['hardware_verified']=False
    manifest.write_text(json.dumps(data,indent=2),encoding='utf-8')
    evidence={'source':str(source),'output':str(out),'old_initrd_sha256':digest(oldpath),
        'new_initrd_sha256':digest(target/'initramfs-xp'),'base_initrd_sha256':digest(basepath),
        'package_entries_preserved':sum(package_entry(n) for n in old),
        'base_entries':len(base),'base_changes':sorted(n for n,e in base.items()
            if not package_entry(n) and (n not in old or fingerprint(e)!=fingerprint(old[n]))),
        'invariants':'Every package-specific entry unchanged; every other entry exactly from the frozen production base. Kernel copied from that same base.',
        'release':False}
    (out/'nt5-synchronization.json').write_text(json.dumps(evidence,indent=2),encoding='utf-8')
    args.evidence.write_text(json.dumps(evidence,indent=2),encoding='utf-8')
    print('Synchronized private fixture cache; all package-specific entries preserved',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('source','out','evidence'):parser.add_argument('--'+name,type=Path,required=True)
    main(parser.parse_args())
