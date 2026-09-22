"""Reproduce the NVMe bundle from two hash-pinned, original Microsoft MSUs.

Usage: python tools/prepare_windows7_nvme_assets.py KB2990941.msu KB3087873.msu
Only Windows expand.exe is used to reconstruct Microsoft's CAB/CIX payloads.
The installers/MSUs are never executed and the host Windows is never serviced.
"""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,tempfile,xml.etree.ElementTree as ET,zipfile
from build_windows7_nvme import build_helpers

PACKAGES=[
    ('KB2990941','d1acbdd8652d6c78ce284bf511f3a7f5f776a0a91357aca060039a99c6a93a16','18615','22823','Windows6.1-KB2990941-v3-x64.cab'),
    ('KB3087873','6d511fb126495579f681ecf5f4052dcb2c4c21154a0a9faa5d9d8ae06d4be538','18969','23172','Windows6.1-KB3087873-v2-x64.cab'),
]
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'zig-out/windows7-nvme';VENDOR=ROOT/'tools/vendor/windows7-nvme'

def make(sources):
    if len(sources)!=2:raise ValueError('Pass the original KB2990941-v3 and KB3087873-v2 x64 MSUs')
    for p,(_,digest,*_) in zip(sources,PACKAGES):
        if hashlib.sha256(p.read_bytes()).hexdigest()!=digest:raise ValueError('MSU checksum mismatch: '+str(p))
    build_helpers(ROOT,OUT)
    work=Path(tempfile.mkdtemp(prefix='asset-source-',dir=OUT)).resolve()
    assert work.is_relative_to(OUT.resolve())
    env=dict(os.environ,TEMP=str(OUT/'tmp'),TMP=str(OUT/'tmp'))
    files={};rows={};paths={'Windows/System32/drivers/stornvme.sys'}
    try:
        with (OUT/'asset-extraction.log').open('wb') as log:
            for msu,(kb,digest,gdr,ldr,cabname) in zip(sources,PACKAGES):
                package=work/kb;package.mkdir()
                subprocess.run(['expand.exe','-F:*',str(msu),str(package)],env=env,stdout=log,stderr=log,check=True)
                cab=next(p for p in package.iterdir() if p.name.lower()==cabname.lower())
                files['updates/'+cabname]=cab.read_bytes()
                expanded=package/'expanded';expanded.mkdir()
                subprocess.run(['expand.exe','-F:*',str(cab),str(expanded)],env=env,stdout=log,stderr=log,check=True)
                for branch,revision in [('gdr',gdr),('ldr',ldr)]:
                    for manifest in sorted(expanded.glob('amd64_*.manifest')):
                        if '_6.1.7601.'+revision+'_none_' not in manifest.name:continue
                        for item in ET.parse(manifest).getroot().iter():
                            if not item.tag.endswith('}file') or not item.get('destinationPath'):continue
                            source=expanded/manifest.stem/item.get('sourceName',item.get('name'))
                            dest=item.get('destinationPath').replace('\\','/').rstrip('/')
                            for var,replacement in [('$(runtime.drivers)','Windows/System32/drivers'),('$(runtime.system32)','Windows/System32'),('$(runtime.wbem)','Windows/System32/wbem'),('$(runtime.bootDrive)','')]:dest=dest.replace(var,replacement)
                            if '$' in dest:raise ValueError('Unknown destination: '+dest)
                            path=(dest+'/'+item.get('name')).lstrip('/')
                            if path.startswith('sources/'):group='setup'
                            elif path.lower().endswith('/classpnp.sys'):group='classpnp'
                            elif path.lower() in ('windows/system32/drivers/storport.sys','windows/system32/iologmsg.dll','windows/system32/wbem/stortrace.mof'):group='storport'
                            else:raise ValueError('Unexpected bootstrap file: '+path)
                            result=subprocess.run([str(OUT/'pe-file-version.exe'),str(source)],capture_output=True)
                            version=result.stdout.decode().strip() if result.returncode==0 else '-'
                            files['bootstrap/'+branch+'/'+path]=source.read_bytes()
                            rows[(branch,path.lower())]='\t'.join([branch,group,path,version]);paths.add(path)
                    if kb=='KB2990941':
                        driver=next(p for p in expanded.glob('amd64_stornvme.inf_*') if p.is_dir() and '_6.1.7601.'+revision+'_none_' in p.name)
                        inf=(driver/'stornvme.inf').read_bytes();needle=hashlib.sha1(inf).digest()
                        catalogs=[p for p in expanded.glob('*.cat') if '_bf~' not in p.name and needle in p.read_bytes()]
                        if len(catalogs)!=1:raise ValueError('Expected one original catalog for '+branch)
                        files['nvme/'+branch+'/stornvme.inf']=inf
                        files['nvme/'+branch+'/stornvme.sys']=(driver/'stornvme.sys').read_bytes()
                        files['nvme/'+branch+'/MicrosoftNVMe.cat']=catalogs[0].read_bytes()
        files['files.tsv']=('\n'.join(sorted(rows.values()))+'\n').encode()
        files['paths.txt']=('\n'.join('/'+p for p in sorted(paths))+'\n').encode()
        VENDOR.mkdir(parents=True,exist_ok=True)
        archive=VENDOR/'assets.zip'
        with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            for name,data in sorted(files.items()):
                info=zipfile.ZipInfo(name,date_time=(2026,9,13,0,0,0));info.external_attr=0o100644<<16;info.compress_type=zipfile.ZIP_DEFLATED
                z.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
        manifest={'format':1,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'sources':[{'kb':kb,'msu_sha256':digest} for kb,digest,*_ in PACKAGES],'files':{name:hashlib.sha256(data).hexdigest() for name,data in sorted(files.items())}}
        (VENDOR/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print('NVMe bundle:',len(files),'files;',archive.stat().st_size,'bytes;',manifest['archive_sha256'])
    finally:
        if not work.is_relative_to(OUT.resolve()):raise RuntimeError('Refusing cleanup outside the local build directory')
        shutil.rmtree(work)

if __name__=='__main__':make([Path(p).resolve() for p in sys.argv[1:]])
