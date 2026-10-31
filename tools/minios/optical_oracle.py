#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only 7-Zip oracle: all files streamed through stdout, no extracted tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import logged_run


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source,'sha256').hexdigest()


def listing(text):
    text=text.replace('\r\n','\n')
    if '\n----------\n' not in text:
        raise ValueError('7-Zip item separator missing')
    result=[]
    for block in text.split('\n----------\n',1)[1].split('\n\n'):
        fields=dict(line.split(' = ',1) for line in block.splitlines() if ' = ' in line)
        if 'Path' not in fields: continue
        name=fields['Path'].replace('\\','/')
        if name.startswith('[BOOT]/') or name=='[BOOT]': continue  # 7-Zip synthetic El Torito view
        if '\n' in name or '\r' in name or name.startswith('/') or '..' in name.split('/'):
            raise ValueError('Unsafe oracle name')
        result.append(dict(path=name,directory=fields.get('Folder')=='+',
                           size=0 if fields.get('Folder')=='+' else int(fields['Size'])))
    return result


def stream_order_line(line, known):
    """7-Zip can report selected directories as well as their children."""
    if not line.startswith('- '):
        return None
    name = line[2:].rstrip('\r\n').replace('\\', '/')
    if name not in known:
        raise ValueError('Unexpected 7-Zip extracted path: ' + name)
    return None if known[name]['directory'] else name


def extraction_order(logfile,known):
    """Only inspect the log after its child has exited and closed the file."""
    order=[]
    seen=set()
    with logfile.open(encoding='utf-8') as log:
        for line in log:
            name=stream_order_line(line,known)
            if name is None:continue
            if name in seen:raise ValueError('Duplicate 7-Zip extraction event: '+name)
            seen.add(name);order.append(name)
    if seen!={name for name,row in known.items() if not row['directory']}:
        raise ValueError('7-Zip extraction omitted files')
    return order


def reap(proc):
    """Wait for the OS process object, even if Popen already cached its exit.

    On Windows concurrent termination can cache an exit code before all process
    handles have been torn down. Popen.wait() then returns the cached code.
    The unconditional blocking process-handle wait prevents a redirected log
    from surviving its parent's finally block. This never polls the process.
    """
    if os.name=='nt' and hasattr(proc,'_handle'):
        import ctypes
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
        kernel.WaitForSingleObject.restype=ctypes.c_ulong
        result=kernel.WaitForSingleObject(int(proc._handle),0xffffffff)
        if result!=0:raise ctypes.WinError(ctypes.get_last_error())
    return proc.wait()


def stream_pass(command,logfile,label,timeout,consume=None):
    """Drain stdout immediately, without waiting for possibly buffered stderr.

    stderr goes directly to a regular log file. In the order-discovery pass,
    stdout goes to the null device; in the hash pass, consume drains its pipe.
    Both waits block until completion and have a kill deadline, without polls.
    """
    timed_out = threading.Event()
    with logfile.open('xb') as log:
        log.write(label.encode('utf-8'));log.flush()
        proc=subprocess.Popen(command,stdout=subprocess.DEVNULL if consume is None else subprocess.PIPE,stderr=log)
        def deadline():
            timed_out.set();proc.kill()
        timer=threading.Timer(timeout,deadline);timer.start()
        try:
            if consume is not None:consume(proc.stdout)
            code=proc.wait()
            if timed_out.is_set():raise TimeoutError('7-Zip stream deadline')
            if code:raise ValueError('7-Zip streaming failed: '+str(code))
            return code
        except BaseException as error:
            if timed_out.is_set() and not isinstance(error,TimeoutError):
                raise TimeoutError('7-Zip stream deadline') from error
            raise
        finally:
            timer.cancel()
            # The deadline must stop using proc before the owner cleans up.
            timer.join()
            if not timed_out.is_set() and proc.returncode is None:proc.kill()
            reap(proc)
            if proc.stdout is not None:proc.stdout.close()


def stream_files(iso, sevenzip, includes, entries, logfile, label, timeout=1800):
    """Discover extraction order with null stdout, then stream/hash in that order.

    7-Zip can buffer stderr until after emitting a file larger than a pipe. A
    single pass that waits for an stderr filename before draining stdout can
    therefore deadlock. The two full streaming passes never wait on stderr.
    The second completed log must prove precisely the same extraction order.
    No payload is saved and no extracted directory tree is created.
    """
    known={}
    for entry in entries:
        if entry['path'] in known:raise ValueError('Duplicate oracle path')
        known[entry['path']]=entry
    command=[str(sevenzip),'x','-so','-bb1','-bso2','-bsp0','-sccUTF-8','-scsUTF-8','-spd',str(iso),'-i@'+str(includes)]
    orderlog=logfile.with_name(logfile.stem+'-order'+logfile.suffix)
    stream_pass(command,orderlog,label,timeout)
    order=extraction_order(orderlog,known)
    def consume(source):
        for name in order:
            entry=known[name];h=hashlib.sha256();remaining=entry['size']
            while remaining:
                block=source.read(min(256*1024,remaining))
                if not block:raise ValueError('Truncated 7-Zip stream: '+name)
                h.update(block);remaining-=len(block)
            entry['sha256']=h.hexdigest()
        if source.read(1):raise ValueError('Extra 7-Zip stream data')
    code=stream_pass(command,logfile,label,timeout,consume)
    if extraction_order(logfile,known)!=order:
        raise ValueError('7-Zip extraction order changed between passes')
    return code,order


def header(repo, require_clean=True):
    head,dirty=logged_run.tree(repo)
    if require_clean and dirty: raise ValueError('Oracle evidence requires a clean tree')
    return head, dirty, f'HEAD {head}\nWORKTREE_DIRTY {dirty}\n'


def compare(iso,exe,sevenzip,out,mode='manifest',mode_args=(),require_clean=True):
    repo=Path(__file__).resolve().parents[2]
    head, dirty, label=header(repo,require_clean)
    if out.exists(): raise ValueError('New output directory required')
    out.mkdir(parents=True)
    source_hash=digest(iso)
    program_hash=digest(exe)
    sevenzip_hash=digest(sevenzip)
    listing_run=subprocess.run([str(sevenzip),'l','-slt','-sccUTF-8',str(iso)],capture_output=True,timeout=300)
    text=listing_run.stdout.decode('utf-8').replace('\r','')
    (out/'sevenzip-listing.txt').write_text(label+text,encoding='utf-8')
    if listing_run.returncode: raise ValueError('7-Zip listing failed')
    entries=listing(text)
    files=[entry for entry in entries if not entry['directory']]
    includes=out/'files.txt'
    includes.write_text('\n'.join(e['path'] for e in files)+'\n',encoding='utf-8')
    own=subprocess.run([str(exe),mode,str(iso),*mode_args],capture_output=True,timeout=1800)
    own_text=(own.stdout+own.stderr).decode('utf-8')
    (out/'own.log').write_text(label+own_text,encoding='utf-8')
    if own.returncode or 'OPTICAL_MANIFEST_COMPLETE ' not in own_text: raise ValueError('Own reader refused')
    actual=[json.loads(line[6:]) for line in own_text.splitlines() if line.startswith('ENTRY ')]
    code, order=stream_files(iso,sevenzip,includes,entries,out/'sevenzip-stream.log',label)
    for entry in entries:
        if entry['directory']: entry['sha256']=None
    def indexed(rows):
        result={}
        for row in rows:
            if row['path'] in result: raise ValueError('Duplicate oracle path')
            result[row['path']]=row
        return result
    left,right=indexed(entries),indexed(actual)
    differences=[name for name in sorted(left.keys()|right.keys()) if left.get(name)!=right.get(name)]
    for name,rows in [('expected.jsonl',entries),('actual.jsonl',actual)]:
        with (out/name).open('x',encoding='utf-8') as target:
            for row in rows:target.write(json.dumps(row,ensure_ascii=False)+'\n')
    unchanged=digest(iso)==source_hash
    tools_unchanged=digest(exe)==program_hash and digest(sevenzip)==sevenzip_hash
    result=dict(schema='minios-optical-7zip-v1',head=head,worktree_dirty=dirty,
                iso_bytes=iso.stat().st_size,iso_sha256=source_hash,source_unchanged=unchanged,
                program_sha256=program_hash,sevenzip_sha256=sevenzip_hash,tools_unchanged=tools_unchanged,entries=len(entries),files=len(files),
                directories=len(entries)-len(files),bytes_hashed=sum(e['size'] for e in files),
                files_above_4g=[dict(path=e['path'],size=e['size']) for e in files if e['size']>4*1024**3],
                differences=differences[:100],difference_count=len(differences),sevenzip_exit=code,
                stream_order_verified=True,extraction_order_matches_listing=order==[e['path'] for e in files],
                sevenzip_stream_passes=2,order_discovery_stdout='DEVNULL',
                sevenzip_payload_bytes_streamed=2*sum(e['size'] for e in files),
                order_log_sha256=digest(out/'sevenzip-stream-order.log'),stream_log_sha256=digest(out/'sevenzip-stream.log'),
                synthetic_boot_view_ignored='[BOOT]' in text,iso_mounted=False,extracted_tree=False,
                actual_manifest_sha256=digest(out/'actual.jsonl'),expected_manifest_sha256=digest(out/'expected.jsonl'),
                own_heap_peak=int(re.search(r'heap_peak=(\d+)',own_text).group(1)),
                kind=re.search(r'OPTICAL kind=(\w+)',own_text).group(1),
                passed=unchanged and tools_unchanged and not differences)
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    if require_clean and logged_run.tree(repo)!=(head,0):raise ValueError('Tree changed during evidence')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['iso','exe','sevenzip','out']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--mode',choices=['manifest','block-manifest','ntfs-manifest'],default='manifest')
    p.add_argument('--mode-arg',action='append',default=[])
    p.add_argument('--development',action='store_true',help='Allow dirty tree; never final evidence')
    a=p.parse_args();r=compare(a.iso,a.exe,a.sevenzip,a.out,a.mode,a.mode_arg,not a.development)
    print(json.dumps(r));raise SystemExit(0 if r['passed'] else 1)
