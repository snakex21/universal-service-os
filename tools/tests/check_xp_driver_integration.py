"""Short file/hive/shell checks. No disk image, VM, boot, or target disk write."""
from pathlib import Path
import gzip,hashlib,json,os,subprocess,sys,ctypes as c,winreg,shutil,csv,argparse
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'tools'))
from build_micro_linux import parse_newc
from xp_driver_overlay import META,SELECTED,BUILTIN_USB,DRIVERS,registry_values,decode,edit_section
base=Path(os.environ.get('USOS_XP_PACKAGE_DIR',root/'zig-out/xp-uefi-csm'))
parser=argparse.ArgumentParser();parser.add_argument('--added-source',action='store_true',help='only the bundle of the later-added source ISO');args=parser.parse_args()
manifest=json.loads((base/'manifest.json').read_text())
# Every bundle in the archive is checked against the work folder of its own
# source ISO (drivers/<ISO SHA-256>), never against a list position.
sources=manifest.get('driver_sources') or [manifest['added_source']]
if args.added_source:sources=[manifest['added_source']] if 'added_source' in manifest else sources
assert {s['bundle'] for s in sources}<=set(manifest['driver_bundles']),sources
if not args.added_source:assert {s['bundle'] for s in sources}==set(manifest['driver_bundles']),'a driver bundle has no recorded source'
# Regression: split Microsoft source sections must not discard declarations or
# retain an older competing version of a replaced boot-critical driver.
split='[Files]\nkeep=one\nx.sys=old\n[Other]\nx.sys=untouched\n[FILES]\nkeep2=two\nx.sys=older\n'
fixed=edit_section(split,'Files',['x.sys=new'])
assert fixed.count('x.sys=new')==1 and 'x.sys=old' not in fixed
assert 'keep=one' in fixed and 'keep2=two' in fixed and '[Other]\r\nx.sys=untouched' in fixed
def check_bundle(source_dir):
 bundle=source_dir/'bundle';original=source_dir/'original'
 report=json.loads((bundle/'manifest.json').read_text())
 for n,h in report['sha256'].items():assert hashlib.sha256((bundle/n).read_bytes()).hexdigest()==h,n
 prefix='usr/lib/usos/xp-drivers/'+report['id']+'/'
 for p in bundle.rglob('*'):
  if p.is_file():assert archive[prefix+p.relative_to(bundle).as_posix()].data==p.read_bytes()
 stage=archive['usr/lib/usos/legacy_xp_staging.sh'].data.decode()
 assert stage.index('usos_xp_driver_preflight')<stage.index('    usos_xp_disk_mode || continue')
 prepare=archive['usr/lib/usos/prepare_xp_ntfs_target.sh'].data.decode()
 assert prepare.index('xp_driver_stage.sh')>prepare.index('prepare_xp_local_source.sh')
 assert prepare.index('xp_driver_stage.sh')<prepare.index('prepare_xp_windows_partition.sh')
 work=source_dir/'driver-checks';work.mkdir(exist_ok=True)
 hivecopy=work/'setupreg-check.hiv';shutil.copyfile(bundle/'I386/SETUPREG.HIV',hivecopy)
 adv=c.WinDLL('advapi32');adv.RegLoadAppKeyW.argtypes=[c.c_wchar_p,c.POINTER(c.c_void_p),c.c_uint,c.c_uint,c.c_uint]
 h=c.c_void_p();assert adv.RegLoadAppKeyW(str(hivecopy),c.byref(h),winreg.KEY_READ,1,0)==0
 try:
  for p,n,t,v in registry_values():
   with winreg.OpenKey(h.value,'ControlSet001\\'+p) as k:assert winreg.QueryValueEx(k,n)==(v,t),(p,n)
 finally:winreg.CloseKey(h.value)
 inf,_=decode((bundle/'I386/HIVESYS.INF').read_bytes())
 for p,n,t,v in registry_values():
  matching=[row for row in csv.reader(inf.splitlines()) if len(row)>=5 and row[0]=='HKLM' and row[1]=='SYSTEM\\CurrentControlSet\\'+p and row[2]==n]
  assert matching,(p,n)
  value=matching[-1][4]
  assert (int(value,16) if t==4 else value)==v,(p,n,value,v)
 # Verify CAB CRCs and that the PnP cache also contains the patched ACPI.
 subprocess.run(['C:/Program Files/7-Zip/7z.exe','t',str(bundle/'I386/SP3.CAB')],check=True,stdout=subprocess.DEVNULL)
 subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(bundle/'I386/SP3.CAB'),'acpi.sys','-o'+str(work),'-y'],check=True,stdout=subprocess.DEVNULL)
 assert (work/'acpi.sys').read_bytes()==(DRIVERS/'ACPI/acpi.sys').read_bytes()
 for n in SELECTED:
  name=Path(n).name.upper();packed=bundle/'I386'/(name[:-1]+'_')
  subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(packed),'-o'+str(work),'-y'],check=True,stdout=subprocess.DEVNULL)
  if name.endswith('.SYS'):assert (work/name).read_bytes()==(DRIVERS/n).read_bytes(),name
 if report.get('native_usb_dependencies'):
  sif,_=decode((bundle/'I386/TXTSETUP.SIF').read_bytes())
  for name in BUILTIN_USB:
   subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(bundle/'I386'/(name[:-1]+'_').upper()),'-o'+str(work),'-y'],check=True,stdout=subprocess.DEVNULL)
   assert hashlib.sha256((work/name).read_bytes()).hexdigest()==report['native_usb_dependencies'][name]
   lines=[line.strip().lower() for line in sif.splitlines() if line.strip().lower().startswith(name+' = 1,') or line.strip().lower().startswith(name+' = 100,')]
   assert lines==[name+' = 1,,,,,,3_,4,0,0,,1,4'],(name,lines)
 # Run the actual staging function against ordinary workspace directories.
 target=work/'target';target.mkdir(exist_ok=True)
 for sub in ('$WIN_NT$.~BT','$WIN_NT$.~LS/I386'):
  folder=target/sub;folder.mkdir(parents=True,exist_ok=True)
  (folder/'TXTSETUP.SIF').write_text('original')
  (folder/'acpi.sys').write_bytes(b'old uncompressed driver')
 source=work/'source/I386';source.mkdir(parents=True,exist_ok=True)
 for n in META:shutil.copyfile(original/n,source/n)
 def posix(p):return '/'+p.drive[0].lower()+p.as_posix()[2:]
 env=dict(os.environ,XP_TARGET_ROOT=posix(target),XP_DRIVER_BUNDLE=posix(bundle),SOURCE_ROOT=posix(source.parent))
 shell='C:/Program Files/Git/bin/bash.exe';script=root/'tools/xp_driver_stage.sh'
 subprocess.run([shell,'-n',str(script)],check=True)
 subprocess.run([shell,str(script),'apply'],env=env,check=True)
 for sub in ('$WIN_NT$.~BT','$WIN_NT$.~LS/I386'):
  for p in (bundle/'I386').iterdir():
   if sub=='$WIN_NT$.~BT' and p.name=='SP3.CAB':continue
   assert (target/sub/p.name).read_bytes()==p.read_bytes()
  assert not (target/sub/'acpi.sys').exists()
 assert (target/'TXTSETUP.SIF').read_bytes()==(bundle/'I386/TXTSETUP.SIF').read_bytes()
 # A changed source must be rejected BEFORE replacing the already-staged files.
 (source/'TXTSETUP.SIF').write_text('wrong source')
 sentinel=target/'$WIN_NT$.~BT/TXTSETUP.SIF';before=sentinel.read_bytes()
 assert subprocess.run([shell,str(script),'apply'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
 assert sentinel.read_bytes()==before
archive=parse_newc(gzip.decompress((base/'initramfs-xp').read_bytes()))
for source in sources:
 check_bundle(base/'drivers'/source['sha256'])
 print('PASS bundle',source['bundle'],source['name'],flush=True)
print('PASS: archive payload, pre-format preflight ordering, persisted Setup hive, CAB/ACPI cache, actual staging copies and wrong-source refusal')
