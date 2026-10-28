"""Read-only NT5 prerequisite audit against original media, with forwarders.

Reuses pe()/resolve() from check_nt52_driver_imports.py without running its
disk-extraction CLI. Decompressed files stay in memory; archive ISOs are only
extracted into an owned collection scratch directory, removed after a case.
Raw-media results precede USOS's source-bound XP kernel edits: compare an
older SP with the raw SP3 control instead of calling a stock SP3 miss a bug.
"""
from pathlib import Path
import argparse
import ast
import hashlib
import importlib.util
import json
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SEVEN = Path(r'C:\Program Files\7-Zip\7z.exe')
SCRATCH = Path(r'G:\USOS-Kolekcja\_audit')
spec = importlib.util.spec_from_file_location('coverage_original_media', ROOT/'tools/windows_media_facts.py')
media = importlib.util.module_from_spec(spec); spec.loader.exec_module(media)
spec = importlib.util.spec_from_file_location('coverage_cab', Path(__file__).with_name('unpack_bytes.py'))
cab = importlib.util.module_from_spec(spec); spec.loader.exec_module(cab)
original_tool = ROOT/'tools/tests/check_nt52_driver_imports.py'
tree = ast.parse(original_tool.read_text(encoding='utf-8'))
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in ('pe','resolve')]
namespace = {'Path':Path,'struct':struct}
exec(compile(ast.Module(body=functions, type_ignores=[]), str(original_tool), 'exec'),namespace)
pe, resolve = namespace['pe'], namespace['resolve']


class MemoryFile:
    def __init__(self, data, name): self.data, self.name = data, name
    def read_bytes(self): return self.data
    def __repr__(self): return self.name


def binary(volume, name):
    """Bound a binary/CAB input separately from small metadata reads."""
    lba, size, directory = volume.entries[name.lower()]
    if directory or size > 128*1024**2: raise ValueError('Binary input exceeds audit bound')
    volume.file.seek(lba*media.BLOCK)
    blob = volume.file.read(size)
    if len(blob) != size: raise ValueError('Truncated binary input')
    if blob.startswith((b'MSCF',b'SZDD')):
        blob = cab.unpack(blob)
    return blob


def module_from_iso(volume, leaf, source='i386'):
    if leaf == 'ntoskrnl.exe': candidates = ['ntkrnlmp.ex_','ntkrnlmp.exe','ntoskrnl.ex_','ntoskrnl.exe']
    elif leaf == 'hal.dll': candidates = ['halmacpi.dl_','halaacpi.dl_','hal.dl_','hal.dll']
    else: candidates = [leaf[:-1]+'_',leaf]
    for candidate in candidates:
        name = source+'/'+candidate
        if name in volume.entries:
            blob = binary(volume,name)
            return blob, name
    for cabinet in ('sp4.cab','sp3.cab','sp2.cab','sp1.cab','driver.cab'):
        name = source+'/'+cabinet
        if name not in volume.entries: continue
        lba,size,directory = volume.entries[name]
        if directory or size > 128*1024**2: continue
        volume.file.seek(lba*media.BLOCK)
        blob = cab.unpack(volume.file.read(size),leaf)
        if blob[:2] == b'MZ': return blob, name+'!'+leaf
    return None, None


def drivers(family):
    if family == 'xp':
        base = ROOT/'media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86'
        names = ['ACPI/acpi.sys','Dependencies/ntoskrn8.sys','Dependencies/storport.sys',
            'KMDF/wdf01000.sys','KMDF/wdfldr.sys','SATA/genahci.sys',
            *['USB3/'+name for name in ('ksecd8.sys','ucx01000.sys','usbd8.sys','usbhub3.sys','usbxhci.sys','wpprecor.sys')]]
        return {Path(name).name.lower():base/name for name in names}
    return {
        'ahcint.sys':ROOT/'tools/vendor/ahcint/1.3.0.0-usos4/bin/2KXP/i386/ahcint.sys',
        'usosrst.sys':ROOT/'tools/w2k/usosrst/bin/i386/usosrst.sys',
        'usosnvme.sys':ROOT/'tools/nt/usosnvme/bin/NT4/i386/usosnvme.sys',
        'usosvbe.sys':ROOT/'tools/nt4/usosvbe/bin/i386/usosvbe.sys',
        'xhci98.sys':ROOT/'tools/vendor/xhci98/1.1.1.0-usos3/release-x86/xhci98.sys',
    }


def audit_iso(path, family):
    selected = drivers(family)
    tables, driver_info, source_info = {}, {}, {}
    for name, file in selected.items():
        if not file.exists():
            driver_info[name] = {'error':'driver file absent in base','path':str(file.relative_to(ROOT))}
            continue
        blob = file.read_bytes()
        try: tables[name] = pe(MemoryFile(blob,name))
        except Exception as error:
            driver_info[name] = {'error':f'PE parse: {type(error).__name__}: {error}'}
            continue
        driver_info[name] = {'path':str(file.relative_to(ROOT)),'sha256':hashlib.sha256(blob).hexdigest(),
                             'version':media.pe_facts(blob),'imports':len(tables[name][1])}
    inbox = {'ntoskrnl.exe','hal.dll','scsiport.sys','usbport.sys','usbd.sys','hidclass.sys','hidparse.sys','wmilib.sys'}
    for exports, imports in tables.values(): inbox.update(module for module,name in imports)
    with path.open('rb') as stream:
        volume = media.ISO(stream)
        for name in sorted(inbox-set(selected)):
            blob, source = module_from_iso(volume,name)
            if blob is None:
                source_info[name] = {'present':False}
                continue
            try: tables[name] = pe(MemoryFile(blob,name))
            except Exception as error:
                source_info[name] = {'present':True,'source':source,'error':str(error)}
                continue
            source_info[name] = {'present':True,'source':source,'sha256':hashlib.sha256(blob).hexdigest(),
                                  'version':media.pe_facts(blob),'exports':len(tables[name][0])}
    for name in selected:
        if name not in tables: continue
        missing = sorted({item for item in (resolve(tables,module,symbol) for module,symbol in tables[name][1]) if item})
        driver_info[name]['missing'] = [{'module':module,'symbol':symbol} for module,symbol in missing]
    return dict(family=family, drivers=driver_info, source_modules=source_info,
        method='Original media prerequisites; unmodified check_nt52_driver_imports.py pe/resolve, forwarders followed',
        caveat='Before source-bound XP kernel edits; a raw SP3 miss alone does not prove a production failure')


def one(row):
    path = Path(row['path'])
    if path.suffix.lower() == '.iso': return dict(row,audit=audit_iso(path,row['family']))
    with tempfile.TemporaryDirectory(prefix='nt5-',dir=SCRATCH) as temporary:
        output = Path(temporary)
        result = subprocess.run([str(SEVEN),'e','-y','-o'+str(output),str(path),'*.iso','-r'],capture_output=True,timeout=300)
        if result.returncode: raise RuntimeError('Archive ISO extraction failed')
        child, = output.glob('*.iso')
        with child.open('rb') as stream: digest = hashlib.file_digest(stream,'sha256').hexdigest()
        return dict(row,member=child.name,member_sha256=digest,audit=audit_iso(child,row['family']))


def main(args):
    if shutil.disk_usage(SCRATCH.anchor).free < 100*1024**3: raise SystemExit('Less than 100 GiB free')
    SCRATCH.mkdir(parents=True,exist_ok=True)
    rows = json.loads(args.plan.read_text(encoding='utf-8'))
    results = []
    for row in rows:
        try: result = one(row)
        except Exception as error: result = dict(row,error=f'{type(error).__name__}: {error}')
        results.append(result)
        print(json.dumps({'media':Path(row['path']).name,'error':result.get('error')}),flush=True)
    args.out.write_text(json.dumps(results,indent=2),encoding='utf-8')
    SCRATCH.rmdir()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    main(parser.parse_args())
