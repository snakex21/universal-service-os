"""Prepared private collector/console guards; no VM or guest disk reads."""
from pathlib import Path
import gzip
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT/'artifacts/coverage/nt35-client-auto-fresh01'


def main():
    spec = importlib.util.spec_from_file_location('prepared_nt35_collector', HERE/'harness/collect_nt35_success.py')
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    assert len(m.FILES) == 9 and m.MAX_TOTAL == 9*m.MAX_FILE+4096
    assert m.DRIVER_SHA256 == 'd94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
    parent = ROOT/'artifacts/nt35-client-auto/fixture-tests'
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=parent) as temp:
        d = Path(temp)
        def archive(extra=False):
            plain = io.BytesIO()
            with tarfile.open(fileobj=plain, mode='w') as tar:
                for name in (*m.FILES, 'DRIVER-READBACK.SHA256', *(('NOT-ALLOWED.TXT',) if extra else ())):
                    data = (m.DRIVER_SHA256+'\n').encode() if name.endswith('READBACK.SHA256') else b'own synthetic text\n'
                    item = tarfile.TarInfo('./'+name); item.size = len(data)
                    tar.addfile(item, io.BytesIO(data))
            return gzip.compress(plain.getvalue())
        evidence = m.export_evidence(archive(), d/'positive')
        assert evidence['driver_hash_matches'] and not evidence['installed_runtime_pass']
        try: m.export_evidence(archive(True), d/'negative')
        except ValueError: pass
        else: raise AssertionError('Unknown own file accepted')
        assert not (d/'negative').exists()
        collection = d/'collection'
        paths = (collection/'_vm/case', collection/'_assets/cache', d/'artifacts/coverage/out')
        m.validate(dict(private_profile=False,folder='Windows NT 3.5'),*paths,collection,d,require_target=False)
        for metadata in (dict(private_profile=True,folder='Windows NT 3.5'),dict(private_profile=False,folder='Windows NT 4.0'),{}):
            try: m.validate(metadata,*paths,collection,d,require_target=False)
            except ValueError: pass
            else: raise AssertionError('Private/ambiguous/wrong OS accepted')
        start = ROOT/'tools/tests/start_nt35_client_auto.py'
        env = dict(os.environ,TEMP=str(d),TMP=str(d),APPDATA=str(d),LOCALAPPDATA=str(d))
        pipe = subprocess.run([sys.executable,'-I','-B',str(start)],input=b'',capture_output=True,env=env)
        nul = subprocess.run([sys.executable,'-I','-B',str(start)],stdin=subprocess.DEVNULL,capture_output=True,env=env)
        for result in (pipe,nul):
            assert result.returncode and b'Live Windows operator console required' in result.stderr
        assert not (HERE/'start-manifest.json').exists()
    report = dict(prepared_private_nine_file_collector=True,unknown_file_refused=True,
        private_ambiguous_wrong_os_refused=True,matching_hash_never_runtime_pass=True,
        pipe_refused=True,windows_nul_refused=True,vm_started=False,guest_images_read=False)
    (HERE/'host-fixture-checks.json').write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(report))


if __name__ == '__main__': main()
