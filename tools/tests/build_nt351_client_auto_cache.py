"""Private qualified-f579 cache plus exactly three client-policy entries."""
from pathlib import Path
import gzip
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
BASE = Path(r'G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt351-irq-fresh01')
OUT = Path(r'G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt351-client-auto01')
HERE = ROOT/'artifacts/coverage/nt351-client-auto-fresh01'
BASE_PIN = '2540baab9efb257396fc21d58a3572f9a774bf2212593ea37ad25e61c4a8d820'
POST_PIN = '615f6d6b49b3c53df62603b804195f80c0d431dad4b2d88145ece1ad166ed48b'
DRIVER = 'f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf'
INITRD = Path('zig-out/micro-linux/initramfs-usos')


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def sha(data): return hashlib.sha256(data).hexdigest()


def main():
    helper = load('client_auto_cache_common', ROOT/'tools/tests/build_nt351_irq_fresh_cache.py')
    helper.safe_cache(BASE); helper.safe_cache(OUT)
    output = HERE/'cache-manifest.json'
    if OUT.exists() or output.exists(): raise FileExistsError('New private cache/output required')
    if shutil.disk_usage(BASE).free < 100*1024**3: raise ValueError('100GiB G reserve required')
    original = (BASE/INITRD).read_bytes()
    if sha(original) != BASE_PIN: raise ValueError('Qualified fresh d94 base changed')
    layers, cpio = helper.modules()
    before, count = layers.effective_newc(gzip.decompress(original))
    for name, pin in (('usr/lib/usos/nt3/USOSNET351.SYS', DRIVER),
                      ('usr/lib/usos/nt3/USOSNT3.EXE', 'd2c1115180d8daeb02421d23920584a95dd8aa082a42c566dec1e9ff836e1096'),
                      ('usr/lib/usos/nt3/USOSLOG351.EXE', 'ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7')):
        if sha(before[name].data) != pin: raise ValueError('Frozen entry mismatch: '+name)
    build = json.loads((ROOT/'artifacts/nt351-client-auto/build01/build.json').read_text(encoding='utf-8'))
    post = Path(build['binary']).read_bytes()
    if sha(post) != POST_PIN or build['sha256'] != POST_PIN: raise ValueError('Final own POST pin mismatch')
    preflight = json.loads((ROOT/'artifacts/nt351-client-auto/post-original-preflight01.json').read_text(encoding='utf-8'))
    if preflight['binary_sha256'] != POST_PIN or preflight['missing']:
        raise ValueError('Final original-import proof required')
    delta = {'usr/lib/usos/nt3/USOSNT3.EXE': cpio.Entry('usr/lib/usos/nt3/USOSNT3.EXE', before['usr/lib/usos/nt3/USOSNT3.EXE'].mode, post)}
    sys.path.insert(0, str(ROOT/'tools/tests'))
    from build_nt351_fixture_cache import owned_hunks
    for leaf in ('nt4_csmwrap_target.sh', 'nt351_network_setup.sh'):
        name = 'usr/lib/usos/'+leaf
        old_source = subprocess.check_output(['git','show','664d721e:tools/'+leaf],cwd=ROOT).replace(b'\r\n',b'\n')
        new_source = (ROOT/'tools'/leaf).read_bytes().replace(b'\r\n',b'\n')
        staged = owned_hunks(before[name].data, old_source, new_source)
        delta[name] = cpio.Entry(name, before[name].mode, staged)
    overlay = gzip.compress(cpio.newc(delta), compresslevel=9, mtime=0)
    combined = original+b'\0'*(-len(original)%4)+overlay
    after, final_count = layers.effective_newc(gzip.decompress(combined))
    changed = helper.compare(before, after, delta)
    secondary, _ = layers.effective_newc(gzip.decompress((BASE/'zig-out/micro-linux/qemu9x.cpio').read_bytes()))
    if set(delta)&secondary.keys() or final_count != count+1: raise ValueError('Layer/secondary override mismatch')
    files = {p.relative_to(BASE).as_posix():dict(bytes=p.stat().st_size,sha256=helper.file_sha(p))
             for p in sorted(BASE.rglob('*')) if p.is_file()}
    shutil.copytree(BASE, OUT)
    (OUT/INITRD).write_bytes(combined)
    for relative, row in files.items():
        expected = sha(combined) if relative == INITRD.as_posix() else row['sha256']
        if helper.file_sha(OUT/relative) != expected or helper.file_sha(BASE/relative) != row['sha256']:
            raise ValueError('Copied cache/base immutability mismatch: '+relative)
    report = dict(base=str(BASE), output=str(OUT), base_initrd_sha256=BASE_PIN,
        initrd_sha256=sha(combined), overlay_sha256=sha(overlay), base_prefix_preserved=True,
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        base_layers=count, final_layers=final_count, effective_entries=len(before),
        unchanged_effective_entries=len(before)-3, source_cache_files=files,
        changed_entries=[dict(entry=n,old_sha256=sha(before[n].data),sha256=sha(after[n].data),bytes=len(after[n].data)) for n in changed],
        post_sha256=POST_PIN, post_bytes=len(post), driver_sha256=DRIVER, driver_bytes=17024,
        logger_sha256='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7',
        old_cache_modified=False, other_cache_files_identical=True, frozen_usb_unchanged=True,
        secondary_initrd_overrides_candidate=False, physical_writes=False, runtime_pass=False)
    HERE.mkdir(parents=True,exist_ok=True)
    encoded = (json.dumps(report,indent=2)+'\n').encode('utf-8')
    output.write_bytes(encoded)
    (OUT/'nt351-client-auto-inputs.json').write_bytes(encoded)
    print(json.dumps({k:report[k] for k in ('output','initrd_sha256','post_sha256','driver_sha256','effective_entries','unchanged_effective_entries')},indent=2))


if __name__ == '__main__': main()
