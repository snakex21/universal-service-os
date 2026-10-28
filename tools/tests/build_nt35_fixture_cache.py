"""Create a new NT35-only experimental fixture cache, never boot a VM.

Preserve the base initrd byte-for-byte, append only owned payload overrides,
apply NT35 hunks to its actual scripts, and bind every new input to hashes.
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
BASE_INITRD='ea7c1f59537bc0c8ba7eb518bde5cbd41d327067529e417a6d4401d9efd13aca'
BASE_COMMIT='b762b240'
DRIVER_SHA='e1aa69a3ec8e3da802013131abbb6fefc9f466da6f4eeb66fe15ec47e60421c5'
POST_SHA='8ab10c79cbbdab08c7f6d722219cbf14e034df9cb798739fdae3e64fab477024'
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
        if len(positions)!=1:raise ValueError('NT35 hunk context absent or ambiguous in actual cache')
        i=positions[0];current[i:i+len(old)]=new
    return ''.join(current).encode('utf-8')


def effective_newc(data):
    """Read all concatenated newc layers, matching the kernel archive order.

    https://www.kernel.org/doc/html/latest/driver-api/early-userspace/buffer-format.html
    The frozen base is hash-verified before this parser is used.
    """
    if len(data)>1024**3:raise ValueError('Decompressed cache exceeds bound')
    import importlib.util
    spec=importlib.util.spec_from_file_location('own_cpio',ROOT/'tools/build_micro_linux.py')
    cpio=importlib.util.module_from_spec(spec);sys.modules[spec.name]=cpio;spec.loader.exec_module(cpio)
    offset=0;entries={};layers=0;members=0
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
        if not trailer:raise ValueError('Frozen cache layer must have explicit trailer')
        layers+=1
        if layers>16:raise ValueError('Cpio layer bound exceeded')
        entries.update(cpio.parse_newc(data[start:offset]))
    if not layers:raise ValueError('No cache layers')
    return entries,layers


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
    if sha(original)!=BASE_INITRD:raise ValueError('Exact reviewed NT351 net2 base initrd required')
    entries,layers=effective_newc(gzip.decompress(original));delta={};proof=[]
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
            'effective_sha256':sha(changed),'method':'Unique context NT35 hunks over actual cache; unrelated base preserved'})
    source_payloads={
        'usr/lib/usos/nt35_network_setup.sh':ROOT/'tools/nt35_network_setup.sh',
        'usr/lib/usos/nt3/USOSNT3.EXE':args.post_helper.resolve(),
        'usr/lib/usos/nt3/USOSNET35.SYS':ROOT/'tools/nt/usosnet/bin/i386/usosnet35.sys',
        'usr/lib/usos/nt3/USOSLOG35.EXE':ROOT/'tools/nt3/usoslog/bin/i386/usoslog.exe',
    }
    for name,path in source_payloads.items():
        if not path.is_relative_to(ROOT):raise ValueError('Only owned worktree payloads')
        data=path.read_bytes()
        if path.suffix=='.sh':data=data.replace(b'\r\n',b'\n')
        if name.endswith('USOSNT3.EXE') and sha(data)!=POST_SHA:raise ValueError('Posthelper hash mismatch')
        if name.endswith('USOSNET35.SYS') and sha(data)!=DRIVER_SHA:raise ValueError('Driver hash mismatch')
        if name.endswith('USOSLOG35.EXE') and sha(data)!=LOGGER_SHA:raise ValueError('NT3 logger hash mismatch')
        put(delta,Entry(name,stat.S_IFREG|(0o755 if path.suffix=='.sh' else 0o644),data))
        proof.append({'entry':name,'source':str(path.relative_to(ROOT)),'sha256':sha(data),'bytes':len(data)})
    for leaf,digest in (('USOSNET35',DRIVER_SHA),('USOSLOG35',LOGGER_SHA)):
        extension='SYS' if leaf=='USOSNET35' else 'EXE'
        name='usr/lib/usos/nt3/'+leaf+'.SHA256'
        put(delta,Entry(name,stat.S_IFREG|0o644,(digest+'  '+leaf+'.'+extension+'\n').encode('ascii')))
    overlay=gzip.compress(newc(delta),compresslevel=9,mtime=0)
    verify=parse_newc(gzip.decompress(overlay))
    if any(verify[name].data!=entry.data for name,entry in delta.items()):raise ValueError('Overlay readback differs')
    efi=args.efi.resolve()
    if not efi.is_relative_to(ROOT) or not efi.read_bytes().startswith(b'MZ'):raise ValueError('Own rebuilt UEFI required')
    if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip():
        raise ValueError('Commit reviewed tracked integration before creating the cache')
    # All checks above are read-only. Create the complete new cache now.
    shutil.copytree(base,out)
    initrd=out/'zig-out/micro-linux/initramfs-usos'
    initrd.write_bytes(original+b'\0'*(-len(original)%4)+overlay)
    shutil.copyfile(efi,out/'zig-out/bin/usos-x86_64.efi')
    effective,total_layers=effective_newc(gzip.decompress(initrd.read_bytes()))
    expected=dict(entries);expected.update(delta)
    if set(effective)!=set(expected) or any(effective[n].data!=e.data or effective[n].mode!=e.mode for n,e in expected.items()):
        raise ValueError('Full effective overlay readback differs')
    report={'scope':'NT35-only experimental fixture cache; not full USOS release or installed Windows PASS',
        'base':str(base),'output':str(out),'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'base_cpio_layers':layers,'final_cpio_layers':total_layers,'effective_entries':len(effective),'full_effective_readback':True,'base_initrd_sha256':sha(original),'initrd_sha256':sha(initrd.read_bytes()),'overlay_sha256':sha(overlay),
        'base_prefix_preserved':initrd.read_bytes()[:len(original)]==original,
        'efi':{'source':str(efi.relative_to(ROOT)),'sha256':sha(efi.read_bytes()),
            'caveat':'Own renderer rebuild; base EFI source commit is unavailable locally, no claim of whole-release equivalence'},
        'verified_entries':proof,'runtime_pass':False,'r17_modified':False,
        'logger_command':r'C:\USOS\NT3\USOSLOG.EXE /once /nohook /nodbg /out C:\USOS\NT3\USABILITY.TXT',
        'note':'Preserves all other base files. Original Microsoft media is supplied separately by the next keyless fixture.'}
    (out/'nt35-inputs.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    artifact=ROOT/'artifacts/nt35-network/next-cache-manifest.json'
    artifact.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'output':str(out),'initrd_sha256':report['initrd_sha256'],'runtime_pass':False},indent=2))


if __name__=='__main__':main()
