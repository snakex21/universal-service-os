"""Create a new NT351-only experimental fixture cache, never boot a VM.

Preserve the base initrd byte-for-byte, append only owned payload overrides,
apply NT351 hunks to its actual scripts, and bind every new input to hashes.
This is not a full USOS release and carries no installed Windows PASS.
"""
from pathlib import Path
import argparse
import difflib
import gzip
import hashlib
import json
import shutil
import stat
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
BASE_INITRD='3cfcaee979bd6ab9ba59447b912b1ed8fbcea1b5aac75df7531eb8bd4f3fecd5'
BASE_COMMIT='b6411a14'
DRIVER_SHA='dc8827954e6fe75ee8264c7382e87899cc9761890998198c126c7ea8aa5c55b6'
LOGGER_SHA='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7'


def sha(data):return hashlib.sha256(data).hexdigest()


def owned_hunks(base, before, after):
    """Apply only a reviewed branch delta; keep unrelated cache additions.

    Every original context must occur exactly once. Line-number fuzz and
    silent fallback to the older full branch script are deliberately absent.
    """
    current=base.decode('utf-8').splitlines(keepends=True)
    diff=list(difflib.unified_diff(before.decode('utf-8').splitlines(keepends=True),
        after.decode('utf-8').splitlines(keepends=True),n=3))[2:]
    groups=[]
    for line in diff:
        if line.startswith('@@'):groups.append([])
        elif groups:groups[-1].append(line)
    for group in groups:
        old=[line[1:] for line in group if line[0] in ' -']
        new=[line[1:] for line in group if line[0] in ' +']
        if not old:raise ValueError('Empty source hunk context')
        positions=[i for i in range(len(current)-len(old)+1) if current[i:i+len(old)]==old]
        if len(positions)!=1:raise ValueError('NT351 hunk context absent or ambiguous in actual cache')
        i=positions[0];current[i:i+len(old)]=new
    return ''.join(current).encode('utf-8')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--efi',type=Path,required=True)
    parser.add_argument('--post-helper',type=Path,required=True)
    args=parser.parse_args()
    base=args.base.resolve();out=args.out.resolve()
    for path in (base,out):
        if not path.is_relative_to(COLLECTION/'_assets'):raise ValueError('Cache must stay in owned collection assets')
    if not base.is_dir() or out.exists() or out.is_relative_to(base):raise ValueError('Use existing base and fresh separate output')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('Less than100GiB free')
    sys.path.insert(0,str(ROOT/'tools'))
    from build_micro_linux import Entry,newc,parse_newc,put
    original=(base/'zig-out/micro-linux/initramfs-usos').read_bytes()
    if sha(original)!=BASE_INITRD:raise ValueError('Exact reviewed R15 base initrd required')
    entries=parse_newc(gzip.decompress(original));delta={};proof=[]
    for source in ('tools/nt4_csmwrap_target.sh','tools/nt4_qemu_install.sh','tools/w9x_csmwrap_prepare.sh'):
        name='usr/lib/usos/'+Path(source).name
        old=subprocess.check_output(['git','show',BASE_COMMIT+':'+source],cwd=ROOT).replace(b'\r\n',b'\n')
        current=(ROOT/source).read_bytes().replace(b'\r\n',b'\n')
        changed=owned_hunks(entries[name].data,old,current)
        # Preserve the actual cache's later NT4 storage integration.
        for marker in (b'NT4_USB_STORAGE',b'usb_storage_dword',b'USOSUSB.LOG'):
            if marker in entries[name].data and marker not in changed:raise ValueError('NT4 cache feature removed')
        put(delta,Entry(name,stat.S_IFREG|0o755,changed))
        proof.append({'entry':name,'base_sha256':sha(entries[name].data),'branch_source_sha256':sha(current),
            'effective_sha256':sha(changed),'method':'Unique context NT351 hunks over actual cache; unrelated base preserved'})
    source_payloads={
        'usr/lib/usos/nt351_network_setup.sh':ROOT/'tools/nt351_network_setup.sh',
        'usr/lib/usos/nt3/USOSNT3.EXE':args.post_helper.resolve(),
        'usr/lib/usos/nt3/USOSNET351.SYS':ROOT/'tools/nt/usosnet/bin/i386/usosnet351.sys',
        'usr/lib/usos/nt3/USOSLOG351.EXE':ROOT/'tools/nt3/usoslog/bin/i386/usoslog.exe',
    }
    for name,path in source_payloads.items():
        if not path.is_relative_to(ROOT):raise ValueError('Only owned worktree payloads')
        data=path.read_bytes()
        if path.suffix=='.sh':data=data.replace(b'\r\n',b'\n')
        if name.endswith('USOSNET351.SYS') and sha(data)!=DRIVER_SHA:raise ValueError('Driver hash mismatch')
        if name.endswith('USOSLOG351.EXE') and sha(data)!=LOGGER_SHA:raise ValueError('NT3 logger hash mismatch')
        put(delta,Entry(name,stat.S_IFREG|(0o755 if path.suffix=='.sh' else 0o644),data))
        proof.append({'entry':name,'source':str(path.relative_to(ROOT)),'sha256':sha(data),'bytes':len(data)})
    for leaf,digest in (('USOSNET351',DRIVER_SHA),('USOSLOG351',LOGGER_SHA)):
        extension='SYS' if leaf=='USOSNET351' else 'EXE'
        name='usr/lib/usos/nt3/'+leaf+'.SHA256'
        put(delta,Entry(name,stat.S_IFREG|0o644,(digest+'  '+leaf+'.'+extension+'\n').encode('ascii')))
    overlay=gzip.compress(newc(delta),compresslevel=9,mtime=0)
    verify=parse_newc(gzip.decompress(overlay))
    if any(verify[name].data!=entry.data for name,entry in delta.items()):raise ValueError('Overlay readback differs')
    efi=args.efi.resolve()
    if not efi.is_relative_to(ROOT) or not efi.read_bytes().startswith(b'MZ'):raise ValueError('Own rebuilt UEFI required')
    # All checks above are read-only. Create the complete new cache now.
    shutil.copytree(base,out)
    initrd=out/'zig-out/micro-linux/initramfs-usos'
    initrd.write_bytes(original+b'\0'*(-len(original)%4)+overlay)
    shutil.copyfile(efi,out/'zig-out/bin/usos-x86_64.efi')
    report={'scope':'NT351-only experimental fixture cache; not full USOS release or installed Windows PASS',
        'base':str(base),'output':str(out),'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'base_initrd_sha256':sha(original),'initrd_sha256':sha(initrd.read_bytes()),'overlay_sha256':sha(overlay),
        'base_prefix_preserved':initrd.read_bytes()[:len(original)]==original,
        'efi':{'source':str(efi.relative_to(ROOT)),'sha256':sha(efi.read_bytes()),
            'caveat':'Own renderer rebuild; base EFI source commit is unavailable locally, no claim of whole-release equivalence'},
        'verified_entries':proof,'runtime_pass':False,'r17_modified':False,
        'logger_command':r'C:\USOS\NT3\USOSLOG.EXE /once /nohook /nodbg /out C:\USOS\NT3\USABILITY.TXT',
        'note':'Preserves all other base files. Original Microsoft media is supplied separately by the next keyless fixture.'}
    (out/'nt351-inputs.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    artifact=ROOT/'artifacts/nt351-network/next-cache-manifest.json'
    artifact.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'output':str(out),'initrd_sha256':report['initrd_sha256'],'runtime_pass':False},indent=2))


if __name__=='__main__':main()
