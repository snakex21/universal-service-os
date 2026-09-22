"""Download upstream packages for review only; never run their installers."""
import urllib.request, urllib.parse, json, hashlib, io, zipfile, struct
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tools/vendor/xp-modern/2026-09-21'
OUT.mkdir(parents=True,exist_ok=True)
def request(url, headers=None):
 return urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'USOS-driver-review',**(headers or {})}),timeout=45)
class RemoteZip(io.RawIOBase):
 def __init__(self,url):
  self.url=url; self.pos=0
  with request(url,{'Range':'bytes=0-0'}) as r:
   if r.status!=206: raise RuntimeError('Range unsupported; refusing full OS download')
   self.size=int(r.headers['Content-Range'].split('/')[-1]); r.read()
 def seekable(self): return True
 def seek(self,n,whence=0):
  self.pos=n if whence==0 else self.pos+n if whence==1 else self.size+n
  return self.pos
 def tell(self): return self.pos
 def read(self,n=-1):
  if n<0:n=self.size-self.pos
  if n==0:return b''
  with request(self.url,{'Range':f'bytes={self.pos}-{self.pos+n-1}'}) as r:
   if r.status!=206:raise RuntimeError('Range request rejected')
   data=r.read(n+1)
   if len(data)!=n:raise RuntimeError('Wrong range length')
  self.pos+=len(data);return data
records=[]
for name,url in [
 ('GenAHCI_6.3.0.1.7z','https://github.com/GeorgeK1ng/GenAHCI/releases/download/GenAHCI/GenAHCI_6.3.0.1.7z'),
 ('xhci98-1.1.0.0.zip','https://github.com/yeokm1/xhci98/releases/download/v1.1.0.0/xhci98-1.1.0.0.zip')]:
 p=OUT/name
 if not p.exists():
  with request(url) as r:p.write_bytes(r.read())
 records.append(dict(file=name,url=url,sha256=hashlib.sha256(p.read_bytes()).hexdigest(),size=p.stat().st_size))
 print('DOWNLOADED',name,p.stat().st_size,flush=True)
url='https://zone94.com/files/software/operating_systems/'+urllib.parse.quote('Windows XP Professional SP3 x86 - Integral Edition 2025.8.19.zip')
try:
 with zipfile.ZipFile(RemoteZip(url)) as z:
  entries=[dict(name=i.filename,size=i.file_size,compressed=i.compress_size) for i in z.infolist()]
  (OUT/'integral-archive-index.json').write_text(json.dumps(entries,indent=2),encoding='utf8')
  for i in z.infolist():
   chosen=('Options Menu.cmd','Patches/ACPI drivers/','Patches/Microsoft USB3.x xHCI driver v2.2/','Patches/Microsoft SATA driver v6.3.0.1/','Patches/Kernel-Mode Driver Framework 1.11/','Patches/Miscellaneous/')
   if 'Patch Integrator v4.2.3/' in i.filename and i.filename.split('Patch Integrator v4.2.3/',1)[1].startswith(chosen):
    if not i.is_dir():
     dest=OUT/'integrator'/i.filename
     if not dest.resolve().is_relative_to((OUT/'integrator').resolve()):raise RuntimeError('Unsafe archive path')
     dest.parent.mkdir(parents=True,exist_ok=True)
     if not dest.exists():dest.write_bytes(z.read(i))
     records.append(dict(file=dest.relative_to(OUT).as_posix(),url=url,member=i.filename,sha256=hashlib.sha256(dest.read_bytes()).hexdigest(),size=dest.stat().st_size))
except Exception:
 (OUT/'download-manifest-partial.json').write_text(json.dumps(records,indent=2),encoding='utf8')
 raise
(OUT/'download-manifest.json').write_text(json.dumps(records,indent=2),encoding='utf8')
print('SELECTED_DOWNLOADS_COMPLETE',len(records),flush=True)
