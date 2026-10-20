"""Coverage facts from production readers and bounded original media metadata.

Only version/build/edition/language/marker facts are saved. No answer file or
product key is read. Archive members are extracted only into a new G: scratch
directory, inspected, then deleted. Downloaded inputs are never changed.
"""
from pathlib import Path
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import struct
import tempfile
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[3]
SEVEN=Path(r'C:\Program Files\7-Zip\7z.exe')
SCRATCH=Path(r'G:\USOS-Kolekcja\_inspection')
spec=importlib.util.spec_from_file_location('coverage_media_facts',ROOT/'tools/windows_media_facts.py')
facts=importlib.util.module_from_spec(spec);spec.loader.exec_module(facts)
spec=importlib.util.spec_from_file_location('coverage_cab',Path(__file__).with_name('unpack_bytes.py'))
cab=importlib.util.module_from_spec(spec);spec.loader.exec_module(cab)


def nt_build_number(blob):
    """Read the exported kernel data variable; resources can retain an old build.

    NT 3.51's actual NtBuildNumber is 1057 while its version resource says
    1025. This reads PE metadata/data only and never executes the input.
    """
    try:
        if blob[:2] != b'MZ':return None
        u=lambda n:struct.unpack_from('<I',blob,n)[0]
        pe=u(0x3c)
        if blob[pe:pe+4] != b'PE\0\0':return None
        opt=pe+24;magic=struct.unpack_from('<H',blob,opt)[0]
        if magic not in (0x10b,0x20b):return None
        count=struct.unpack_from('<H',blob,pe+6)[0]
        if not 0<count<=96:return None
        sections=opt+struct.unpack_from('<H',blob,pe+20)[0]
        def offset(rva):
            for i in range(count):
                vs,va,rs,raw=struct.unpack_from('<IIII',blob,sections+i*40+8)
                if va<=rva<va+min(vs or rs,rs) and raw+rva-va<len(blob):return raw+rva-va
            raise ValueError('RVA outside backed file bytes')
        directory=opt+(112 if magic==0x20b else 96)
        rva,size=u(directory),u(directory+4)
        if not rva:return None
        exp=offset(rva);names=offset(u(exp+32));ords=offset(u(exp+36));funcs=offset(u(exp+28))
        name_count=u(exp+24)
        if name_count>65536:return None
        for i in range(name_count):
            position=offset(u(names+4*i))
            if blob[position:position+14] != b'NtBuildNumber\0':continue
            ordinal=struct.unpack_from('<H',blob,ords+2*i)[0]
            if ordinal>=u(exp+20):return None
            value_rva=u(funcs+4*ordinal)
            if rva<=value_rva<rva+size:return None  # Forwarder, not a DWORD.
            value=u(offset(value_rva))
            return dict(rva=value_rva,raw=value,build=value&0xffff)
    except (ValueError,IndexError,struct.error):
        return None
    return None


def inspect_iso(path,probe):
    try:result=facts.inspect(path)
    except Exception as error:result={'metadata_error':f'{type(error).__name__}: {error}'}
    response=subprocess.run([str(probe),str(path)],capture_output=True,timeout=180)
    try:result['usos']=json.loads(response.stdout+response.stderr)
    except (ValueError,UnicodeError):result['usos']={'probe_error':(response.stdout+response.stderr).decode(errors='replace')[:500]}
    try:
        with path.open('rb') as stream:
            volume=facts.ISO(stream)
            result['root_markers']=[name for name in volume.entries if '/' not in name and not name.endswith(('.exe','.dll','.sif','.ini','.inf','.reg'))][:80]
            result['source_directories']=[n for n in ('win95','win98','win9x','i386','amd64','sources','setup','cmpnents') if n in volume.entries]
            binaries={}
            for name in ('i386/ntdll.dl_','i386/ntoskrnl.ex_','i386/ntdll.dll','i386/ntoskrnl.exe','i386/setupldr.bin','i386/setupdd.sy_','amd64/ntoskrnl.ex_'):
                if name not in volume.entries:continue
                blob=volume.read(name)
                if blob.startswith((b'MSCF',b'SZDD')):blob=cab.unpack(blob)
                version=facts.pe_facts(blob)
                if 'ntoskrnl' in name and version:
                    number=nt_build_number(blob)
                    if number:version['nt_build_number']=number
                if version:binaries[name]=version
            result['binary_versions']=binaries
            for name in ('sources/install.wim','sources/install.esd','sources/install.swm'):
                if name not in volume.entries:continue
                header=volume.read(name,length=208)
                import struct
                encoded,offset,size=struct.unpack_from('<QQQ',header,72)
                if encoded&0x00ffffffffffffff!=size or size>facts.LIMIT:continue
                tree=ET.fromstring(volume.read(name,offset,size).decode('utf-16'))
                result['image_versions']=[{'index':x.get('INDEX'),'name':x.findtext('NAME'),
                    'version':{n.tag:n.text for n in x.findall('WINDOWS/VERSION/*')},
                    'edition':x.findtext('WINDOWS/EDITIONID'),'arch':x.findtext('WINDOWS/ARCH'),
                    'language':x.findtext('WINDOWS/LANGUAGES/DEFAULT')} for x in tree.findall('IMAGE')]
    except Exception as error:result['extra_metadata_error']=f'{type(error).__name__}: {error}'
    return result


def inspect_file(row,probe):
    if row['beta']:return {'path':row['path'],'sha256':row['sha256'],'status':'out of scope: beta; no content inspection'}
    path=Path(row['path'])
    if path.suffix.lower()=='.iso':return {'path':str(path),'sha256':row['sha256'],'facts':inspect_iso(path,probe)}
    if path.suffix.lower()=='.img':return {'path':str(path),'sha256':row['sha256'],'status':'floppy/image; optical parser not applicable'}
    listing=subprocess.run([str(SEVEN),'l','-slt',str(path)],capture_output=True,text=True,errors='replace',timeout=60)
    members=[]
    for block in listing.stdout.split('\n\n'):
        properties=dict(line.split(' = ',1) for line in block.splitlines() if ' = ' in line)
        name=properties.get('Path','')
        if name.lower().endswith(('.iso','.img','.ima')) and name!=str(path):members.append(properties)
    result={'path':str(path),'sha256':row['sha256'],'members':members,'listing_exit':listing.returncode,'images':[]}
    for member in members:
        with tempfile.TemporaryDirectory(prefix='media-',dir=SCRATCH) as temporary:
            work=Path(temporary)
            r=subprocess.run([str(SEVEN),'e','-y','-o'+str(work),str(path),member['Path']],capture_output=True,timeout=300)
            if r.returncode:result['images'].append({'member':member['Path'],'error':'7-Zip extraction failed'});continue
            children=[p for p in work.iterdir() if p.suffix.lower() in ('.iso','.img','.ima')]
            for child in children:
                with child.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
                image={'member':member['Path'],'sha256':digest,'bytes':child.stat().st_size}
                if child.suffix.lower()=='.iso':image['facts']=inspect_iso(child,probe)
                else:image['status']='floppy/image; optical parser not applicable'
                result['images'].append(image)
    return result


def main(a):
    SCRATCH.mkdir(parents=True,exist_ok=True)
    rows=json.loads(a.inventory.read_text(encoding='utf-8'))['files']
    previous={}
    if a.previous:previous={r['sha256']:r for r in json.loads(a.previous.read_text(encoding='utf-8'))}
    def one(row):
        if row['sha256'] in previous:return dict(previous[row['sha256']],path=row['path'])
        try:return inspect_file(row,a.probe)
        except Exception as error:return {'path':row['path'],'sha256':row['sha256'],'error':f'{type(error).__name__}: {error}'}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(one,rows))
    a.out.write_text(json.dumps(results,indent=2,ensure_ascii=False),encoding='utf-8')
    SCRATCH.rmdir()
    print('Media facts complete:',len(results),'inputs; archive scratch removed')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('inventory','probe','out'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--previous',type=Path)
    main(p.parse_args())
