"""Start one fresh normal USOS NT351, with immutable R22-derived inputs."""
from pathlib import Path
import hashlib,importlib.util,json,os,subprocess,sys
ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'artifacts/coverage/nt351-irq-fresh01'
COLLECTION=Path(r'G:\USOS-Kolekcja')
QEMU=ROOT.parent/'bety-instalacja/tools/qemu/qemu-system-x86_64.exe'
DRIVER='f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf'
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
def main():
    output=HERE/'start-manifest.json'
    if output.exists():raise FileExistsError('Never restart the same fresh case')
    cache=json.loads((HERE/'cache-manifest.json').read_text(encoding='utf-8'))
    harness=json.loads((HERE/'harness-manifest.json').read_text(encoding='utf-8'))
    plan=HERE/'plan.json';assets=Path(cache['output']);profile=HERE/'keyless.profile.ini'
    if sha(plan)!=harness['plan_sha256'] or sha(profile)!=harness['keyless_profile_sha256']:raise ValueError('Plan/profile pin mismatch')
    for leaf,row in harness['files'].items():
        if sha(HERE/'harness'/leaf)!=row['private_sha256']:raise ValueError('Harness snapshot changed: '+leaf)
    for leaf,row in harness['observer_scripts'].items():
        if sha(ROOT/'tools'/leaf)!=row['sha256']:raise ValueError('R22 observation script changed')
    case,=json.loads(plan.read_text(encoding='utf-8'))
    if case['tag']!='nt351-irq-fresh01' or case['system']!='windows-nt-3-51' or case['expected_own_driver_sha256']!=DRIVER:
        raise ValueError('Wrong case/candidate')
    if not case['ps2_input'] or case['usb_only_input'] or 'private_key' in case:raise ValueError('Exact R22 keyless input route required')
    if sha(Path(case['source']))!=case['source_sha256']:raise ValueError('Original source archive pin mismatch')
    if cache['driver_sha256']!=DRIVER or sha(ROOT/'tools/nt/usosnet/bin/i386/usosnet351.sys')!=DRIVER:raise ValueError('Own binary mismatch')
    if len(cache['changed_entries'])!=2 or not cache['other_cache_files_identical']:raise ValueError('Unexpected cache delta')
    for relative,row in cache['source_cache_files'].items():
        expected=cache['initrd_sha256'] if relative=='zig-out/micro-linux/initramfs-usos' else row['sha256']
        if sha(assets/relative)!=expected:raise ValueError('Immutable private cache changed: '+relative)
    if sha(Path(cache['base'])/'zig-out/micro-linux/initramfs-usos')!=cache['r22_initrd_sha256']:raise ValueError('Old frozen cache changed')
    collector=load('nt351_irq_collector',HERE/'harness/collect_nt351_success.py')
    if collector.DRIVER_SHA256!=DRIVER or collector.DRIVER_BYTES!=17024:raise ValueError('Wrong collector candidate')
    fixture=load('nt351_irq_fixture',HERE/'harness/prepare_stick.py')
    resources=fixture.check_resources(COLLECTION,2048)
    command=[sys.executable,'-I','-B',str(HERE/'harness/run_plan.py'),'--plan',str(plan),
             '--assets',str(assets),'--qemu',str(QEMU),'--profile',str(profile),'--nested']
    record=dict(tag=case['tag'],plan_sha256=sha(plan),assets=str(assets),
        initrd_sha256=cache['initrd_sha256'],profile_sha256=sha(profile),
        driver_sha256=DRIVER,driver_bytes=17024,collector_expected_sha256=collector.DRIVER_SHA256,
        qemu_sha256=sha(QEMU),resources=resources,command=command,
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        scope='Fresh normal USOS NT351 with corrected IRQ; separate Client/noSharing observation; no physical qualification')
    output.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print('NT351_IRQ_FRESH_PREFLIGHT_PASS; STARTING_NORMAL_USOS',flush=True)
    env=dict(os.environ,TEMP=str(HERE),TMP=str(HERE),APPDATA=str(HERE),LOCALAPPDATA=str(HERE),PYTHONDONTWRITEBYTECODE='1')
    return subprocess.call(command,cwd=ROOT,env=env)

if __name__=='__main__':raise SystemExit(main())
