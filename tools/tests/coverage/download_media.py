"""Download explicitly listed media to G:\\USOS-Kolekcja only, verify published hashes.

No account, product key, activation or execution of downloaded software.
No progress polling: stream each response until completion; print completion only.
"""
from pathlib import Path
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import shutil
import urllib.request

COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
MIN_FREE=100*1024**3


def download(row):
    target=(COLLECTION/row['relative']).resolve()
    if not target.is_relative_to(COLLECTION):raise ValueError('download path escapes collection')
    if shutil.disk_usage(COLLECTION).free<MIN_FREE:raise RuntimeError('less than 100 GiB free; downloads stopped')
    target.parent.mkdir(parents=True,exist_ok=True)
    part=target.with_name(target.name+'.part')
    if target.exists() or part.exists():raise FileExistsError('refusing to overwrite existing media or partial file')
    hashes={'sha256':hashlib.sha256(),row['hash_algorithm']:hashlib.new(row['hash_algorithm'])}
    try:
        request=urllib.request.Request(row['url'],headers={'User-Agent':'USOS-media-coverage/1.0'})
        with urllib.request.urlopen(request,timeout=90) as response,part.open('xb') as output:
            content_type=response.headers.get('Content-Type','')
            if 'text/html' in content_type:raise ValueError('source returned HTML instead of media')
            final_url=response.url
            while chunk:=response.read(1024*1024):
                output.write(chunk)
                for digest in hashes.values():digest.update(chunk)
        actual={k:v.hexdigest() for k,v in hashes.items()}
        if actual[row['hash_algorithm']].lower()!=row['published_hash'].lower():
            raise ValueError('published checksum mismatch; downloaded copy discarded')
        if row.get('bytes') and part.stat().st_size!=row['bytes']:raise ValueError('source size mismatch')
        size=part.stat().st_size;part.rename(target)
        return dict(row,status='downloaded and verified',sha256=actual['sha256'],bytes=size,
                    final_url=final_url,date=datetime.datetime.now(datetime.timezone.utc).isoformat())
    except Exception:
        part.unlink(missing_ok=True)
        raise


def write_index(rows):
    lines=['USOS media collection (local test inputs; never upload or commit media)',
           'Created for Windows coverage; binaries are read-only inputs after download.',
           'Folder -> file; original filename, source and checksum follow each entry.','']
    for r in rows:
        if not r.get('sha256'):continue
        lines += [r['relative'],f"  Original: {r['original_name']}",f"  Source: {r['page']}",
            f"  Download URL: {r['final_url']}",f"  Bytes: {r['bytes']}",f"  SHA-256: {r['sha256']}",
            f"  Published {r['hash_algorithm']}: {r['published_hash']} (MATCH)",
            f"  Identity (source claim; media inspection separate): {r['identity']}",f"  Downloaded: {r['date']}",'']
    (COLLECTION/'README.txt').write_text('\n'.join(lines),encoding='utf-8')


def main(a):
    rows=json.loads(a.plan.read_text(encoding='utf-8'))
    before=shutil.disk_usage(COLLECTION).free;results=[]
    # Two streams; VM concurrency is governed separately by the VM runner.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures={pool.submit(download,r):r for r in rows}
        for future in concurrent.futures.as_completed(futures):
            row=futures[future]
            try:result=future.result()
            except Exception as e:result=dict(row,status='not downloaded',error=f'{type(e).__name__}: {e}')
            results.append(result)
            print(json.dumps({'media':result['relative'],'status':result['status'],
                              'error':result.get('error')},ensure_ascii=False),flush=True)
    results.sort(key=lambda r:r['relative'])
    (COLLECTION/'download-manifest.json').write_text(json.dumps(results,indent=2,ensure_ascii=False),encoding='utf-8')
    write_index(results)
    a.out.write_text(json.dumps({'free_before':before,'free_after':shutil.disk_usage(COLLECTION).free,
                                'files':results},indent=2,ensure_ascii=False),encoding='utf-8')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    main(p.parse_args())
