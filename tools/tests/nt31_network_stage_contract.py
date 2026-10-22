"""Bounded original network INF contract for installing stock TCP/IP in owned NT31."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
MATRIX=ROOT.parent/'macierz-windows'
SCRATCH=Path(r'G:\USOS-Kolekcja\_audit\nt31-network-stage')
OUT=ROOT/'artifacts/nt31-fullmac-contract/network-stage-contract-01.json'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main(details=False,identify=False,loop=False):
    global OUT
    if details:OUT=OUT.with_name('network-stage-contract-02.json')
    if identify:OUT=OUT.with_name('network-oem-identification.json')
    if loop:OUT=OUT.with_name('network-loopback-oem-contract.json')
    if OUT.exists():raise FileExistsError('Never overwrite a completed contract')
    if shutil.disk_usage(SCRATCH.anchor).free<100*1024**3:raise ValueError('100GiB reserve required')
    media=load('network_stage_media',MATRIX/'tools/tests/coverage/driver_audit.py')
    unpack=media.cab.unpack;media.cab.unpack=lambda b,member=None:unpack(b,member,scratch=SCRATCH/'packed')
    case,=json.loads((MATRIX/'artifacts/coverage/nt31-runtime-r19/plan.json').read_text(encoding='utf-8'))
    if sha(Path(case['source']))!=case['source_sha256']:raise ValueError('Original archive mismatch')
    result=dict(scope='Original INF staging contract; not installed network PASS',archive_sha256=case['source_sha256'],iso_sha256=case['member_sha256'],inf={})
    SCRATCH.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(dir=SCRATCH,prefix='original-') as temp:
        work=Path(temp)
        subprocess.run([str(media.SEVEN),'e','-y','-o'+str(work),case['source'],case['member']],check=True,capture_output=True,timeout=120)
        iso=work/Path(case['member']).name
        if sha(iso)!=case['member_sha256']:raise ValueError('ISO mismatch')
        with iso.open('rb') as stream:
            volume=media.media.ISO(stream)
            if identify:
                result['oem_candidates']={}
                for name in sorted(volume.entries):
                    if not re.fullmatch(r'i386/oemnad[^/]*\.in_',name):continue
                    blob=media.binary(volume,name);lines=blob.decode('cp1252').splitlines()
                    matches=[dict(line=i+1,text=line) for i,line in enumerate(lines) if re.search(r'ProductSoftwareName\s*=|NE2000|ProductSoftwareImagePath\s*=|UtilityInf\s*=',line,re.I)]
                    if len(matches)>80:raise ValueError('Bound OEM identity excerpts')
                    result['oem_candidates'][name]=dict(sha256=hashlib.sha256(blob).hexdigest(),lines=matches)
                if len(result['oem_candidates'])>64:raise ValueError('Bound OEM candidate count')
            for leaf in (('oemnadlb.inf',) if loop else ('oemnadne.inf','oemnxptc.inf')):
                if identify:break
                name='i386/'+leaf
                if name not in volume.entries:name=name[:-1]+'_'
                blob=media.binary(volume,name);lines=blob.decode('cp1252').splitlines()
                selected=[i for i,line in enumerate(lines) if re.search(r'CreateService|SetRegistry|OpenReg|Linkage|DependOn|\bBind\b|\bExport\b|\bRoute\b|RegistryValue|AddReg|ServiceName|ServiceType|StartType|LoadOrder|TcpipConfig|tcpcfg|ServiceGroup',line,re.I)]
                indices=sorted({i for at in selected for i in range(max(0,at-2),min(len(lines),at+3))})
                if loop:
                    selected=[i for i,line in enumerate(lines) if re.search(r'ProductSoftware|ProductHardware|NDISLoop|loop\.sys|BusType|BusNumber|LibraryProcedure|DlgTemplate|Source Media|Files-|AddHardware|AdapterList|bindform|NetRule',line,re.I)]
                    indices=sorted({i for at in selected for i in range(max(0,at-1),min(len(lines),at+2))})
                if details:
                    ranges=((20,80),(200,285),(286,350)) if leaf=='oemnadne.inf' else ((20,90),(245,330),(395,435),(735,790),(1001,1068),(1110,1165))
                    indices=sorted({i for start,end in ranges for i in range(start-1,min(end,len(lines)))})
                if len(indices)>500:raise ValueError('Narrow INF contract before retry')
                result['inf'][name]=dict(sha256=hashlib.sha256(blob).hexdigest(),total_lines=len(lines),selected_lines=[dict(line=i+1,text=lines[i]) for i in indices])
    result.update(temporary_iso_removed=not work.exists(),expanded_ms_files_persisted=False,runtime_pass=False)
    OUT.write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(dict(output=str(OUT),lines={k:len(v['selected_lines']) for k,v in result['inf'].items()},temporary_iso_removed=result['temporary_iso_removed'])))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--details',action='store_true');p.add_argument('--identify',action='store_true');p.add_argument('--loop',action='store_true');a=p.parse_args();main(a.details,a.identify,a.loop)
