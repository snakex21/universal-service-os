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
archive_policy=module('native_text_archive',Path(__file__).with_name('evidence_archive.py'))
fixture=module('native_text_fixture',Path(__file__).with_name('prepare_stick.py'))
transport=module('native_text_transport',Path(__file__).with_name('collect_guest_logs.py'))
LOGS=('setuplog.txt','setuperr.txt','setupact.txt','post.txt')
NAMES=set(LOGS)|{'collection-state.txt'}
STATUSES={'exported','empty','unavailable','too-large'}
MAX_ARCHIVE_PLAIN=len(NAMES)*2*1024**2+65536
STATE_HEADER='Sanitized Setup text; unavailable means read failed and source existence is unknown.'
SANITIZER=r'''LC_ALL=C tr -cd '\11\12\15\40-\176' | sed -E 's/[[:alnum:]]{5}(-[[:alnum:]]{5}){4}/[key omitted]/g; s/[0-9]{3,}/[number omitted]/g' '''
READLOG=r'''readlog() {
    rm -f /tmp/raw/log "/tmp/export/nt4/$2"
    status=unavailable
    if MTOOLS_SKIP_CHECK=1 mcopy -i /dev/vda@@32256 "::$1" /tmp/raw/log 2>/dev/null; then
        if [ "$(wc -c < /tmp/raw/log)" -gt 2097152 ]; then
            status=too-large
        else
            cat /tmp/raw/log | SANITIZE > "/tmp/export/nt4/$2"
            if [ "$(wc -c < "/tmp/export/nt4/$2")" -gt 2097152 ]; then
                rm -f "/tmp/export/nt4/$2"
                status=too-large
            elif [ -s "/tmp/export/nt4/$2" ]; then
                status=exported
            else
                status=empty
            fi
        fi
    fi
    rm -f /tmp/raw/log
    printf '%s=%s\n' "$2" "$status" >> /tmp/export/nt4/collection-state.txt
}'''


def log_status(text):
    lines=text.splitlines()
    if not lines or lines[0]!=STATE_HEADER:
        raise ValueError('Unexpected NT4 text evidence status')
    statuses={}
    for line in lines[1:]:
        pair=line.split('=')
        if len(pair)!=2 or pair[0] not in LOGS or pair[1] not in STATUSES or pair[0] in statuses:
            raise ValueError('Unexpected NT4 text evidence status')
        statuses[pair[0]]=pair[1]
    if set(statuses)!=set(LOGS):raise ValueError('Incomplete NT4 text evidence status')
    return statuses


def export_text(payload,directory):
    # Canonical base64 still permits multiple gzip members inside one frame.
    # Bound expansion and verify one member's EOF/CRC before parsing any tar.
    plain=archive_policy.single_gzip(payload,MAX_ARCHIVE_PLAIN)
    entries={}
    with tarfile.open(fileobj=io.BytesIO(plain),mode='r:') as archive:
        for member in archive.getmembers():
            # BusyBox tar's single ./ prefix is allowed; all other path syntax
            # and collisions are rejected by the same exact basename allowlist.
            name=member.name[2:] if member.name.startswith('./') else member.name
            if not member.isfile() or name not in NAMES or name in entries or member.size>2*1024**2:
                raise ValueError('Unexpected NT4 text evidence entry')
            data=archive.extractfile(member).read()
            text=data.decode('ascii')
            if re.search(r'[^\t\n\r\x20-\x7e]|[0-9]{3,}|[A-Za-z0-9]{5}(?:-[A-Za-z0-9]{5}){4}',text):
                raise ValueError('Evidence guest did not sanitize text; no raw data saved')
            entries[name]=text
        # BusyBox and Python tar both terminate with at least two zero blocks.
        # A second tar or unvalidated nonzero trailer must not be ignored.
        archive_policy.tar_end(plain,archive.offset)
    if 'collection-state.txt' not in entries:raise ValueError('Missing NT4 text evidence status')
    statuses=log_status(entries['collection-state.txt'])
    for name,status in statuses.items():
        if status in {'exported','empty'}:
            if name not in entries or bool(entries[name])!=(status=='exported'):
                raise ValueError('NT4 text evidence disagrees with its status')
        elif name in entries:
            raise ValueError('NT4 text evidence disagrees with its status')
    # Validate the entire archive before saving even sanitized entries.
    for name,text in entries.items():
        (directory/name).write_text(text,encoding='utf-8',newline='\n')
    actual=[name for name in LOGS if statuses[name]=='exported']
    return dict(files=list(entries),log_status=statuses,actual_native_logs=actual,
        native_logs_read=bool(actual),
        evidence_result='native-text-exported' if actual else 'no-native-text-exported')


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
printf '%s\n' 'STATE_HEADER' > /tmp/export/nt4/collection-state.txt
READLOG_FUNCTION
readlog /WINNT/SETUPLOG.TXT setuplog.txt
readlog /WINNT/SETUPERR.LOG setuperr.txt
readlog /WINNT/SETUPACT.LOG setupact.txt
readlog /USOS/NT4/POST.LOG post.txt
cd /tmp/export/nt4
tar -czf /tmp/evidence.tgz ./*.txt
echo COVERAGE_EVIDENCE_BEGIN
base64 /tmp/evidence.tgz
echo COVERAGE_EVIDENCE_END
cd /
echo LOWRAM-RESULT=PASS
poweroff -f
'''.replace('READLOG_FUNCTION',READLOG).replace('SANITIZE',SANITIZER).replace('STATE_HEADER',STATE_HEADER)
    result=await fixture.load_bootstrap().run_case(args.qemu,args.assets/'zig-out/micro-linux/vmlinuz-virt',
        args.assets/'zig-out/micro-linux/initramfs-usos',work/'read-native-text',1024,'qemu64',180,
        ['-drive',f'file={(work/"target.qcow2").as_posix()},format=qcow2,if=virtio,readonly=on'],
        commands=transport.serial_shell.wrap(commands),suffix='-nt4-text')
    if result['result']!='PASS':raise RuntimeError('Read-only text evidence VM failed')
    payload=transport.decode_transport((Path(result['directory'])/'serial.log').read_text(encoding='utf-8',errors='replace'))
    evidence=export_text(payload,args.out)
    evidence['scope']='Sanitized ASCII Setup text only; no OS or device PASS'
    (args.out/'collection.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print('NT4_NATIVE_TEXT_COLLECTION_COMPLETE result='+evidence['evidence_result']+
        ' native_logs='+str(len(evidence['actual_native_logs'])),flush=True)
