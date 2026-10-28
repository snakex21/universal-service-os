# SPDX-License-Identifier: GPL-3.0-or-later
"""Run our Zig NTFS reader over a locked, accepted VHD using read-only IPC."""
import argparse,contextlib,json,re,struct,subprocess,threading
from pathlib import Path
import bcdboot_reference as reference
import install_native as native
import logged_run
import wim_oracle as o

PATHS=('Windows/System32/winload.efi','Windows/Boot/EFI/bootmgfw.efi','Windows/System32/config/BCD-Template',
       'Windows/INF/setupapi.offline.20240401_072600.log','Windows/servicing/Sessions/Sessions.xml')

def run(a):
 head,dirty=logged_run.tree(reference.REPO)
 if dirty:raise ValueError('Clean probe tree required')
 out=o.owned(a.out)
 if out.exists():raise ValueError('Fresh evidence directory required')
 o.storage_guard(1024**2)
 proof=json.loads(a.native.read_text(encoding='utf-8-sig'))
 if proof.get('passed') is not True or proof.get('schema')!='minios-install-native-v1':raise ValueError('Accepted native receipt required')
 base=native.regular(o.owned(Path(proof['vhd'])))
 layout=json.loads((a.native.parent/'layout.json').read_text());part=next(p for p in layout['partitions'] if p['number']==layout['windows_number'])
 expected={}
 with a.tree.open(encoding='utf-8') as f:
  for line in f:
   item=json.loads(line);path=item['path'].replace('\\','/').lower()
   for i,wanted in enumerate(PATHS):
    if path==wanted.lower():
     streams=[s for s in item['streams'] if s['kind']=='data' and s['name'] is None]
     if len(streams)!=1:raise ValueError('One exact independent unnamed stream required')
     expected[i]=streams[0]
 if len(expected)!=len(PATHS):raise ValueError('Independent manifest lacks boot source')
 out.mkdir(parents=True)
 env=o.environment(out);errors=[];stderr=bytearray();reads=bytes_read=0
 with o.readonly(base) as source:
  if o.digest_stream(source)!=proof['vhd_sha256']:raise ValueError('Native base changed')
  image=native.DynamicVhd(base,stream=source)
  command=[str(a.exe),str(part['start']),str(part['bytes'])]
  child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  def capture():
   while data:=child.stderr.read(65536):
    if len(stderr)+len(data)>1024**2:
     errors.append('stderr limit');child.kill();continue
    stderr.extend(data)
  thread=threading.Thread(target=capture);thread.start()
  timer=threading.Timer(300,child.kill);timer.daemon=True;timer.start()
  try:
   while request:=child.stdout.read(12):
    if len(request)!=12:raise ValueError('Truncated read request')
    offset,count=struct.unpack('<QI',request)
    if not 0<count<=65536 or offset>image.size or count>image.size-offset or reads>=1_000_000 or bytes_read+count>128*1024**2:raise ValueError('Read-only IPC bounds')
    image.seek(offset);data=image.read(count)
    if len(data)!=count:raise ValueError('Truncated image range')
    child.stdin.write(data);child.stdin.flush();reads+=1;bytes_read+=count
   code=child.wait(timeout=15)
  finally:
   if child.returncode is None:child.kill()
   child.wait(timeout=15);timer.cancel();thread.join(timeout=15)
   child.stdin.close();child.stdout.close();child.stderr.close()
  after=o.digest_stream(source)
 if errors or code or after!=proof['vhd_sha256']:raise ValueError('Probe failed: '+stderr.decode(errors='replace'))
 text=stderr.decode('utf-8')
 rows=re.findall(r'PROBE_FILE index=(\d+) bytes=(\d+) sha1=([a-f0-9]{40})',text)
 if len(rows)!=len(PATHS) or len({int(row[0]) for row in rows})!=len(PATHS) or 'PROBE_READONLY PASS writes=0' not in text:raise ValueError('Missing reader proof')
 for index,size,sha in rows:
  oracle=expected[int(index)]
  if int(size)!=oracle['size'] or sha!=oracle['sha1']:raise ValueError('Independent source SHA1 differs')
 (out/'probe.log').write_bytes(f'HEAD {head}\nWORKTREE_DIRTY 0\n'.encode()+stderr)
 result=dict(schema='minios-ntfs-reader-probe-v1',head=head,dirty=0,passed=True,read_only=True,image_sha256_before=proof['vhd_sha256'],image_sha256_after=after,reads=reads,read_bytes=bytes_read,files=[dict(path=PATHS[int(i)],bytes=int(n),sha1=s) for i,n,s in rows],independent_manifest_sha256=o.digest(a.tree),exe_sha256=o.digest(a.exe),mft_runs=int(re.search(r'PROBE_MFT runs=(\d+)',text)[1]),physical_disks_opened=False,writes=0)
 if logged_run.tree(reference.REPO)!=(head,0):raise ValueError('Tree changed')
 o.save(out/'result.json',result);return result

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__)
 for n in ('exe','native','tree','out'):p.add_argument('--'+n,type=Path,required=True)
 print(json.dumps(run(p.parse_args())))
