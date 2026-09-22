"""Exercise the production NVMe preparation script inside micro-Linux.

Requires a built zig-out/micro-linux and bundled QEMU. No disks are attached;
synthetic non-executable PE fixtures and WIMs live in guest RAM only.
"""
from pathlib import Path
import sys,stat,gzip,subprocess,os,json
root=Path(__file__).resolve().parents[2]
out=root/'zig-out/windows7-nvme-version-test';out.mkdir(parents=True,exist_ok=True)
(out/'tmp').mkdir(exist_ok=True)
sys.path.insert(0,str(root/'tools'));sys.path.insert(0,str(root/'tools/tests'))
from build_micro_linux import Entry,newc,put
from test_windows7_nvme import version_pe
extra={}
for mode,version in [('gdr',(6,1,7601,17514)),('ldr',(6,1,7601,22822)),('newer',(6,1,7601,25000)),('rtm',(6,1,7600,16385)),('mixed',(6,1,7601,17514)),('malformed',(6,1,7601,17514))]:
 for path in ('Windows/System32/drivers/storport.sys','Windows/System32/drivers/Classpnp.sys','sources/winsetup.dll','sources/setup.exe'):
  data=version_pe((6,1,7601,25000) if mode=='mixed' and path.endswith('/setup.exe') else version)
  if mode=='malformed' and path.endswith('/storport.sys'):data=b'invalid PE'
  name='nvme-test-fixtures/'+mode+'/'+path;put(extra,Entry(name,stat.S_IFREG|0o644,data))
 if mode=='newer':
  name='nvme-test-fixtures/'+mode+'/Windows/System32/drivers/stornvme.sys';put(extra,Entry(name,stat.S_IFREG|0o644,version_pe(version)))
script='''#!/bin/sh
exec >/dev/console 2>&1
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
base=/usr/lib/usos/.nvme-tests
assets=/usr/lib/usos/windows7-nvme
mkdir -p "$base"
sh -n /usr/lib/usos/prepare_windows7_nvme.sh
for mode in gdr ldr newer rtm mixed malformed; do
 work="$base/$mode";mkdir -p "$work/.usos-win7-stage/USOS"
 echo nonce=version-policy >"$work/.usos-work"
 wimlib-imagex capture "/nvme-test-fixtures/$mode" "$work/original.wim" --compress=none --no-acls
 original_hash=$(sha256sum "$work/original.wim")
 if WORK_ROOT="$work" sh /usr/lib/usos/prepare_windows7_nvme.sh "$work/original.wim" 1 "$work/.usos-win7-stage"; then result=0; else result=$?; fi
 [ "$(sha256sum "$work/original.wim")" = "$original_hash" ]
 stage="$work/.usos-win7-stage"
 case "$mode" in
  gdr|ldr|mixed)
   [ "$result" = 0 ] && [ -s "$stage/nvme-update.txt" ] && [ -f "$stage/USOS/nvme-load.flag" ]
   branch=$mode;[ "$mode" != mixed ] || branch=gdr
   cmp "$stage/nvme-bootstrap/Windows/System32/drivers/storport.sys" "$assets/bootstrap/$branch/Windows/System32/drivers/storport.sys"
   cmp "$stage/USOS/nvme/stornvme.sys" "$assets/nvme/$branch/stornvme.sys"
   if [ "$mode" = mixed ]; then [ ! -e "$stage/nvme-bootstrap/sources/setup.exe" ]; fi
   ;;
  newer)
   [ "$result" = 0 ] && [ ! -s "$stage/nvme-update.txt" ] && [ -f "$stage/USOS/nvme-enabled.flag" ] && [ ! -e "$stage/USOS/nvme-load.flag" ]
   ;;
  rtm)
   [ "$result" = 0 ] && [ ! -s "$stage/nvme-update.txt" ] && [ ! -e "$stage/USOS/nvme-enabled.flag" ]
   ;;
  malformed) [ "$result" != 0 ] && [ ! -e "$stage/USOS/nvme-enabled.flag" ] ;;
 esac
 echo "USOS_NVME_VERSION_CASE_PASS=$mode"
done
echo USOS_NVME_VERSION_POLICY_PASS
poweroff -f
'''
put(extra,Entry('test-init',stat.S_IFREG|0o755,script.encode()))
initrd=out/'version-policy-initrd';initrd.write_bytes((root/'zig-out/micro-linux/initramfs-usos').read_bytes()+gzip.compress(newc(extra),mtime=0))
args=[str(root/'tools/qemu/qemu-system-x86_64.exe'),'-machine','pc','-accel','tcg','-m','2048','-display','none','-nic','none','-monitor','none','-kernel',str(root/'zig-out/micro-linux/vmlinuz-virt'),'-initrd',str(initrd),'-append','console=ttyS0 rdinit=/test-init panic=-1','-serial','file:'+str(out/'version-policy.log'),'-no-reboot']
with (out/'version-policy-qemu.log').open('wb') as log:p=subprocess.Popen(args,env=dict(os.environ,TEMP=str(out/'tmp'),TMP=str(out/'tmp')),stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW)
(out/'version-policy-vm.json').write_text(json.dumps({'pid':p.pid,'args':args}));print('Version policy VM',p.pid)

try:
 p.wait(timeout=180)
except subprocess.TimeoutExpired:
 p.kill();p.wait();raise RuntimeError('Version-policy VM timed out; see '+str(out/'version-policy.log'))
log=(out/'version-policy.log').read_text(errors='replace')
cases=[line.strip() for line in log.splitlines() if line.startswith('USOS_NVME_VERSION_CASE_PASS=')]
for line in cases:print(line)
if p.returncode or len(cases)!=6 or 'USOS_NVME_VERSION_POLICY_PASS' not in log:
 raise RuntimeError('Version-policy integration test failed; see '+str(out/'version-policy.log'))
print('USOS_NVME_VERSION_POLICY_PASS')
