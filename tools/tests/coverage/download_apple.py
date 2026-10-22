"""Download selected full Apple installers; keep media and its index on G:.

The input is metadata from Apple's public software-update catalogue and
English distribution files, not a third-party ISO. Do not execute packages.
This extends the user's media collection; it is not a macOS install test.
"""
from pathlib import Path
import argparse
import concurrent.futures
import importlib.util
import json
import datetime
import hashlib
import shutil
import urllib.parse
import urllib.request

HERE = Path(__file__).resolve().parent
CATALOG_URL = 'https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog'
spec = importlib.util.spec_from_file_location('coverage_download', HERE/'download_media.py')
downloader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(downloader)
spec = importlib.util.spec_from_file_location('coverage_apple_integrity',HERE/'apple_integrity.py')
integrity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integrity)


def plan(source):
    rows = []
    for product in source:
        version = product['distribution_facts']['VERSION']
        build = product['distribution_facts']['BUILD']
        package, = product['packages']
        host = urllib.parse.urlparse(package['URL']).hostname
        if host != 'swcdn.apple.com':
            raise ValueError('Expected Apple CDN')
        digest = package['Digest']
        if len(digest) != 40:
            raise ValueError('Expected catalogue SHA-1')
        rows.append(dict(
            relative=f"macOS/{product['family']}/macOS {product['family']} {version} {build} InstallAssistant.pkg",
            original_name='InstallAssistant.pkg',
            identity=f"macOS {product['family']} {version}, build {build}; full installer package; multilingual",
            page=product['distribution_url'], url=package['URL'], bytes=package['Size'],
            hash_algorithm='sha1', published_hash=digest,
            hash_scope='compressed-XAR-TOC', catalogue_url=CATALOG_URL,
            apple_product=product['product'], kind='full-installer-package',
            integrity_url=package.get('IntegrityDataURL')))
    return rows


def download_package(row):
    target = (downloader.COLLECTION/row['relative']).resolve()
    if not target.is_relative_to(downloader.COLLECTION/'macOS'):
        raise ValueError('Apple media path escapes collection')
    if shutil.disk_usage(downloader.COLLECTION).free < downloader.MIN_FREE:
        raise RuntimeError('Less than 100 GiB free')
    target.parent.mkdir(parents=True,exist_ok=True)
    part = target.with_name(target.name+'.part')
    if target.exists() or part.exists():
        raise FileExistsError('Refusing to overwrite media or a partial file')
    for url in (row['url'],row['integrity_url']):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != 'https' or parsed.hostname != 'swcdn.apple.com':
            raise ValueError('Expected verified HTTPS Apple CDN URL')
    with urllib.request.urlopen(row['integrity_url'],timeout=90) as response:
        manifest = response.read(4*1024**2)
    chunks = integrity.chunk_manifest(manifest,row['bytes'])
    manifest_path = target.with_name(target.name+'.integrityDataV1')
    manifest_path.write_bytes(manifest)
    full = hashlib.sha256()
    total = 0
    try:
        request = urllib.request.Request(row['url'],headers={'User-Agent':'USOS-media-coverage/1.0'})
        with urllib.request.urlopen(request,timeout=90) as response, part.open('xb') as output:
            if response.status != 200:
                raise ValueError('Expected a complete package response')
            for expected_size, expected_hash in chunks:
                remaining = expected_size
                chunk_hash = hashlib.sha256()
                while remaining:
                    data = response.read(min(1024**2,remaining))
                    if not data:
                        raise ValueError('Truncated Apple package')
                    output.write(data); full.update(data); chunk_hash.update(data)
                    total += len(data); remaining -= len(data)
                if chunk_hash.digest() != expected_hash:
                    raise ValueError('Apple package chunk SHA-256 differs')
            if response.read(1) or total != row['bytes']:
                raise ValueError('Apple package size differs')
        with part.open('rb') as stream:
            toc = integrity.verify_xar_toc(stream,row['published_hash'])
        part.rename(target)
        return dict(row,status='downloaded and verified',bytes=total,sha256=full.hexdigest(),
            final_url=row['url'],date=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            verification='Apple catalogue compressed-XAR-TOC SHA-1; all HTTPS manifest chunks SHA-256',
            integrity_manifest_sha256=hashlib.sha256(manifest).hexdigest(),
            integrity_chunks=len(chunks), integrity_signature=False, toc=toc)
    except Exception:
        part.unlink(missing_ok=True)
        raise


def write_index(rows):
    root = downloader.COLLECTION/'macOS'
    lines = [
        'Apple macOS local test media — downloaded directly from Apple',
        'Full InstallAssistant.pkg packages, NOT bootable ISO files.',
        'The installer must still be prepared for the intended boot flow.',
        'Package downloads are not evidence that macOS boots on this PC.',
        'Source method: https://support.apple.com/102662',
        '',
    ]
    for row in rows:
        lines += [row['relative'], '  '+row['identity'], '  Status: '+row['status']]
        if row.get('sha256'):
            lines += [f"  Original: {row['original_name']}", f"  Source: {row['page']}",
                      f"  Download URL: {row['final_url']}", f"  Bytes: {row['bytes']}",
                      f"  SHA-256: {row['sha256']}",
                      f"  Apple catalogue compressed-XAR-TOC SHA-1: {row['published_hash']} (MATCH)",
                      f"  All {row['integrity_chunks']} chunks SHA-256: MATCH (manifest fetched over HTTPS; method 2 is not signed)",
                      f"  Downloaded: {row['date']}"]
        else:
            lines += ['  Error: '+row.get('error', 'unknown')]
        lines += ['']
    root.mkdir(parents=True, exist_ok=True)
    (root/'README.txt').write_text('\n'.join(lines), encoding='utf-8')
    (root/'download-manifest.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')


def main(args):
    rows = plan(json.loads(args.selected.read_text(encoding='utf-8')))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.with_name('apple-download-plan.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
    print(f"Apple plan: {len(rows)} full packages, {sum(r['bytes'] for r in rows)/1024**3:.2f} GiB", flush=True)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        pending = {pool.submit(download_package, row): row for row in rows}
        for future in concurrent.futures.as_completed(pending):
            row = pending[future]
            try:
                result = future.result()
            except Exception as error:
                result = dict(row, status='not downloaded', error=f'{type(error).__name__}: {error}')
            results.append(result)
            print(json.dumps({k:result[k] for k in ('relative','status')}, ensure_ascii=False), flush=True)
    results.sort(key=lambda r:r['relative'])
    write_index(results)
    args.out.write_text(json.dumps(results, indent=2), encoding='utf-8')
    if any(row['status'] != 'downloaded and verified' for row in results):
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selected', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    main(parser.parse_args())
