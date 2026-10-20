"""Read a stopped, keyless test ESP read-only; export generated logs/screens.

The collector boots Linux directly only for evidence, never for an OS PASS.
Its transport is serial base64 in RAM; no writable raw disk or host share.
"""
from pathlib import Path
import argparse
import asyncio
import base64
import importlib.util
import io
import json
import tarfile

ROOT=Path(__file__).resolve().parents[3]
ALLOWED_NAMES={'screen.ppm','command.txt','qemu.log','serial.log','seabios.log','monitor.log','runs.txt','POST.LOG'}
spec=importlib.util.spec_from_file_location('fixture',Path(__file__).with_name('prepare_stick.py'))
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)


def decode_transport(text):
    lines=text.splitlines()
    begin=next(i for i,line in enumerate(lines) if line.strip()=='COVERAGE_EVIDENCE_BEGIN')
    end=next(i for i,line in enumerate(lines[begin+1:],begin+1) if line.strip()=='COVERAGE_EVIDENCE_END')
    # The console echoes each command with its prompt. Preserve strict
    # base64 validation after removing only that known prompt prefix.
    encoded=''.join(line.strip() for line in lines[begin+1:end]
                    if line.strip() and not line.startswith('/tmp/export/nt4 # '))
    return base64.b64decode(encoded,validate=True)


def export_evidence(payload,output):
    saved=[]
    with tarfile.open(fileobj=io.BytesIO(payload),mode='r:gz') as archive:
        for member in archive.getmembers():
            name=Path(member.name)
            if not member.isfile() or name.is_absolute() or '..' in name.parts or member.size>8*1024**2 or name.name not in ALLOWED_NAMES:
                raise ValueError('Unexpected evidence archive entry')
            destination=output/name
            if not destination.resolve().is_relative_to(output.resolve()):
                raise ValueError('Evidence path outside output')
            destination.parent.mkdir(parents=True,exist_ok=True)
            data=archive.extractfile(member).read()
            if destination.suffix=='.ppm':
                from PIL import Image
                try:
                    with Image.open(io.BytesIO(data)) as frame:frame.save(destination.with_suffix('.png'))
                    destination=destination.with_suffix('.png')
                except (ValueError,OSError) as error:
                    destination=destination.with_suffix('.invalid.json')
                    destination.write_text(json.dumps(dict(bytes=len(data),error=type(error).__name__))+'\n')
            elif b'\0' in data:
                destination=destination.with_suffix('.invalid.json')
                destination.write_text(json.dumps(dict(bytes=len(data),error='non-text evidence rejected'))+'\n')
            else:
                destination.write_text(data.decode('utf-8',errors='replace'),encoding='utf-8',newline='\n')
            saved.append(str(destination.relative_to(output)))
    return saved


async def main(args):
    work=args.fixture.resolve()
    if not work.is_relative_to(fixture.COLLECTION/'_vm'):
        raise ValueError('Only owned VM fixtures')
    metadata=json.loads((work/'fixture.json').read_text(encoding='utf-8'))
    if metadata.get('private_profile'):
        raise ValueError('General log collection refuses keyed tests')
    if not args.out.resolve().is_relative_to(ROOT/'artifacts/coverage'):
        raise ValueError('Evidence must stay in owned coverage artifacts')
    args.out.mkdir(parents=True,exist_ok=False)
    fixture.check_resources(work,1024)
    commands=r'''
/bin/busybox --install -s /bin
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -e
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
for m in virtio_pci virtio_blk vfat fat; do modprobe "$m"; done
mdev -s
mkdir -p /tmp/export
# Read-only block device; mtools tolerates an incomplete directory entry
# left by a stopped emergency-shell run better than the kernel FAT walker.
MTOOLS_SKIP_CHECK=1 mcopy -i /dev/vda1 -s ::/EFI/USOS/win9x/nt4 /tmp/export/ || true
cd /tmp/export/nt4
items=$(find . -type f \( -name screen.ppm -o -name command.txt -o -name qemu.log -o -name serial.log -o -name seabios.log -o -name monitor.log -o -name runs.txt -o -name POST.LOG \))
[ -n "$items" ]
tar -czf /tmp/evidence.tgz $items
echo COVERAGE_EVIDENCE_BEGIN
base64 /tmp/evidence.tgz
echo COVERAGE_EVIDENCE_END
cd /
echo LOWRAM-RESULT=PASS
poweroff -f
'''
    result=await fixture.load_bootstrap().run_case(args.qemu,args.assets/'zig-out/micro-linux/vmlinuz-virt',
        args.assets/'zig-out/micro-linux/initramfs-usos',work/'read-logs-mtools',1024,'qemu64',180,
        ['-drive',f'file={(work/"stick.qcow2").as_posix()},format=qcow2,if=virtio,readonly=on'],
        commands=commands,suffix='-evidence')
    if result['result']!='PASS':raise RuntimeError('Read-only evidence VM failed; inspect its local serial log')
    payload=decode_transport((Path(result['directory'])/'serial.log').read_text(encoding='utf-8',errors='replace'))
    saved=export_evidence(payload,args.out)
    (args.out/'collection.json').write_text(json.dumps(dict(result=result,files=saved,scope='read-only stopped test evidence; not an OS boot test'),indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(collected=len(saved),directory=str(args.out))),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('qemu','assets','fixture','out'):parser.add_argument('--'+name,type=Path,required=True)
    asyncio.run(main(parser.parse_args()))
