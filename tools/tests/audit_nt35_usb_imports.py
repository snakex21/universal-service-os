"""Compare frozen own USB imports with hash-verified NT35 media, MS bytes only RAM."""
from pathlib import Path
import argparse,gzip,hashlib,importlib.util,json,shutil,subprocess,tempfile
import pefile
ROOT=Path(__file__).resolve().parents[2];MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows');OWN=Path(r'G:\USOS-Kolekcja\_audit\nt35-usb-imports')
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def digest(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True);args=parser.parse_args();OUT=args.out.resolve()
 if not OUT.is_relative_to(ROOT/'artifacts/nt35-network'):raise ValueError('Owned output required')
 if OUT.exists():raise FileExistsError('Fresh own audit output required')
 if not OWN.resolve().is_relative_to(Path(r'G:\USOS-Kolekcja\_audit').resolve()):raise ValueError('Owned audit only')
 OWN.mkdir(parents=True,exist_ok=True)
 if shutil.disk_usage(OWN).free<100*1024**3:raise ValueError('100GiB reserve')
 h=load('original_media',MATRIX/'tools/tests/coverage/driver_audit.py');unpack=h.cab.unpack;h.cab.unpack=lambda blob,member=None:unpack(blob,member,scratch=OWN/'packed')
 rows=json.loads((MATRIX/'artifacts/coverage/nt3-hid-runtime-plan-r15.json').read_text(encoding='utf-8'));case=next(c for c in rows if c['tag']=='r15-nt35-wks-hid')
 if digest(Path(case['source']))!=case['source_sha256']:raise ValueError('Archive hash differs')
 cache=load('own_layers',ROOT/'tools/tests/build_nt35_fixture_cache.py');entries,_=cache.effective_newc(gzip.decompress(Path(r'G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt35-net1\zig-out\micro-linux\initramfs-usos').read_bytes()))
 own=entries['usr/lib/usos/nt3/USOSUSB.SYS'].data
 if hashlib.sha256(own).hexdigest()!='2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1':raise ValueError('Frozen USB changed')
 result={'scope':'Static import compatibility only, no kernel load/class/HID runtime PASS','source_sha256':case['source_sha256'],'iso_sha256':case['member_sha256'],'own_usb_sha256':hashlib.sha256(own).hexdigest(),'modules':{}}
 with tempfile.TemporaryDirectory(prefix='original-',dir=OWN) as temporary:
  work=Path(temporary);subprocess.run([str(h.SEVEN),'e','-y','-o'+str(work),case['source'],case['member']],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=120)
  iso=work/Path(case['member']).name
  if digest(iso)!=case['member_sha256']:raise ValueError('ISO hash differs')
  with iso.open('rb') as stream:
   vol=h.media.ISO(stream);pe=pefile.PE(data=own);missing=[]
   for dll in pe.DIRECTORY_ENTRY_IMPORT:
    leaf=dll.dll.decode().lower();names=[i.name.decode() if i.name else '#'+str(i.ordinal) for i in dll.imports]
    if leaf=='ntoskrnl.exe':
     candidates=[n for n in ('i386/ntoskrnl.ex_','i386/ntoskrnl.exe','i386/ntkrnlmp.ex_','i386/ntkrnlmp.exe') if n in vol.entries]
     if len(candidates)!=2 or not any('/ntoskrnl.' in n for n in candidates) or not any('/ntkrnlmp.' in n for n in candidates):raise ValueError('Both original UP/MP kernels required')
     variants=[(h.binary(vol,n),n) for n in candidates]
    else:variants=[h.module_from_iso(vol,leaf)]
    for blob,member in variants:
     if blob is None:raise ValueError('Original module absent: '+leaf)
     ex,_=h.pe(h.MemoryFile(blob,leaf));absent=[n for n in names if n not in ex];missing.extend(member+'!'+n for n in absent)
     result['modules'][member]={'module':leaf,'member':member,'sha256':hashlib.sha256(blob).hexdigest(),'imports':names,'missing':absent}
   result['missing']=missing;result['own_pe_os']=[pe.OPTIONAL_HEADER.MajorOperatingSystemVersion,pe.OPTIONAL_HEADER.MinorOperatingSystemVersion];result['own_pe_subsystem']=[pe.OPTIONAL_HEADER.MajorSubsystemVersion,pe.OPTIONAL_HEADER.MinorSubsystemVersion]
 result.update(temporary_iso_removed=not work.exists(),expanded_ms_binary_exported=False,runtime_pass=False)
 OUT.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
