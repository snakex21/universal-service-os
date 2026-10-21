"""Original NT35 timezone table in RAM; never read or modify a live VM."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,shutil,struct,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2];MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows');OWN=Path(r'G:\USOS-Kolekcja\_audit\nt35-timezone-contract')
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def digest(path):
 with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True);a=parser.parse_args();out=a.out.resolve()
 if not out.is_relative_to(ROOT/'artifacts/nt35-network') or out.exists():raise ValueError('Fresh owned metadata output required')
 if not OWN.resolve().is_relative_to(Path(r'G:\USOS-Kolekcja\_audit').resolve()):raise ValueError('Owned audit only')
 OWN.mkdir(parents=True,exist_ok=True)
 if shutil.disk_usage(OWN).free<100*1024**3:raise ValueError('100GiB reserve')
 h=load('timezone_original_media',MATRIX/'tools/tests/coverage/driver_audit.py');modern=load('timezone_regf12',ROOT/'tools/xp_hive.py');unpack=h.cab.unpack;h.cab.unpack=lambda b,member=None:unpack(b,member,scratch=OWN/'packed')
 case=next(x for x in json.loads((MATRIX/'artifacts/coverage/nt3-hid-runtime-plan-r15.json').read_text()) if x['tag']=='r15-nt35-wks-hid')
 if digest(Path(case['source']))!=case['source_sha256']:raise ValueError('Original archive hash differs')
 report={'source_sha256':case['source_sha256'],'iso_sha256':case['member_sha256'],'script_sha256':digest(Path(__file__)),'scope':'Original timezone source data, not unattended/runtime PASS'}
 with tempfile.TemporaryDirectory(prefix='original-',dir=OWN) as temporary:
  work=Path(temporary);subprocess.run([str(h.SEVEN),'e','-y','-o'+str(work),case['source'],case['member']],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=120);iso=work/Path(case['member']).name
  if digest(iso)!=case['member_sha256']:raise ValueError('Original ISO hash differs')
  with iso.open('rb') as stream:
   volume=h.media.ISO(stream);blob=h.binary(volume,'i386/software._');version=struct.unpack_from('<II',blob,20)
   if version!=(1,2) or blob[:4]!=b'regf' or blob[4:8]!=blob[8:12] or modern.checksum(blob)!=struct.unpack_from('<I',blob,508)[0]:raise ValueError('Exact original SOFTWARE REGF1.2/clean header required')
   report.update(member='i386/software._',software_sha256=hashlib.sha256(blob).hexdigest(),regf_version=list(version),reader_sha256=digest(ROOT/'tools/xp_hive.py'))
   values=modern.read_hive_content(blob);zones={}
   for path,fields in values.items():
    if path.startswith('microsoft\\windows nt\\currentversion\\time zones\\') and any(t in path for t in ('gmt','greenwich','monrovia','casablanca')):
     zones[path]={key:raw.decode('utf-16le').rstrip('\0') for key,(typ,raw) in fields.items() if key in ('display','std','dlt') and typ in (1,2)}
   report['timezone_keys']=zones;report['candidate_present_as_display']=any(v.get('display')=='(GMT) Monrovia, Casablanca' for v in zones.values())
   if not report['candidate_present_as_display']:raise ValueError('Expected original timezone label missing')
   main,member=h.module_from_iso(volume,'main.cpl');report['main_cpl']={'member':member,'sha256':hashlib.sha256(main).hexdigest(),'registry_path_string_present':'Software\\Microsoft\\Windows NT\\CurrentVersion\\Time Zones'.encode('utf-16le') in main,'install_switch_string_present':b'/INSTALL=' in main or '/INSTALL='.encode('utf-16le') in main}
 report.update(temporary_iso_removed=not work.exists(),expanded_ms_binary_exported=False,runtime_pass=False);out.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
