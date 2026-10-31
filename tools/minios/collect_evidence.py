"""Publish completed 1a correction evidence, with portable relative paths only.

Runtime receipts retain exact invocations outside the repository. This index
replaces machine-specific prefixes with declared symbolic relative roots.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

REPO=Path(__file__).resolve().parents[2]
def read(path): return json.loads(path.read_text(encoding='utf-8-sig'))
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        while b:=f.read(1024*1024): h.update(b)
    return h.hexdigest()

def portable(value, roots):
    if isinstance(value,dict): return {portable(k,roots):portable(v,roots) for k,v in value.items()}
    if isinstance(value,list): return [portable(v,roots) for v in value]
    if isinstance(value,str):
        if value.lstrip().startswith(('{','[')):
            try: embedded=json.loads(value)
            except json.JSONDecodeError: pass
            else: return json.dumps(portable(embedded,roots),ensure_ascii=False)
        for root,label in sorted(roots,key=lambda r:len(str(r[0])),reverse=True):
            # Match complete path prefixes, not a sibling such as app-other.
            for spelling in {str(root),str(root).replace('\\','/')}:
                value=re.sub(r'(?<![A-Za-z0-9_])'+re.escape(spelling)+r'(?=$|[\\/,\s"\)])',lambda _:label,value,flags=re.I)
        # Opaque NT volume identifiers are evidence, not host file paths.
        value=re.sub(r'^\\\\\?\\Volume\{([0-9a-fA-F-]+)\}\\$',r'nt-volume:\1',value)
        value=value.replace('\\','/')
        if re.search(r'[A-Za-z]:[/\\]',value) or value.startswith(('/', '//')):
            raise ValueError('Unmapped absolute path in published evidence: '+value)
    return value

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--workspace',type=Path,required=True,help='Parent containing cases/oracle/validation')
    p.add_argument('--qemu-dir',type=Path,required=True)
    p.add_argument('--source-root',type=Path,required=True)
    p.add_argument('--control',default='control-final')
    a=p.parse_args()
    root=a.workspace.resolve(); cases=root/'cases'; oracle=root/'oracle'
    roots=[(root,'evidence'),(REPO,'repo'),(a.qemu_dir.resolve(),'qemu'),(a.source_root.resolve(),'source')]
    control=read(oracle/a.control/'result.json')
    control_windows=read(oracle/(a.control+'-windows01')/'result.json')
    if control['mkntfs_exit']!=0 or not control_windows['readonly_chkdsk_pass'] or control_windows['chkdsk_exit']!=0:
        raise ValueError('Independent mkntfs/chkdsk control did not pass')
    upcase=control['upcase_sha256']; matrix=[]; identities=[]
    for arch in ('x64','ia32','bios'):
        for kind in ('gpt','mbr'):
            name=f'final-{arch}-{kind}'; case=cases/name
            run=case/'run-64m'; receipt=read(run/'completed.json')
            export=read(oracle/'inputs'/name/'export.json')
            linux=read(oracle/(name+'-linux01')/'result.json')
            winpath=oracle/(name+'-windows01')/'result.json'; win=read(winpath)
            if not(receipt['application_pass'] and receipt['returncode']==33 and linux['passed'] and linux['tree_passed'] and win['passed'] and win['readonly_file_tree_pass'] and win['readonly_chkdsk_pass'] and win['chkdsk_exit']==0):
                raise ValueError('Incomplete acceptance case: '+name)
            if linux['upcase_sha256']!=upcase: raise ValueError('UpCase differs from mkntfs reference')
            if export['chain_before']!=export['chain_after']: raise ValueError('Source chain changed')
            if not(win['chkdsk_target_guard']['passed'] and win['dismounted'] and win['temporary_dos_alias_removed'] and win['source_sha256_before']==win['source_sha256_after'] and win['vhd_sha256_before']==win['vhd_sha256_after']):
                raise ValueError('Windows identity/readonly/cleanup guard failed')
            log=run/'USOSPREP.LOG'; text=log.read_text('utf-8')
            ids=read(oracle/'inputs'/name/'identifiers.json'); identities.append(ids)
            matrix.append({'case':name,'arch':arch,'partitioning':kind,'ram_mib':64,
                'application':receipt,'allocator_peak_bytes':max(map(int,re.findall(r'(?:alloc_peak|peak)=(\d+)',text))),
                'log':str(log),'log_sha256':digest(log),'image_sha256':export['raw_sha256'],
                'identifiers':ids,'source_chain_unchanged':True,'linux':linux,
                'windows':{k:v for k,v in win.items() if k!='file_tree'},
                'files':win['file_tree']['file_count'],'directories':win['file_tree']['directory_count'],
                'windows_result':str(winpath),'windows_result_sha256':digest(winpath),
                'cleanup':read(case/'cleanup.completed.json')})
    for field in ('ntfs_serial','mbr_signature'):
        if len({x[field] for x in identities})!=6: raise ValueError('Repeated identifier: '+field)
    guids=[g for x in identities for g in (x.get('disk_guid'),x.get('partition_guid')) if g]
    if len(set(guids))!=len(guids): raise ValueError('Repeated GPT GUID')
    leftovers=[str(f) for parent in (cases,oracle) for f in parent.rglob('*') if f.is_file() and f.suffix.lower() in ('.raw','.vhd','.qcow2','.img','.fd')]
    if leftovers: raise ValueError('Unremoved images: '+repr(leftovers))
    output=REPO/'docs/minios-evidence-1a.json'
    result={'schema':2,'stage':'1a corrections','overall':'PASS','qemu_only':True,'stage1b_started':False,
        'roots':{'evidence':'caller-selected evidence workspace','repo':'this worktree','qemu':'caller-selected QEMU directory','source':'caller-selected oracle dependency checkout'},
        'names':'POSIX namespace 0; reserved metadata keeps canonical namespace',
        'upcase':{'rules':'ntfs-3g ntfs_upcase_table_build, Windows 6.1 target','bytes':131072,'sha256':upcase,'matches_independent_mkntfs':True},
        'entropy':'fresh host OS CSPRNG 64 bytes per run through QEMU fw_cfg; host backend randomSecure; absent entropy fails before writes',
        'build':read(root/'validation/build-result.json'),'python_tests':read(root/'validation/python-result.json'),
        'matrix':matrix,'control':{'formatter':control,'windows':control_windows},
        'artifacts':[{'path':str(x.relative_to(REPO)),'bytes':x.stat().st_size,'sha256':digest(x)} for x in sorted((REPO/'zig-out/test-assets').glob('usosprep*')) if x.is_file()],
        'cleanup':{'oracle':read(oracle/'cleanup-completed.json'),'remaining_images':leftovers},
        'stage1b_first_gate':'NTFS scaling redesign: >=100000 files, free-space reuse, fragmented/large files, attribute overflow, efficient indexes; no WIM implementation started'}
    result=portable(result,roots)
    output.write_bytes((json.dumps(result,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
    print(json.dumps({'output':str(output),'sha256':digest(output),'matrix_cases':len(matrix),'overall':'PASS'}))

if __name__=='__main__': main()
