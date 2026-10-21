"""Export sanitized native NT4 Setup text from a stopped disposable target.

Only four explicit log names; no screen, registry hive, answer or key file.
ASCII projection and key/number redaction happen inside the evidence guest,
before base64 reaches any host log. This is diagnostic evidence, not PASS.
"""
from pathlib import Path
import asyncio
import importlib.util
import io
import json
import re
import tarfile

ROOT=Path(__file__).resolve().parents[3]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
fixture=module('native_text_fixture',Path(__file__).with_name('prepare_stick.py'))
transport=module('native_text_transport',Path(__file__).with_name('collect_guest_logs.py'))
NAMES={'setuplog.txt','setuperr.txt','post.txt','setupact.txt','collection-state.txt'}
SANITIZER=r'''LC_ALL=C tr -cd '\11\12\15\40-\176' | sed -E 's/[[:alnum:]]{5}(-[[:alnum:]]{5}){4}/[key omitted]/g; s/[0-9]{3,}/[number omitted]/g' '''


def export_text(payload,directory):
    saved=[]
    with tarfile.open(fileobj=io.BytesIO(payload),mode='r:gz') as archive:
        for member in archive.getmembers():
            if not member.isfile() or member.name not in NAMES or member.size>2*1024**2:
                raise ValueError('Unexpected NT4 text evidence entry')
            data=archive.extractfile(member).read()
            text=data.decode('ascii')
            if '\0' in text or re.search(r'[0-9]{3,}|[A-Za-z0-9]{5}(?:-[A-Za-z0-9]{5}){4}',text):
                raise ValueError('Evidence guest did not sanitize text; no raw data saved')
            (directory/member.name).write_text(text,encoding='utf-8',newline='\n')
            saved.append(member.name)
    return saved


async def main(args):
    work=args.fixture.resolve()
    if not work.is_relative_to(fixture.COLLECTION/'_vm') or args.assets is None:
        raise ValueError('Owned stopped fixture and explicit frozen assets required')
    metadata=json.loads((work/'fixture.json').read_text(encoding='utf-8'))
    if metadata.get('folder')!='Windows NT 4.0':raise ValueError('Native text collector is NT4 only')
    if not args.assets.resolve().is_relative_to(fixture.COLLECTION/'_assets'):
        raise ValueError('Evidence kernel outside owned frozen inputs')
    if not args.out.resolve().is_relative_to(ROOT/'artifacts/coverage'):
        raise ValueError('Evidence outside owned artifacts')
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
mkdir -p /tmp/raw /tmp/export/nt4
readlog() {
    MTOOLS_SKIP_CHECK=1 mcopy -i /dev/vda@@32256 "::$1" /tmp/raw/log 2>/dev/null || return 0
    [ "$(wc -c < /tmp/raw/log)" -le 2097152 ] || { rm -f /tmp/raw/log; return 0; }
    cat /tmp/raw/log | SANITIZE > "/tmp/export/nt4/$2"
    rm -f /tmp/raw/log
}
readlog /WINNT/SETUPLOG.TXT setuplog.txt
readlog /WINNT/SETUPERR.LOG setuperr.txt
readlog /WINNT/SETUPACT.LOG setupact.txt
readlog /USOS/NT4/POST.LOG post.txt
printf 'Only selected Setup text logs; ASCII projection; key-like strings and numeric runs omitted. No images, answers or registry.\n' > /tmp/export/nt4/collection-state.txt
cd /tmp/export/nt4
tar -czf /tmp/evidence.tgz ./*.txt
echo COVERAGE_EVIDENCE_BEGIN
base64 /tmp/evidence.tgz
echo COVERAGE_EVIDENCE_END
cd /
echo LOWRAM-RESULT=PASS
poweroff -f
'''.replace('SANITIZE',SANITIZER)
    result=await fixture.load_bootstrap().run_case(args.qemu,args.assets/'zig-out/micro-linux/vmlinuz-virt',
        args.assets/'zig-out/micro-linux/initramfs-usos',work/'read-native-text',1024,'qemu64',180,
        ['-drive',f'file={(work/"target.qcow2").as_posix()},format=qcow2,if=virtio,readonly=on'],
        commands=commands,suffix='-nt4-text')
    if result['result']!='PASS':raise RuntimeError('Read-only text evidence VM failed')
    payload=transport.decode_transport((Path(result['directory'])/'serial.log').read_text(encoding='utf-8',errors='replace'))
    # BusyBox tar emits ./basename; remove exactly that harmless prefix.
    clean=io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(payload),mode='r:gz') as source,tarfile.open(fileobj=clean,mode='w:gz') as target:
        for member in source.getmembers():
            if member.name.startswith('./'):member.name=member.name[2:]
            target.addfile(member,source.extractfile(member) if member.isfile() else None)
    files=export_text(clean.getvalue(),args.out)
    (args.out/'collection.json').write_text(json.dumps(dict(files=files,scope='Sanitized ASCII Setup text only; no OS or device PASS'),indent=2)+'\n',encoding='utf-8')
    print('NT4_NATIVE_TEXT_COLLECTION_COMPLETE files='+str(len(files)),flush=True)
