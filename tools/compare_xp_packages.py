"""Compare two XP UEFI-CSM packages (initramfs-xp) by content. Read-only.

Every driver-bundle entry is either byte-identical, or: cabinets are expanded
and every contained file compared (only CFFILE date/time may differ), hives
are parsed and every key and value compared (only key LastWriteTime and
header bookkeeping may differ), and the bundle manifests may differ only in
the hashes of those files. Other entries are identical, equal to the current
micro-Linux base (base update), or listed with a diff as intended changes.

  python tools/compare_xp_packages.py OLD NEW --base J:/EFI/USOS/micro-linux/initramfs-usos [--json out.json]
Exit status 0 only if there is no unexplained difference.
"""
from pathlib import Path
import argparse, difflib, gzip, hashlib, json, shutil, stat, subprocess, sys, tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
from build_micro_linux import parse_newc
import xp_cab, xp_hive

SEVEN='C:/Program Files/7-Zip/7z.exe'
DRIVERS='usr/lib/usos/xp-drivers/'

def load(path):return parse_newc(gzip.decompress(Path(path).read_bytes()))
def sha(b):return hashlib.sha256(b).hexdigest()

def expand(data,work):
    work.mkdir(parents=True);cab=work/'x.cab';cab.write_bytes(data)
    subprocess.run([SEVEN,'x',str(cab),'-o'+str(work/'files'),'-y'],check=True,stdout=subprocess.DEVNULL)
    return {p.relative_to(work/'files').as_posix().lower():p.read_bytes() for p in (work/'files').rglob('*') if p.is_file()}

def compare_cab(old,new,work):
    meta=lambda d:[(e[0].lower(),e[1],e[2],e[3],e[6]) for e in xp_cab.entries(d)]
    if meta(old)!=meta(new):return 'cabinet file list/layout differs'
    a=expand(old,work/'old');b=expand(new,work/'new')
    if a.keys()!=b.keys():return 'expanded names differ'
    bad=[n for n in a if a[n]!=b[n]]
    if bad:return 'expanded content differs: '+', '.join(bad)
    stamps=sum(1 for x,y in zip(xp_cab.entries(old),xp_cab.entries(new)) if x[4:6]!=y[4:6])
    return None,'cabinet: %d files expanded and identical; %d CFFILE date/time differ'%(len(a),stamps)

def compare_hive(old,new):
    a=xp_hive.read_hive(old);b=xp_hive.read_hive(new)
    if {k:v for k,(_,v) in a.items()}!={k:v for k,(_,v) in b.items()}:
        keys=sorted(k for k in a.keys()|b.keys() if a.get(k,(0,None))[1]!=b.get(k,(0,None))[1])
        return 'hive keys/values differ: '+', '.join(keys[:20])
    values=sum(len(v) for _,v in a.values())
    times=sum(1 for k in a if a[k][0]!=b[k][0])
    return None,'hive: %d keys, %d values identical; %d key LastWriteTime differ'%(len(a),values,times)

def compare_bundle_manifest(old,new,equivalent):
    a=json.loads(old);b=json.loads(new)
    for m in (a,b):
        for name in equivalent:m['sha256'].pop(name,None)
    return None if a==b else 'bundle manifest differs beyond content-equivalent file hashes'

def compare_payload_list(old,new,equivalent):
    rows=lambda t:[l for l in t.decode().splitlines() if l.split('  ',1)[1] not in equivalent]
    return None if rows(old)==rows(new) else 'payload.sha256 differs beyond content-equivalent files'

def text_diff(old,new,name):
    try:a=old.decode('utf-8').splitlines();b=new.decode('utf-8').splitlines()
    except UnicodeDecodeError:return ['binary: %s -> %s'%(sha(old)[:16],sha(new)[:16])]
    return list(difflib.unified_diff(a,b,'old/'+name,'new/'+name,lineterm='',n=1))

def compare(old,new,base,intended=()):
    old=load(old);new=load(new);base=load(base) if base else {}
    report={'identical':0,'equivalent':{},'base_update':[],'intended':{},'unexplained':{}}
    bundles={n[len(DRIVERS):].split('/')[0] for n in old.keys()|new.keys() if n.startswith(DRIVERS)}
    work=Path(tempfile.mkdtemp(prefix='xp-compare-'))
    try:
        for n in sorted(old.keys()|new.keys()):
            if n.startswith(DRIVERS) and n.count('/')>=5 and n.split('/')[-1] in ('manifest.json','payload.sha256'):continue
            a=old.get(n);b=new.get(n)
            if a is not None and b is not None and a.mode==b.mode and a.data==b.data:report['identical']+=1;continue
            if a is None and n in base and base[n].mode==b.mode and base[n].data==b.data and n not in intended:report['base_update'].append(n+' (added)');continue
            if a is None or b is None:
                where='only in new' if a is None else 'only in old'
                (report['intended'] if n in intended else report['unexplained'])[n]=where;continue
            if a.mode!=b.mode and a.data==b.data:report['unexplained'][n]='mode %o -> %o'%(a.mode,b.mode);continue
            if n.startswith(DRIVERS):
                upper=n.upper()
                result=('not a cabinet or hive',)
                if upper.endswith('_') or upper.endswith('.CAB'):result=compare_cab(a.data,b.data,work/str(len(report['equivalent'])))
                elif upper.endswith('.HIV'):result=compare_hive(a.data,b.data)
                if isinstance(result,tuple) and result[0] is None:report['equivalent'][n]=result[1]
                else:report['unexplained'][n]=result if isinstance(result,str) else result[0]
                continue
            if n in base and base[n].data==b.data and n not in intended:report['base_update'].append(n);continue
            (report['intended'] if n in intended else report['unexplained'])[n]=text_diff(a.data,b.data,n)
        for bundle in sorted(bundles):
            prefix=DRIVERS+bundle+'/'
            equivalent={n[len(prefix):] for n in report['equivalent'] if n.startswith(prefix)}
            for name,check in (('payload.sha256',compare_payload_list),('manifest.json',compare_bundle_manifest)):
                a=old.get(prefix+name);b=new.get(prefix+name)
                if a is None or b is None:report['unexplained'][prefix+name]='missing';continue
                if a.data==b.data:report['identical']+=1;continue
                problem=check(a.data,b.data,equivalent)
                if problem:report['unexplained'][prefix+name]=problem
                else:report['equivalent'][prefix+name]='differs only in hashes of the content-equivalent files above';equivalent.add(name)
    finally:shutil.rmtree(work,ignore_errors=True)
    return report

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('old');p.add_argument('new');p.add_argument('--base');p.add_argument('--intended',action='append',default=[]);p.add_argument('--json',type=Path)
    a=p.parse_args()
    r=compare(a.old,a.new,a.base,set(a.intended))
    print('identical entries:',r['identical'])
    print('content-equivalent entries:',len(r['equivalent']))
    for n,why in r['equivalent'].items():print('  ',n,'--',why)
    print('base update (new entry == current micro-Linux base):',len(r['base_update']))
    for n in r['base_update']:print('  ',n)
    for title,key in (('intended changes','intended'),('UNEXPLAINED differences','unexplained')):
        print(title+':',len(r[key]))
        for n,d in r[key].items():
            print('  ',n);[print('     ',l) for l in (d if isinstance(d,list) else [d])]
    if a.json:a.json.write_text(json.dumps(r,indent=2)+'\n')
    sys.exit(1 if r['unexplained'] else 0)
