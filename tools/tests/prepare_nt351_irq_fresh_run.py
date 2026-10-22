"""Pin a private R22-derived harness and plan, without starting any VM."""
from pathlib import Path
import hashlib,json,shutil,subprocess,sys,zipfile

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT.parent/'macierz-windows'
HERE=ROOT/'artifacts/coverage/nt351-irq-fresh01'
TAG='nt351-irq-fresh01'
DRIVER='f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf'
R22_COMMIT='ec60b10c825c7e78633ae00e26b8aa2ecdfe5cea'
def sha(data):return hashlib.sha256(data).hexdigest()
def main():
    HERE.mkdir(parents=True,exist_ok=True)
    harness=HERE/'harness'
    if harness.exists():raise FileExistsError('Never replace an existing private harness')
    harness.mkdir()
    manifest={}
    for source in sorted((SOURCE/'tools/tests/coverage').glob('*.py')):
        original=source.read_bytes();text=original.decode('utf-8')
        # Relocate only helper root lookup. Each imported neighbour stays in
        # this immutable private snapshot, outside every shared checkout.
        text=text.replace('Path(__file__).resolve().parents[3]',repr(ROOT))
        text=text.replace('Path(__file__).resolve().parents[2]',repr(ROOT/'tools'))
        # repr(Path) is not portable source code; use explicit Path literals.
        text=text.replace(repr(ROOT), 'Path('+repr(str(ROOT))+')')
        text=text.replace(repr(ROOT/'tools'), 'Path('+repr(str(ROOT/'tools'))+')')
        if source.name=='collect_nt351_success.py':
            needle="DRIVER_SHA256='f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a'"
            if text.count(needle)!=1:raise ValueError('Collector input contract changed')
            text=text.replace(needle,"DRIVER_SHA256='"+DRIVER+"'")
        compile(text,str(harness/source.name),'exec')
        data=text.encode('utf-8');(harness/source.name).write_bytes(data)
        manifest[source.name]=dict(source_sha256=sha(original),private_sha256=sha(data))
    # The two guest observation scripts are the exact tracked R22 sources.
    scripts={}
    for leaf in ('micro_linux_ui.sh','xp_menu_ui.sh'):
        data=subprocess.check_output(['git','show',R22_COMMIT+':tools/'+leaf],cwd=SOURCE)
        target=ROOT/'tools'/leaf
        before=target.read_bytes();target.write_bytes(data)
        scripts[leaf]=dict(r22_source_commit=R22_COMMIT,sha256=sha(data),previous_sha256=sha(before))
    profile=(SOURCE/'artifacts/coverage/keyless.profile.ini').read_bytes()
    if sha(profile)!='e0753e9efb0207e41ef9c603bc96581bb2672ba538e57a159047f0e3f28563c5':raise ValueError('Exact R22 keyless profile required')
    (HERE/'keyless.profile.ini').write_bytes(profile)
    catalog=(SOURCE/'artifacts/coverage/catalog.ndjson').read_bytes()
    catalog_out=ROOT/'artifacts/coverage/catalog.ndjson'
    if catalog_out.exists():raise FileExistsError('Fresh local catalog required')
    catalog_out.write_bytes(catalog)
    r22=json.loads((SOURCE/'artifacts/coverage/nt351-runtime-r22/plan.json').read_text(encoding='utf-8'))
    case,=r22
    before=dict(case);case['tag']=TAG;case['expected_own_driver_sha256']=DRIVER
    if {key for key in before if case[key]!=before[key]}!={'tag','expected_own_driver_sha256'}:raise ValueError('Unexpected plan difference')
    (HERE/'plan.json').write_text(json.dumps([case],indent=2)+'\n',encoding='utf-8')
    # Keep the original run_plan and boot_menu cleanup paths byte-identical;
    # three creation-event notifiers retain same-file hard links on G only.
    notify=(SOURCE/'artifacts/coverage/nt31-runtime-r19/notify.py').read_bytes()
    (HERE/'notify_core.py').write_bytes(notify)
    report=dict(source_root=str(SOURCE),private_harness=str(harness),files=manifest,
        observer_scripts=scripts,keyless_profile_sha256=sha(profile),catalog_sha256=sha(catalog),
        notify_core_sha256=sha(notify),plan_sha256=sha((HERE/'plan.json').read_bytes()),
        plan_changed_fields=['tag','expected_own_driver_sha256'],
        harness_functional_change='Collector expected own SYS digest only; root paths relocated',
        guest_package_functional_change='Only canonical-IRQ own SYS and sidecar in private cache',
        physical_writes=False,runtime_pass=False)
    (HERE/'harness-manifest.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    with zipfile.ZipFile(HERE/'harness-snapshot.zip','x',compression=zipfile.ZIP_DEFLATED) as z:
        for path in sorted(harness.glob('*.py')):z.write(path,path.name)
    print(json.dumps(dict(prepared=True,harness_files=len(manifest),plan_sha256=report['plan_sha256']),indent=2))

if __name__=='__main__':main()
