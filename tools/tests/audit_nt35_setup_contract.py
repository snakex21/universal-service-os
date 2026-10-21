"""Original NT35 INF and own helper imports; expanded Microsoft bytes only RAM."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,re,shutil,subprocess,tempfile
import pefile
ROOT=Path(__file__).resolve().parents[2];MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows');OWN=Path(r'G:\USOS-Kolekcja\_audit\nt35-setup-contract')
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def digest(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True);parser.add_argument('--post-helper',type=Path,required=True);args=parser.parse_args();OUT=args.out.resolve()
 if not OUT.is_relative_to(ROOT/'artifacts/nt35-network'):raise ValueError('Owned audit output required')
 if OUT.exists():raise FileExistsError('Fresh output required')
 if not OWN.resolve().is_relative_to(Path(r'G:\USOS-Kolekcja\_audit').resolve()):raise ValueError('Owned audit only')
 OWN.mkdir(parents=True,exist_ok=True)
 if shutil.disk_usage(OWN).free<100*1024**3:raise ValueError('100GiB reserve')
 h=load('original_media',MATRIX/'tools/tests/coverage/driver_audit.py');unpack=h.cab.unpack;h.cab.unpack=lambda blob,member=None:unpack(blob,member,scratch=OWN/'packed')
 cases=json.loads((MATRIX/'artifacts/coverage/nt3-hid-runtime-plan-r15.json').read_text());case,=[c for c in cases if c['system']=='windows-nt-3-5' and c['folder']=='Windows NT 3.5']
 if digest(Path(case['source']))!=case['source_sha256']:raise ValueError('Original archive hash differs')
 helper=args.post_helper.resolve();logger=ROOT/'tools/nt3/usoslog/bin/i386/usoslog.exe'
 if not helper.is_relative_to(ROOT) or not helper.is_file():raise ValueError('Owned posthelper required')
 result={'source_sha256':case['source_sha256'],'iso_sha256':case['member_sha256'],'script_sha256':digest(Path(__file__)),'inf_contract':{},'own_import_preflight':{}}
 with tempfile.TemporaryDirectory(prefix='original-',dir=OWN) as temporary:
  work=Path(temporary).resolve();assert work.is_relative_to(OWN.resolve())
  subprocess.run([str(h.SEVEN),'e','-y','-o'+str(work),case['source'],case['member']],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=120)
  iso=work/Path(case['member']).name
  if digest(iso)!=case['member_sha256']:raise ValueError('Original ISO hash differs')
  with iso.open('rb') as stream:
   vol=h.media.ISO(stream)
   setup=h.binary(vol,'i386/txtsetup.sif');text=setup.decode('cp1252');version={key:int(re.search(r'^'+key+r'\s*=\s*(\d+)',text,re.M|re.I).group(1)) for key in ('MajorVersion','MinorVersion')}
   if version!={'MajorVersion':3,'MinorVersion':50}:raise ValueError('Exact NT3.50 source expected')
   result['setup_version']={'member':'i386/txtsetup.sif','sha256':hashlib.sha256(setup).hexdigest(),**version}
   members=[n for n in vol.entries if n.startswith('i386/') and n.endswith(('.in_','.inf','.txt','.tx_')) and Path(n).name.startswith(('oemnadlb','unattend','initial','oemnsvtc','oemnxptc','subroutn','netsetup','oemnsvdh','ntlanman'))]
   result['members']=members
   patterns=(r'GetDefaultAnswer',r'NetworkAdapterData',r'TransportData',r'ProtocolData',r'InstallTCPIP',r'AdapterParameters',r'AutoNetOption',r'InstallTCPIP',r'SetupNetWork',r'AutoWorkGroup',r'^adapteroptions = \+',r'^skipoptions = \+',r'BusNumber',r'BusType',r'Medium',r'GMT',r'DHCP')
   for name in members:
    blob=h.binary(vol,name);lines=blob.decode('cp1252').splitlines()
    hits=[i for i,line in enumerate(lines) if any(re.search(pattern,line,re.I) for pattern in patterns)]
    selected={i for at in hits for i in range(max(0,at-3),min(len(lines),at+4))}
    if len(selected)>800:raise ValueError('Narrow INF excerpts')
    ranges={'i386/initial.in_':((465,510),),'i386/oemnadlb.in_':((170,240),(400,425)),'i386/oemnxptc.in_':((80,120),(1060,1145)),'i386/subroutn.in_':((250,310),)}
    for lo,hi in ranges.get(name,()):selected.update(range(lo-1,min(len(lines),hi)))
    info={'sha256':hashlib.sha256(blob).hexdigest(),'total_lines':len(lines),'lines':[{'line':i+1,'text':lines[i]} for i in sorted(selected)]}
    if Path(name).name.startswith('oemnadlb'):
     env=dict(os.environ,TEMP=str(work),TMP=str(work))
     patch=ROOT/'tools/nt35_network_setup.sh'
     r=subprocess.run([r'C:\Program Files\Git\bin\sh.exe','-c',f'. "{patch.as_posix()}"; usos_nt35_loop_inf'],input=blob,capture_output=True,check=True,env=env)
     info['own_patch_sha256']=digest(patch);info['patched_sha256']=hashlib.sha256(r.stdout).hexdigest();info['own_marker_count']=r.stdout.count(b';USOS-NT35-LOOP-AUTO')
     if info['own_marker_count']!=1:raise ValueError('Exact own INF patch failed')
    result['inf_contract'][name]=info
   result['setup_module_strings']={}
   for leaf in ('ncpa.cpl','netcfg.dll','netsetup.dll'):
    blob,member=h.module_from_iso(vol,leaf)
    if blob is None:continue
    pe=pefile.PE(data=blob);hits=[]
    for pattern,encoding in ((rb'[\x20-\x7e]{4,}','ascii'),(rb'(?:[\x20-\x7e]\x00){4,}','utf-16le')):
     for match in re.finditer(pattern,blob):
      text=match.group().decode(encoding)
      if any(k.lower() in text.lower() for k in ('TransportData','InstallTCPIP','InstallNetBEUI','InstallNWLink','AutoNetOption','NetworkAdapterData','AdapterParameters','NetCardParameterList','AutoTcp','Dhcp')):
       if len(text)>300:raise ValueError('Narrow setup string')
       hits.append({'rva':hex(pe.get_rva_from_offset(match.start())),'text':text})
    result['setup_module_strings'][leaf]={'member':member,'sha256':hashlib.sha256(blob).hexdigest(),'strings':hits}
   exports={}
   for leaf in ('kernel32.dll','advapi32.dll','user32.dll'):
    blob,member=h.module_from_iso(vol,leaf)
    ex,_=h.pe(h.MemoryFile(blob,leaf));exports[leaf]=set(ex)
    result.setdefault('dll_contract',{})[leaf]={'sha256':hashlib.sha256(blob).hexdigest(),'exports_count':len(ex),'member':member}
   for own in (helper,logger):
    pe=pefile.PE(str(own));missing=[];imports=[]
    for module in pe.DIRECTORY_ENTRY_IMPORT:
     dll=module.dll.decode().lower()
     for i in module.imports:
      name=i.name.decode() if i.name else '#'+str(i.ordinal);imports.append(dll+'!'+name)
      if dll not in exports or name not in exports[dll]:missing.append(dll+'!'+name)
    result['own_import_preflight'][own.name]={'sha256':digest(own),'imports':imports,'missing':missing,'pe_os':[pe.OPTIONAL_HEADER.MajorOperatingSystemVersion,pe.OPTIONAL_HEADER.MinorOperatingSystemVersion],'pe_subsystem':[pe.OPTIONAL_HEADER.MajorSubsystemVersion,pe.OPTIONAL_HEADER.MinorSubsystemVersion]}
 result['temporary_iso_removed']=not work.exists();result['expanded_ms_binary_exported']=False;result['runtime_pass']=False
 OUT.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps({'output':str(OUT),'inf_hashes':{n:{'sha256':i['sha256'],'patched_sha256':i.get('patched_sha256')} for n,i in result['inf_contract'].items()},'own_missing':{n:i['missing'] for n,i in result['own_import_preflight'].items()}},indent=2))
if __name__=='__main__':main()
