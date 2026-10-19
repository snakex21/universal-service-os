"""Real BusyBox staging smoke test; Linux RAM only, synthetic files, no disks.

Pass existing --kernel, --initramfs and --qemu paths. Only BusyBox and its
musl loader are read from the existing initramfs; no Windows files are copied.
"""
from pathlib import Path
import argparse, gzip, hashlib, io, os, stat, subprocess, sys, zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_legacy_stage import build

def entries(data):
    # Linux initramfs may concatenate uncompressed early cpio and gzip streams.
    pos = 0
    while pos < len(data):
        if data[pos:pos+2] == b'\x1f\x8b':
            yield from entries(gzip.decompress(data[pos:])); return
        if data[pos:pos+6] != b'070701':
            pos += 1; continue
        fields = [int(data[pos+6+i*8:pos+14+i*8], 16) for i in range(13)]
        start = pos+110
        name = data[start:start+fields[11]-1].decode()
        start = (start+fields[11]+3)&~3
        blob = data[start:start+fields[6]]
        pos = (start+fields[6]+3)&~3
        if name != 'TRAILER!!!': yield name.lstrip('./'), blob

def cpio(files):
    out = bytearray()
    for ino, (name, blob, mode, major, minor) in enumerate(files+[('TRAILER!!!',b'',0,0,0)],1):
        encoded = name.encode()+b'\0'
        fields = (ino,mode,0,0,1,0,len(blob),0,0,major,minor,len(encoded),0)
        out.extend(b'070701'+b''.join(f'{v:08x}'.encode() for v in fields)+encoded)
        out.extend(b'\0'*(-len(out)%4)); out.extend(blob); out.extend(b'\0'*(-len(out)%4))
    return gzip.compress(out,mtime=0)

def archive(prefix=b'', adjusted=False):
    stream = io.BytesIO(prefix if adjusted else b'')
    if adjusted: stream.seek(0,2)
    with zipfile.ZipFile(stream,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('root/SETUP.EXE',b'own synthetic program')
        z.writestr('root/SUB/FILE.DAT',b'own nested data')
        z.writestr('root/../BAD.EXE',b'unsafe member')
    return stream.getvalue() if adjusted else prefix+stream.getvalue()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('kernel','initramfs','qemu'): ap.add_argument('--'+key,type=Path,required=True)
    a=ap.parse_args(); out=ROOT/'artifacts/legacy-pack/busybox-vm';out.mkdir(parents=True,exist_ok=True)
    selected={k.removeprefix('usr/'):v for k,v in entries(a.initramfs.read_bytes()) if k.removeprefix('usr/') in ('bin/busybox','lib/ld-musl-x86_64.so.1')}
    if len(selected)!=2: raise SystemExit('BusyBox/musl not found in supplied initramfs')
    files=[(d,b'',stat.S_IFDIR|0o755,0,0) for d in ('bin','lib','dev','proc','sys','tmp','data','lib/addons')]
    files += [('dev/console',b'',stat.S_IFCHR|0o600,5,1),('dev/null',b'',stat.S_IFCHR|0o666,1,3)]
    def add(name,blob,execute=False):files.append((name,blob,stat.S_IFREG|(0o755 if execute else 0o644),0,0))
    for k,v in selected.items():add(k,v,True)
    add('lib/addons/legacy-stage-plan',build(ROOT,out/'planner').read_bytes(),True)
    add('lib/addons/USOSADD.EXE',b'own runner placeholder')
    add('legacy_addons.sh',(ROOT/'tools/legacy_addons.sh').read_bytes().replace(b'\r\n',b'\n'))
    manifest='[pack]\nformat=1\nos=98SE\n[presets]\ndefault=praca\n[preset:praca]\nfull=1\n'
    for n,blob in enumerate((archive(),archive(b'MZown SFX stub\0'*23,True),archive(b'MZown SFX stub\0'*23))):
        add(f'data/ZIP{n}.EXE',blob)
        manifest+=f'[pkg:zip{n}]\ndir=ZIP{n}\nos=98SE\nlang=*\ntier=full\norder={n}\nunpack=zip\nfile1=ARCH.ZIP|own{n}.exe|{hashlib.sha256(blob).hexdigest()}|{len(blob)}\n'
    # Nested ZIP member discovery by pinned size and digest, without guessing names.
    own=b'own nested pinned file'; stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w') as z:z.writestr('odd/path/file.bin',own)
    add('data/NESTED.ZIP',stream.getvalue())
    manifest+=f'[pkg:nested]\ndir=NESTED\nos=98SE\nlang=*\ntier=full\norder=4\nfile1=FILE.DAT|own.bin|{hashlib.sha256(own).hexdigest()}|{len(own)}\n'
    bad=b'own invalid zip';add('data/BROKEN.ZIP',bad)
    manifest+=f'[pkg:broken]\ndir=BROKEN\nos=98SE\nlang=*\ntier=full\norder=5\nunpack=zip\nfile1=BAD.ZIP|broken.zip|{hashlib.sha256(bad).hexdigest()}|{len(bad)}\n'
    for lang in ('PL','EN'):add('lib/addons/LEGACY.'+lang,manifest.encode())
    add('config',b'preset=praca\noptions=\nexclude=\ndialup=off\n')
    init='''#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
busybox | head -1
. /legacy_addons.sh
failed=0
usos_addons_stage /config /target /lib /data 98SE PL '' || failed=1
find /target/USOS/ADDONS/PKG -type f
for n in 0 1 2; do
  test "$(cat /target/USOS/ADDONS/PKG/ZIP$n/SETUP.EXE)" = 'own synthetic program' || failed=1
  test "$(cat /target/USOS/ADDONS/PKG/ZIP$n/SUB/FILE.DAT)" = 'own nested data' || failed=1
  test ! -e /target/USOS/ADDONS/PKG/ZIP$n/BAD.EXE || failed=1
done
test "$(cat /target/USOS/ADDONS/PKG/NESTED/FILE.DAT)" = 'own nested pinned file' || failed=1
grep -q 'staging complete files=4 missing=1' /target/USOS9X/LOGS/ADDONS.LOG || failed=1
if test "$failed" = 0; then echo USOS_BUSYBOX_PASS; else echo USOS_BUSYBOX_FAIL; fi
poweroff -f
'''
    add('init',init.encode(),True); image=out/'own-test.cpio.gz';image.write_bytes(cpio(files))
    cmd=[str(a.qemu),'-machine','q35','-accel','tcg','-m','128','-smp','1','-nodefaults','-nic','none','-display','none','-monitor','none','-serial','stdio','-no-reboot','-kernel',str(a.kernel),'-initrd',str(image),'-append','console=ttyS0 rdinit=/init panic=1']
    result=subprocess.run(cmd,capture_output=True,timeout=120)
    (out/'serial.log').write_bytes(result.stdout+result.stderr)
    text=result.stdout.decode(errors='replace')
    print('\n'.join(l for l in text.splitlines() if any(k in l for k in ('BusyBox','[ADDONS]','USOS_BUSYBOX','cat:'))))
    return 0 if 'USOS_BUSYBOX_PASS' in text and result.returncode==0 else 1

if __name__=='__main__':raise SystemExit(main())
