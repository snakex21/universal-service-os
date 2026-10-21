"""Read only five own NT351 diagnostics and hash the own installed driver.

The outer VM must already have ended. This is evidence collection, never an
installed-Windows, USB or network PASS. No registry hives or OS files leave VM.
"""
from pathlib import Path
import argparse
import asyncio
import base64
import importlib.util
import io
import json
import re
import tarfile

spec=importlib.util.spec_from_file_location('nt351_serial_shell',Path(__file__).with_name('serial_shell.py'))
serial_shell=importlib.util.module_from_spec(spec);spec.loader.exec_module(serial_shell)
spec=importlib.util.spec_from_file_location('nt351_archive_policy',Path(__file__).with_name('evidence_archive.py'))
archive_policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(archive_policy)

FOLDERS=frozenset(('Windows NT 3.51','Windows NT 3.51 Server'))
FILES=('NET351.STATUS','NET351.ON','USABILITY.TXT','POST.LOG','USOSNET351.SHA256')
DRIVER_SHA256='dc8827954e6fe75ee8264c7382e87899cc9761890998198c126c7ea8aa5c55b6'
DRIVER_BYTES=17024
MAX_FILE=1024**2
MAX_TOTAL=5*MAX_FILE+4096
MAX_TRANSPORT=8*1024**2


def validate(metadata,work,assets,output,collection,root,require_target=True):
    if metadata.get('private_profile') is not False or metadata.get('folder') not in FOLDERS:
        raise ValueError('Only explicitly keyless allowlisted NT351 fixtures may be collected')
    work=work.resolve();assets=assets.resolve();output=output.resolve()
    if not work.is_relative_to(collection.resolve()/'_vm') or work==collection.resolve()/'_vm':
        raise ValueError('Only an owned disposable target may be read')
    if not assets.is_relative_to(collection.resolve()/'_assets') or assets==collection.resolve()/'_assets':
        raise ValueError('An explicit owned frozen cache is required')
    if not output.is_relative_to(root.resolve()/'artifacts/coverage'):
        raise ValueError('Evidence must remain in owned coverage artifacts')
    if require_target and not (work/'target.qcow2').is_file():raise FileNotFoundError('Stopped owned target is absent')


def commands():
    # Only these constant paths are passed to mtools. dd bounds even a corrupt
    # directory entry; the block device itself is attached readonly=on.
    reads=[]
    for name in FILES:
        reads.append(f'''if MTOOLS_SKIP_CHECK=1 mdir -i "$disk" ::/USOS/NT3/{name} >/dev/null 2>&1; then
 MTOOLS_SKIP_CHECK=1 mtype -i "$disk" ::/USOS/NT3/{name} | dd bs=1 count={MAX_FILE+1} of=/tmp/export/{name} 2>/dev/null
 [ "$(wc -c </tmp/export/{name})" -le {MAX_FILE} ]
fi''')
    return '''/bin/busybox --install -s /bin
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -e
set -o pipefail
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
for m in virtio_pci virtio_blk vfat fat; do modprobe "$m"; done
mdev -s
mkdir -p /tmp/export
disk=/dev/vda@@32256
'''+ '\n'.join(reads)+f'''
if MTOOLS_SKIP_CHECK=1 mdir -i "$disk" ::/WINNT/SYSTEM32/DRIVERS/usosnet351.sys >/dev/null 2>&1; then
 MTOOLS_SKIP_CHECK=1 mtype -i "$disk" ::/WINNT/SYSTEM32/DRIVERS/usosnet351.sys | dd bs=1 count={DRIVER_BYTES+1} of=/tmp/own-driver 2>/dev/null
 [ "$(wc -c </tmp/own-driver)" -eq {DRIVER_BYTES} ]
 digest=$(sha256sum /tmp/own-driver); digest=${{digest%% *}}
 printf '%s\\n' "$digest" >/tmp/export/DRIVER-READBACK.SHA256
 rm /tmp/own-driver
fi
cd /tmp/export
tar -czf /tmp/evidence.tgz .
echo NT351_OWN_EVIDENCE_BEGIN
base64 /tmp/evidence.tgz
echo NT351_OWN_EVIDENCE_END
cd /
echo LOWRAM-RESULT=PASS
poweroff -f
'''


def decode_transport(text):
    if len(text)>MAX_TRANSPORT:raise ValueError('Transport byte limit exceeded')
    lines=text.splitlines()
    begin=[i for i,v in enumerate(lines) if v.strip()=='NT351_OWN_EVIDENCE_BEGIN']
    end=[i for i,v in enumerate(lines) if v.strip()=='NT351_OWN_EVIDENCE_END']
    if len(begin)!=1 or len(end)!=1 or end[0]<=begin[0]:raise ValueError('Missing or ambiguous transport boundary')
    encoded=''.join(v.strip() for v in lines[begin[0]+1:end[0]]
                    if v.strip() and not v.startswith('/tmp/export # '))
    payload=base64.b64decode(encoded,validate=True)
    if len(payload)>MAX_TOTAL+65536:raise ValueError('Archive limit exceeded')
    return payload


def export_evidence(payload,output):
    # Validate the entire archive before writing anything. No extractall,
    # permissive basenames, traversal, duplicate members or binary logs.
    records={};total=0
    plain=archive_policy.single_gzip(payload,MAX_TOTAL+65536)
    with tarfile.open(fileobj=io.BytesIO(plain),mode='r:') as archive:
        for member in archive:
            if member.name in ('.','./') and member.isdir():continue
            name=member.name.removeprefix('./')
            if not member.isfile() or name not in (*FILES,'DRIVER-READBACK.SHA256') or name in records:
                raise ValueError('Unexpected or duplicate evidence path')
            if member.size>MAX_FILE or member.size<0:raise ValueError('Evidence file limit exceeded')
            total+=member.size
            if total>MAX_TOTAL:raise ValueError('Evidence total limit exceeded')
            data=archive.extractfile(member).read(MAX_FILE+1)
            if len(data)!=member.size or b'\0' in data:raise ValueError('Invalid text evidence')
            records[name]=data.decode('utf-8',errors='strict')
        archive_policy.tar_end(plain,archive.offset)
    digest=records.pop('DRIVER-READBACK.SHA256',None)
    if digest is not None:
        digest=digest.strip()
        if not re.fullmatch('[a-f0-9]{64}',digest):raise ValueError('Invalid driver readback digest')
    output.mkdir(parents=True,exist_ok=False)
    for name,data in records.items():(output/name).write_text(data,encoding='utf-8',newline='\n')
    return dict(files=sorted(records),missing=[name for name in FILES if name not in records],
        driver_readback_sha256=digest,expected_driver_sha256=DRIVER_SHA256,
        driver_hash_matches=digest==DRIVER_SHA256,installed_runtime_pass=False,
        scope='Own stopped-target evidence only; file/status presence is not runtime PASS')


async def main(args):
    root=Path(__file__).resolve().parents[3]
    spec=importlib.util.spec_from_file_location('fixture',Path(__file__).with_name('prepare_stick.py'))
    fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
    work=args.fixture.resolve()
    metadata=json.loads((work/'fixture.json').read_text(encoding='utf-8'))
    validate(metadata,work,args.assets,args.out,fixture.COLLECTION,root)
    if args.out.exists():raise FileExistsError(args.out)
    fixture.check_resources(work,1024)
    result=await fixture.load_bootstrap().run_case(args.qemu,args.assets/'zig-out/micro-linux/vmlinuz-virt',
        args.assets/'zig-out/micro-linux/initramfs-usos',work/'read-nt351-own',1024,'qemu64',180,
        ['-drive',f'file={(work/"target.qcow2").as_posix()},format=qcow2,if=virtio,readonly=on'],
        commands=serial_shell.wrap(commands()),suffix='-nt351-own')
    if result['result']!='PASS':raise RuntimeError('Read-only collector failed; no runtime assessment')
    serial=Path(result['directory'])/'serial.log'
    if serial.stat().st_size>MAX_TRANSPORT:raise ValueError('Transport byte limit exceeded')
    evidence=export_evidence(decode_transport(serial.read_text(encoding='utf-8',errors='strict')),args.out)
    evidence['collector_result']=result
    (args.out/'collection.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(collected=len(evidence['files']),directory=str(args.out),installed_runtime_pass=False)),flush=True)
    return evidence


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('qemu','assets','fixture','out'):parser.add_argument('--'+name,type=Path,required=True)
    asyncio.run(main(parser.parse_args()))
