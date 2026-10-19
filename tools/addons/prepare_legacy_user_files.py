"""Prepare pinned user-supplied WinSPatcher members on the host, without downloads.

The target must be a dedicated private folder, separate from all sources.
The operator can later copy its USOS/WSP tree into DATA/Addons. This tool does
not select disks, alter the manifest, build an MS release asset or install files.
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, sys, tempfile, zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import legacy_manifest as lm
import stage_legacy_pack as stage

def prepare(manifest, sources, target, inno=None):
    target=target.resolve()
    for source in sources:
        source=source.resolve()
        if target==source or target.is_relative_to(source) or source.is_relative_to(target):
            raise ValueError('target must be separate from every source')
        if not source.exists():raise ValueError('source does not exist: '+str(source))
    if target.exists() and any(target.iterdir()):raise ValueError('target must be empty')
    rows=[]
    for package in manifest.packages:
        if package.get('source')!='user' or package.get('status')=='missing':continue
        for file in package.files():
            if 'winspatcher' in file['original'].lower() and '!' in file['original']:
                if not lm.NAME83.fullmatch(package.get('dir')) or not lm.NAME83.fullmatch(file['stage']):
                    raise ValueError('unsafe manifest destination')
                rows.append((package,file))
    wanted={(f['size'],f['sha256']):f['sha256'] for _,f in rows}
    target.mkdir(parents=True,exist_ok=True); scratch=target/'.work';scratch.mkdir()
    old_temp=tempfile.tempdir;old_env={k:os.environ.get(k) for k in ('TEMP','TMP')}
    original_tool=stage.innoextract_tool
    try:
        tempfile.tempdir=str(scratch);os.environ.update(TEMP=str(scratch),TMP=str(scratch))
        if inno is not None:
            inno=inno.resolve()
            if not inno.is_file():raise ValueError('innoextract does not exist')
            stage.innoextract_tool=lambda:inno
        finder=stage.Finder(wanted)
        for source in sources:
            if source.is_dir():finder.scan(source)
            else:
                finder._offer(source.stat().st_size,source.read_bytes)
                if zipfile.is_zipfile(source):
                    with zipfile.ZipFile(source) as z:finder.scan_zip(z,1)
                elif source.suffix.lower()=='.iso' and finder.seven:finder.scan_iso(source)
                elif source.suffix.lower()=='.exe':finder.scan_inno(source)
        records=[]
        for package,file in rows:
            blob=finder.data.get(file['sha256']);relative=Path('USOS/WSP')/package.get('dir')/file['stage']
            record={'package':package.id,'path':relative.as_posix(),'sha256':file['sha256'],'size':file['size'],'status':'missing'}
            if blob is not None:
                dest=target/relative;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(blob)
                if dest.stat().st_size!=file['size'] or hashlib.sha256(dest.read_bytes()).hexdigest()!=file['sha256']:
                    raise OSError('readback failed: '+str(relative))
                record['status']='prepared'
            records.append(record)
        result={'prepared':sum(r['status']=='prepared' for r in records),'missing':sum(r['status']=='missing' for r in records),'files':records}
        (target/'IMPORT.JSON').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        return result
    finally:
        stage.innoextract_tool=original_tool;tempfile.tempdir=old_temp
        for key,value in old_env.items():
            if value is None:os.environ.pop(key,None)
            else:os.environ[key]=value
        shutil.rmtree(scratch)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--manifest',type=Path,default=lm.MANIFEST)
    ap.add_argument('--source',type=Path,action='append',required=True)
    ap.add_argument('--target',type=Path,required=True)
    ap.add_argument('--innoextract',type=Path)
    a=ap.parse_args();manifest=lm.Manifest.load(a.manifest)
    errors=lm.validate(manifest)
    if errors:raise SystemExit('\n'.join(errors))
    result=prepare(manifest,a.source,a.target,a.innoextract)
    print(f"prepared={result['prepared']} missing={result['missing']}; metadata: {a.target/'IMPORT.JSON'}")
    return 0

if __name__=='__main__':raise SystemExit(main())
