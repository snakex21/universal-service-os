"""Read-only archive inventory: save metadata only, never a Windows payload.

Use --sources for the owner's existing Win*.zip folder. Nested ISO and Inno
containers use an explicit private scratch directory; no downloads occur.
"""
from pathlib import Path
import argparse,csv,hashlib,io,json,os,re,shutil,subprocess,tempfile,time,zipfile,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import legacy_manifest as lm

class Inventory:
    def __init__(self,manifest,work,seven,inno=None):
        self.work,self.seven,self.inno=work,seven,inno
        self.wanted={f['size'] for p in manifest.packages if p.id!='speechsdk51-langpack' for f in p.files() if f['sha256'] and f['size']}
        self.matches={};self.unindexed=[];self.archives={};self.unpacked={}
    def offer(self,data,label):
        if len(data) in self.wanted:
            digest=hashlib.sha256(data).hexdigest();self.matches[(len(data),digest)]=label
            if zipfile.is_zipfile(io.BytesIO(data)):
                with zipfile.ZipFile(io.BytesIO(data)) as z:self.unpacked[digest]=sum(i.file_size for i in z.infolist() if not i.is_dir())
            return digest
        return ''
    def members7(self,path):
        r=subprocess.run([self.seven,'l','-slt','-sccUTF-8',str(path)],capture_output=True)
        items=[]
        for block in r.stdout.decode('utf-8',errors='replace').split('\n\n'):
            a={}
            for line in block.splitlines():
                if ' = ' in line:k,v=line.split(' = ',1);a[k]=v.strip()
            if a.get('Size','').isdigit() and a.get('Folder')!='+':items.append((a.get('Path',''),int(a['Size'])))
        return items
    def iso(self,data,label,digest):
        file=self.work/'nested.iso';file.write_bytes(data)
        try:
            entries=self.members7(file)
            if digest:self.unpacked[digest]=sum(size for name,size in entries if '/' not in name.replace('\\','/') and lm.NAME83.fullmatch(name.upper()))
            for name,size in entries:
                if size in self.wanted:
                    r=subprocess.run([self.seven,'e','-so',str(file),name],capture_output=True)
                    if r.returncode==0:self.offer(r.stdout,label+'!'+name)
        finally:file.unlink(missing_ok=True)
    def scan_zip(self,z,label,depth=0):
        for info in z.infolist():
            if info.is_dir():continue
            low=info.filename.lower();nested=depth<3 and low.endswith(('.zip','.iso','.exe')) and info.file_size<=536870912
            if info.file_size not in self.wanted and not nested:continue
            data=z.read(info);where=label+'!'+info.filename;digest=self.offer(data,where)
            if nested and zipfile.is_zipfile(io.BytesIO(data)):
                with zipfile.ZipFile(io.BytesIO(data)) as child:self.scan_zip(child,where,depth+1)
            elif nested and low.endswith('.iso'):self.iso(data,where,digest)
            elif nested and b'Inno Setup' in data[:4<<20]:
                if not self.inno:self.unindexed.append(where+' (Inno: tool unavailable)');continue
                exe=self.work/'inno.exe';dest=self.work/'inno';exe.write_bytes(data);dest.mkdir(exist_ok=True)
                try:
                    r=subprocess.run([self.inno,'-q','-s','-e','-d',str(dest),str(exe)],capture_output=True)
                    if not r.returncode:
                        for f in dest.rglob('*'):
                            if f.is_file() and f.stat().st_size in self.wanted:self.offer(f.read_bytes(),where+'!'+f.relative_to(dest).as_posix())
                    else:self.unindexed.append(where+' (Inno extraction failed)')
                finally:shutil.rmtree(dest);exe.unlink()
    def run(self,source):
        for name in ('Win95.zip','Win98.zip','Win9x.zip','WinME.zip','WinNT.zip'):
            file=source/name
            if not file.is_file():self.unindexed.append(name+' absent');continue
            self.archives[name]={'size':file.stat().st_size,'sha256':hashlib.file_digest(file.open('rb'),'sha256').hexdigest()}
            with zipfile.ZipFile(file) as z:self.scan_zip(z,name)

def write_tables(m,inv,output):
    systems=[('95','95OSR2'),('98 FE','98FE'),('98 SE','98SE'),('ME','ME'),('NT4 WS','NT4'),('NT4 Server','NT4')]
    rows=[];sizes=[]
    for title,os_id in systems:
        for lang in ('PL','EN'):
            variants=['95OSR2','95OSR21','95OSR25'] if title=='95' else [os_id]
            selected=set()
            for os_ in variants:selected.update(lm.resolve(m,os_,lang,'6a' if os_id=='NT4' else '',True,[p.id for p in m.packages if p.tier=='option']).order)
            for p in m.packages:
                if p.id not in selected and not (p.get('status') and any(lm.applicable(m,p,o,lang,'6a' if os_id=='NT4' else '') for o in variants)):continue
                files=p.files() or [dict(original='-',sha256='',size=0)]
                for f in files:
                    origin=inv.matches.get((f['size'],f['sha256']),'')
                    status=p.get('status') or ('ok' if origin or p.tier=='group' else 'missing')
                    redist='warunkowa; decyzja opiekuna' if p.get('source')=='release' else 'GPL: ze zgodnym źródłem' if p.get('license').startswith('GPL') else 'plik użytkownika'
                    rows.append([title,lang,p.id,p.get('provides') or p.get('name_en'),f['original'],f['sha256'],str(f['size']),p.get('source'),p.get('license'),redist,status,origin or ('not indexed: '+p.get('status') if p.get('status') else 'not found in indexed containers')])
            default=[]
            excludes=[p.id for p in m.packages if p.id.startswith('dun') or (os_id=='NT4' and p.id.startswith('nt4-sp6a-'))]
            for os_ in variants:
                for pid in lm.resolve(m,os_,lang,'6a' if os_id=='NT4' else '',True,[],excludes).order:
                    if pid not in default:default.append(pid)
            pinned=sum(f['size'] for pid in default for f in m.find(pid).files())
            available=0;missing=0
            for pid in default:
                p=m.find(pid)
                for f in p.files():
                    if (f['size'],f['sha256']) in inv.matches:available+=inv.unpacked.get(f['sha256'],f['size'])
                    else:missing+=1
            sizes.append(dict(system=title,lang=lang,packages=len(default),pinned_input_bytes=pinned,available_payload_estimate=available,missing_files=missing))
    header=['system','language','package','version/capabilities','file','sha256','size','source','license','redistribution','status','archive member']
    output.mkdir(parents=True,exist_ok=True)
    (output/'legacy-compat-inventory-2026-10-20.tsv').write_text('\t'.join(header)+'\n'+''.join('\t'.join(s.replace('\t',' ').replace('\n',' ') for s in row)+'\n' for row in rows),encoding='utf-8')
    text='# Legacy pack inventory, 2026-10-20\n\nMetadata from the supplied archives; no installers executed or downloaded.\n\n'
    text+='|System|Language|Default packages|Pinned input MiB|Available payload estimate MiB|Missing files|\n|---|---|---:|---:|---:|---:|\n'
    for s in sizes:text+=f'|{s["system"]}|{s["lang"]}|{s["packages"]}|{s["pinned_input_bytes"]/1048576:.1f}|{s["available_payload_estimate"]/1048576:.1f}|{s["missing_files"]}|\n'
    text+='\nInput sizes are not installed Windows sizes. The payload estimate expands matching ZIP/ISO containers from their directory metadata; it excludes unknown/missing inputs, NT4 OEM duplication, runner files, installer caches and installed applications. Stage duration depends on the medium; no physical timing is claimed.\n\n'
    for title,_ in systems:
        text+=f'## {title}\n\n|Language|Package / version|File|SHA-256 (prefix)|Bytes|Source|License / redistribution|Status|\n|---|---|---|---|---:|---|---|---|\n'
        for r in rows:
            if r[0]==title:text+='|'+'|'.join(x.replace('|',' / ') for x in (r[1],r[2]+' / '+r[3],r[4],r[5][:16],r[6],r[7],r[8]+' / '+r[9],r[10]))+'|\n'
        text+='\n'
    old_path=Path(__file__).resolve().parents[2]/'tools/addons/inventory-2026-09-30.tsv'
    with old_path.open(encoding='utf-8') as old_file:old_rows=list(csv.DictReader(old_file,delimiter='\t'))
    verified={(r[5],r[6]) for r in rows if r[5] and not r[11].startswith(('not found','not indexed'))}
    old_hashes={r['sha256'] for r in old_rows}
    exact={(r['sha256'],r['size']) for r in old_rows if r['size']}
    same=len(verified&exact);hash_only=sum(h in old_hashes and (h,n) not in exact for h,n in verified)
    mismatches=sum(any(r['sha256']==h and r['size'] and r['size']!=n for r in old_rows) for h,n in verified)
    text+=f'## Comparison with 2026-09-30 metadata\n\nThe old TSV has {len(old_rows)} rows. Of the {len(verified)} verified input digests represented in this per-system table, {same} match an old hash and size, {hash_only} have an old hash with no recorded size, and {len(verified)-same-hash_only} are newly expanded container members or other inputs absent from that table. Conflicting non-empty old sizes: {mismatches}. The inventory also verifies additional inputs outside the currently applicable system rows.\n\n'
    text+='## Input integrity\n\n'+''.join(f'- `{name}`: {v["size"]} bytes, SHA-256 `{v["sha256"]}`.\n' for name,v in inv.archives.items())
    text+='\n## Not fully indexed\n\n'+(''.join('- '+x+'\n' for x in inv.unindexed) or 'None.\n')
    text+='\nA missing entry means not verified in the indexed containers. Explicitly omitted 1.0 items are not searched separately. KernelEx remains unavailable until matching GPL source is supplied. Full hashes and member paths are in the adjacent TSV. License classifications record the maintainer decision, not an independent legal determination.\n'
    (output/'legacy-compat-inventory-2026-10-20.md').write_text(text,encoding='utf-8')
    return sizes

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--sources',type=Path,required=True);ap.add_argument('--scratch',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--seven',required=True);ap.add_argument('--inno');a=ap.parse_args()
    a.scratch.mkdir(parents=True,exist_ok=True);tempfile.tempdir=str(a.scratch);os.environ.update(TEMP=str(a.scratch),TMP=str(a.scratch));start=time.monotonic()
    m=lm.Manifest.load();inv=Inventory(m,a.scratch,a.seven,a.inno);inv.run(a.sources);sizes=write_tables(m,inv,a.output)
    result=dict(elapsed_seconds=time.monotonic()-start,verified_hashes=len(inv.matches),unindexed=inv.unindexed,sizes=sizes)
    (a.scratch/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result));return 0
if __name__=='__main__':raise SystemExit(main())
