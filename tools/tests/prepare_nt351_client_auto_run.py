"""Private frozen harness/plan for new NT351 client-policy fresh installation."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT.parent/'nt351-fresh'
SOURCE = OLD/'artifacts/coverage/nt351-irq-fresh01'
HERE = ROOT/'artifacts/coverage/nt351-client-auto-fresh01'
TAG = 'nt351-client-auto-fresh01'


def sha(data): return hashlib.sha256(data).hexdigest()


def main():
    manifest = json.loads((SOURCE/'harness-manifest.json').read_text(encoding='utf-8'))
    harness = HERE/'harness'
    if harness.exists() or (HERE/'plan.json').exists(): raise FileExistsError('Fresh private snapshot required')
    harness.mkdir(parents=True)
    files = {}
    for leaf, row in manifest['files'].items():
        data = (SOURCE/'harness'/leaf).read_bytes()
        if sha(data) != row['private_sha256']: raise ValueError('Closed frozen harness changed: '+leaf)
        text = data.decode('utf-8').replace(repr(str(OLD)),repr(str(ROOT)))
        if leaf == 'collect_nt351_success.py':
            original = "FILES=('NET351.STATUS','NET351.ON','USABILITY.TXT','POST.LOG','USOSNET351.SHA256')"
            if text.count(original) != 1: raise ValueError('Collector source contract changed')
            text = text.replace(original, "FILES=('NET351.STATUS','NET351.ON','USABILITY.TXT','POST.LOG','USOSNET351.SHA256','CLNT3511.REQ','CLNT3511.LOG','CLNT3511.ERR','C351NET.LOG')")
            text = text.replace('MAX_TOTAL=5*MAX_FILE+4096','MAX_TOTAL=9*MAX_FILE+4096')
        compile(text,str(harness/leaf),'exec')
        private = text.encode('utf-8')
        (harness/leaf).write_bytes(private)
        files[leaf] = dict(closed_source_sha256=sha(data),private_sha256=sha(private))
    profile = (SOURCE/'keyless.profile.ini').read_bytes()
    if sha(profile) != manifest['keyless_profile_sha256']: raise ValueError('Keyless profile changed')
    (HERE/'keyless.profile.ini').write_bytes(profile)
    catalog = (OLD/'artifacts/coverage/catalog.ndjson').read_bytes()
    if sha(catalog) != manifest['catalog_sha256']: raise ValueError('Closed catalog changed')
    (ROOT/'artifacts/coverage/catalog.ndjson').write_bytes(catalog)
    notify = (SOURCE/'notify_core.py').read_bytes()
    if sha(notify) != manifest['notify_core_sha256']: raise ValueError('Closed event helper changed')
    (HERE/'notify_core.py').write_bytes(notify)
    case, = json.loads((SOURCE/'plan.json').read_text(encoding='utf-8'))
    case['tag'] = TAG
    (HERE/'plan.json').write_bytes((json.dumps([case],indent=2)+'\n').encode('utf-8'))
    scripts = {}
    for leaf, row in manifest['observer_scripts'].items():
        data = (ROOT/'tools'/leaf).read_bytes()
        if sha(data) != row['sha256']: raise ValueError('Frozen observer script mismatch: '+leaf)
        scripts[leaf] = row
    report = dict(tag=TAG,source_closed_harness=str(SOURCE),files=files,observer_scripts=scripts,
        keyless_profile_sha256=sha(profile),catalog_sha256=sha(catalog),notify_core_sha256=sha(notify),
        plan_sha256=sha((HERE/'plan.json').read_bytes()),plan_changed_fields=['tag'],
        private_harness=str(harness),closed_source_manifest_sha256=sha((SOURCE/'harness-manifest.json').read_bytes()),
        harness_change='Root relocation; four own policy/native-log names added to bounded stopped collector, total limit9MiB',
        driver_expected_sha256=case['expected_own_driver_sha256'],runtime_pass=False)
    (HERE/'harness-manifest.json').write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    with zipfile.ZipFile(HERE/'harness-snapshot.zip','x',compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(harness.glob('*.py')): archive.write(path,path.name)
    print(json.dumps(dict(prepared=True,tag=TAG,files=len(files),plan_sha256=report['plan_sha256'])))


if __name__ == '__main__': main()
