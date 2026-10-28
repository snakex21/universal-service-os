#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Owned MiniOS ISO-on-NTFS firmware case; completion waits and preserved overlays."""
from __future__ import annotations
import argparse, json, os, re, secrets, shutil, stat, struct, subprocess, time
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import logged_run
import wim_oracle as oracle
import wim_pool as pool
import wim_firmware_case as firmware
import optical_e2e

REPO=Path(__file__).resolve().parents[2] if Path(__file__).parent.name=="minios" else Path(__file__).resolve().parents[1]
GiB=1024**3

def capture_header(head):
    if not re.fullmatch(r'[0-9a-f]{40}',head):raise ValueError('Exact clean capture HEAD required')
    return f'HEAD {head}\nWORKTREE_DIRTY 0\n'.encode('ascii')

def seal_capture(path,head):
    """Stamp only a completed raw guest capture, preserving every captured byte.

    QEMU owns/truncates its serial/debug files, so their provenance prefix is
    added after the completion wait. The enclosing clean-tree check pins the
    same HEAD before launch and after capture. This never probes a live log.
    """
    header=capture_header(head)
    if not path.exists():
        path.write_bytes(header+b'CAPTURE_EMPTY guest_did_not_create_file=true\n')
        return
    if path.stat().st_size>64*1024**2:raise ValueError('Guest capture exceeds64MiB bound')
    data=path.read_bytes()
    if not data.startswith(header):path.write_bytes(header+b'CAPTURE_PROVENANCE added_after_process_completion=true\n'+data)

def execute(args,log,env,timeout=300,*,cwd=None):
    head,dirty=logged_run.tree(REPO)
    if dirty: raise ValueError("Clean tree required")
    with log.open("x",encoding="utf-8",newline="\n") as out:
        out.write(f"HEAD {head}\nWORKTREE_DIRTY 0\nCOMMAND {json.dumps(list(map(str,args)))}\n");out.flush()
        result=subprocess.run(list(map(str,args)),stdin=subprocess.DEVNULL,stdout=out,stderr=subprocess.STDOUT,
                              timeout=timeout,env=env,cwd=cwd,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
        out.write(f"EXIT {result.returncode}\n")
    if logged_run.tree(REPO)!=(head,0):raise ValueError("Tree changed during command")
    if result.returncode:raise RuntimeError("Command failed; retained "+str(log))

def write_target_marker(qemu_dir,target,out,env,target_format='qcow2'):
    if (target_format != 'qcow2' or
            target!=out/'target-base.qcow2'):
        raise ValueError("Exact new owned target path and format required")
    # qemu-io has its own whitespace parser and does not strip shell quotes.
    # Use a constant basename with an explicit working directory instead.
    execute([qemu_dir/"qemu-io.exe","-f",target_format,"-c","write -s marker.bin 0 512",target],out/"marker-write.log",env,cwd=out)

def readonly_source_args(source):
    # IDE hard disks request write permission even for a readonly backend and
    # QEMU rejects that device before firmware runs. Virtio-blk exposes its
    # readonly feature to EDK2 while retaining a strictly readonly file node.
    # https://github.com/qemu/qemu/blob/master/hw/block/virtio-blk.c
    return ["-drive",f"if=none,id=source,format=raw,readonly=on,file={source}",
            "-device","virtio-blk-pci,drive=source"]

def preparation_target_args(target,target_format='qcow2'):
    # The prepared byte image is reattached through AHCI for Windows first
    # boot. MiniOS uses virtio during preparation, including the full blank
    # scan, to avoid AHCI's expensive emulated polling on every64KiB read.
    if target_format != 'qcow2':raise ValueError('Live target must be QCOW2; VHD is a final export only')
    return ["-drive",f"if=none,id=target,format={target_format},file={target}",
            "-device","virtio-blk-pci,drive=target"]

def selected_target_format(a):
    value=getattr(a,'target_format','qcow2')
    if value != 'qcow2':raise ValueError('Live target must be QCOW2; VHD is a final export only')
    return value

def create_preparation_target(qemu_dir,out,size,env,target_format='qcow2'):
    """Create only this fresh case's writable target and immutable blank copy."""
    if target_format != 'qcow2':raise ValueError('Live target must be QCOW2; VHD is a final export only')
    qemu=qemu_dir/'qemu-img.exe'
    base=out/'target-base.qcow2';target=out/'target.qcow2'
    execute([qemu,'create','-f','qcow2',base,str(size)],out/'target-create.log',env)
    write_target_marker(qemu_dir,base,out,env)
    execute([qemu,'snapshot','-c','blank',base],out/'target-snapshot.log',env)
    base.chmod(stat.S_IREAD)
    execute([qemu,'create','-f','qcow2','-F','qcow2','-b',base,target],out/'target-overlay.log',env)
    return target,base

def seal_prepared_target(qemu_dir,out,size,env,target_format='qcow2'):
    """Freeze the completed QCOW2 checkpoint; export VHD only in the native gate."""
    if target_format != 'qcow2':raise ValueError('Live target must be QCOW2; VHD is a final export only')
    qemu=qemu_dir/'qemu-img.exe'
    execute([qemu,'snapshot','-c','prepared',out/'target.qcow2'],out/'prepared-snapshot.log',env)
    (out/'target.qcow2').chmod(stat.S_IREAD)
    return {}

def preparation_settings(a,*,bios=False):
    """Bound preparation acceleration before creating any fixture or image."""
    accel=getattr(a,'accel','tcg');scope=getattr(a,'verify_scope','selected')
    if accel not in ('tcg','whpx') or scope not in ('selected','all'):
        raise ValueError('Explicit preparation accelerator and verification scope required')
    timeout=getattr(a,'timeout',None)
    if timeout is None:timeout=1800 if accel=='whpx' else 3600
    memory=getattr(a,'memory',None)
    if memory is None:memory=(64 if accel=='whpx' else 32) if bios else 128
    if (type(timeout) is not int or not 60<=timeout<=(1800 if accel=='whpx' else 3600) or
            type(memory) is not int or not (32 if bios else 64)<=memory<=(256 if bios else 512) or
            (accel=='whpx' and memory not in (64,128))):
        raise ValueError('Bounded preparation timeout and RAM required (WHPX: <=1800s,64/128MiB)')
    return accel,scope,timeout,memory

def encode_config(proof,index,size,token,serial,verify_scope='selected',*,timing=False,combine=True,probe_items=None):
    if verify_scope not in ('selected','all'):raise ValueError('Explicit verification scope required')
    if type(timing) is not bool or type(combine) is not bool or (probe_items is not None and (type(probe_items) is not int or not 1<=probe_items<=1000000)):
        raise ValueError('Explicit diagnostic options required')
    return (f"USOSPREP_QEMU_ONLY\nmode=gpt\ntarget_sectors={size//512}\ntoken={token}\nprofile=install\nwim_index={index}\n"
            f"source_bytes={proof['target_bytes']}\nsource_start={proof['partition_start']}\nsource_size={proof['partition_bytes']}\n"
            f"source_serial={serial:016x}\nsource_iso=INSTALL.ISO\nverify_scope={verify_scope}\n"
            f"timing={'on' if timing else 'off'}\ncombine={'on' if combine else 'off'}\n"+
            (f"probe_items={probe_items}\n" if probe_items is not None else '')).encode('ascii')

def guest_command(qemu_dir,out,arch,memory,source,accel='tcg',target_format='qcow2'):
    if arch not in ('x86_64','ia32') or accel not in ('tcg','whpx') or target_format != 'qcow2':
        raise ValueError('Explicit UEFI architecture and preparation accelerator required')
    # WHPX uses the64-bit emulator for either firmware architecture. IA32
    # firmware remains IA32; only the host accelerator process/CPU changes.
    exe='qemu-system-x86_64.exe' if accel=='whpx' or arch=='x86_64' else 'qemu-system-i386.exe'
    cpu='qemu64,-xsave' if accel=='whpx' else ('qemu64' if arch=='x86_64' else 'qemu32')
    fw=qemu_dir/('share/edk2-x86_64-code.fd' if arch=='x86_64' else 'share/edk2-i386-code.fd')
    return [qemu_dir/exe,'-machine','q35','-accel','whpx' if accel=='whpx' else 'tcg,thread=multi',
            '-cpu',cpu,'-smp','1','-m',str(memory),'-nodefaults','-display','none','-no-reboot','-nic','none',
            '-drive',f'if=pflash,format=raw,readonly=on,file={fw}',
            '-drive',f'if=pflash,format=raw,file={out/"vars.fd"}',
            '-fw_cfg',f'name=opt/usosprep-entropy,file={out/"entropy.bin"}',
            '-drive',f'if=none,id=boot,format=qcow2,file={out/"boot.qcow2"}',
            '-device','ide-hd,drive=boot,bus=ide.0,bootindex=1',
            *readonly_source_args(source),*preparation_target_args(out/'target.qcow2',target_format),
            '-device','VGA','-serial',f'file:{out/"serial.log"}','-debugcon',f'file:{out/"debug.log"}',
            '-global','isa-debugcon.iobase=0xe9','-device','isa-debug-exit,iobase=0xf4,iosize=0x04']

def guest_acceptance(code,timed_out,log,source_unchanged):
    return (type(code) is int and code==33 and not timed_out and source_unchanged is True
            and "USOSPREP WIM PASS" in log and "INSTALL layout_mode=uefi" in log
            and "STACK canary_ok=true" in log and "TERMINAL FAIL" not in log)

def memory_evidence(log):
    stack=re.search(r"STACK canary_ok=true reserved_bytes=(\d+) high_water_bytes=(\d+)",log)
    heap=re.search(r"USOSPREP PLATFORM stack_bytes=(\d+) alloc_current=0 alloc_peak=(\d+)",log)
    if not stack or not heap:raise ValueError("Missing bounded stack/allocator measurement")
    reserved,peak=map(int,stack.groups())
    if not 0<peak<reserved or reserved!=int(heap[1]):raise ValueError("Invalid stack high water")
    return dict(stack_reserved=reserved,stack_high_water=peak,allocator_peak_including_stack=int(heap[2]),firmware_excluded=True)

def configure_fixture_tools(out,qemu_dir):
    # The FAT helper's default sandbox is its local zig-out, not the explicitly
    # approved VM pool. Bind it before it opens the first image; keep its guard.
    firmware.api.configure(oracle.RUNTIME,qemu_dir)
    return firmware.api.checked(out/"boot-base.raw")

def run(a):
    for path in (a.out,a.source,a.pack_proof,a.plan):oracle.owned(path)
    for path in (a.program,a.qemu_dir):oracle.local(path)
    if a.out.exists() or not a.program.is_file():raise ValueError("New output and existing firmware required")
    accel,verify_scope,timeout,memory_mib=preparation_settings(a)
    target_format=selected_target_format(a)
    if a.arch not in ("x86_64","ia32") or not 16<=a.target_gib<=64:raise ValueError("Bounded firmware parameters required")
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError("Clean tree required")
    capacity=pool.enforce(a.plan,a.out)
    configure_fixture_tools(a.out,a.qemu_dir)
    proof=json.loads(a.pack_proof.read_text())
    if proof.get("passed") is not True or proof.get("ntfs_manifest_verified") is not True or Path(proof["target"])!=a.source:raise ValueError("Accepted ISO-on-NTFS pack proof required")
    a.out.mkdir(parents=True)
    env=oracle.environment(a.out)
    qemu=a.qemu_dir/"qemu-img.exe"
    token=secrets.token_hex(32)
    marker=b"USOSPREP TARGET v1\n"+token.encode()+b"\n"
    (a.out/"marker.bin").write_bytes(marker+b"\0"*(512-len(marker)))
    program_sha=oracle.digest(a.program)
    size=a.target_gib*GiB
    with oracle.readonly(a.source) as locked:
        source_sha=oracle.digest_stream(locked)
        a.partition_start=proof["partition_start"];a.partition_bytes=proof["partition_bytes"]
        expected=optical_e2e.expectations(a,source_sha)
        if source_sha!=proof["target_sha256"] or a.source.stat().st_size!=proof["target_bytes"]:raise ValueError("Source pack pin differs")
        locked.seek(proof["partition_start"]);bpb=locked.read(512)
        if bpb[3:11]!=b"NTFS    ":raise ValueError("Source BPB differs")
        serial=struct.unpack_from("<Q",bpb,72)[0]
        config=encode_config(proof,a.index,size,token,serial,verify_scope,timing=getattr(a,'timing',False),combine=getattr(a,'combine',True),probe_items=getattr(a,'probe_items',None))
        (a.out/"USOSPREP.CFG").write_bytes(config)
        esp=firmware.SmallEsp(a.out/"boot-base.raw")
        esp.add("EFI/BOOT/"+("BOOTX64.EFI" if a.arch=="x86_64" else "BOOTIA32.EFI"),a.program.stat().st_size,firmware.api.blocks(a.program))
        esp.add("USOSPREP.CFG",len(config),[config]);esp.finish()
        target_path,target_base=create_preparation_target(a.qemu_dir,a.out,size,env,target_format)
        for name,fmt in (("boot","raw"),):
            base=a.out/(name+"-base.raw")
            base.chmod(stat.S_IREAD)
            execute([qemu,"create","-f","qcow2","-F",fmt,"-b",base,a.out/(name+".qcow2")],a.out/(name+"-overlay.log"),env)
        bases={str(p.name):oracle.digest(p) for p in (target_base,a.out/"boot-base.raw")}
        entropy=secrets.token_bytes(64);(a.out/"entropy.bin").write_bytes(entropy)
        shutil.copyfile(a.qemu_dir/"share/edk2-i386-vars.fd",a.out/"vars.fd")
        args=guest_command(a.qemu_dir,a.out,a.arch,memory_mib,a.source,accel,target_format)
        started=time.monotonic();timed_out=False;code=None
        with (a.out/"qemu.stdout").open("xb") as stdout,(a.out/"qemu.stderr").open("xb") as stderr:
            for stream in (stdout,stderr):stream.write(capture_header(head));stream.flush()
            child=subprocess.Popen(list(map(str,args)),stdout=stdout,stderr=stderr,stdin=subprocess.DEVNULL,env=env,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
            try:code=child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:timed_out=True;child.kill();code=child.wait()
        guest_seconds=time.monotonic()-started
        for name in ('debug.log','serial.log'):seal_capture(a.out/name,head)
        log=(a.out/"debug.log").read_text(encoding="utf-8",errors="replace")
        source_after=oracle.digest_stream(locked)
    probe=getattr(a,'probe_items',None)
    diagnostic_completed=(probe is not None and code==73 and not timed_out and source_after==source_sha and
                          re.search(r'DIAGNOSTIC_STOP current=(\d+) incomplete=true not_installation_pass=true',log) is not None and
                          'USOSPREP WIM PASS' not in log)
    passed=probe is None and guest_acceptance(code,timed_out,log,source_after==source_sha)
    base_ok=all(oracle.digest(a.out/p)==h for p,h in bases.items())
    passed=passed and base_ok and oracle.digest(a.program)==program_sha
    diagnostic_completed=diagnostic_completed and base_ok and oracle.digest(a.program)==program_sha
    # Preserve prepared disk as immutable checkpoint, future boot tests use another overlay.
    prepared=seal_prepared_target(a.qemu_dir,a.out,size,env,target_format) if passed else {}
    result_target=a.out/'target.qcow2' if passed else target_path
    memory=memory_evidence(log) if passed else None
    result=dict(schema="minios-install-firmware-v1",head=head,dirty=0,qemu_only=True,arch=a.arch,mode="gpt",target=str(result_target),target_bytes=size,
                target_sha256=oracle.digest(result_target),target_format=target_format,blank_checkpoint=str(target_base),blank_checkpoint_sha256=bases[target_base.name],
                source=str(a.source),source_sha256=source_sha,source_unchanged=source_sha==source_after,
                program_sha256=program_sha,base_unchanged=base_ok,returncode=code,timed_out=timed_out,guest_completion_wait=True,
                elapsed_seconds=time.monotonic()-started,memory_mib=memory_mib,accel=accel,verify_scope=verify_scope,timeout_seconds=timeout,
                guest_elapsed_seconds=guest_seconds,postprocess_excluded_from_guest_time=True,
                timing=getattr(a,'timing',False),combine=getattr(a,'combine',True),probe_items=probe,diagnostic_completed=diagnostic_completed,
                command=list(map(str,args)),passed=passed,cleanup_performed=False,physical_disks_opened=False,windows_boot_attempted=False,
                raw_guest_capture_provenance='serial/debug prefixed after process completion; stdout/stderr before launch',
                independent_windows_gate_not_yet_run=True,memory=memory,expected=expected,capacity_plan_sha256=oracle.digest(a.plan),**prepared)
    if logged_run.tree(REPO)!=(head,0):raise ValueError("Tree changed during firmware gate")
    oracle.save(a.out/"result.json",result)
    return result

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    for n in ("out","source","pack-proof","program","qemu-dir","plan","expected-tree","expected-security","iso-proof"):p.add_argument("--"+n,type=Path,required=True)
    p.add_argument("--arch",choices=("x86_64","ia32"),required=True);p.add_argument("--index",type=int,required=True)
    p.add_argument('--accel',choices=('whpx','tcg'),default='tcg');p.add_argument('--verify-scope',choices=('selected','all'),default='selected')
    p.add_argument('--target-format',choices=('qcow2',),default='qcow2')
    p.add_argument('--timing',action='store_true',help='Explicit diagnostic profiling; production default is off')
    p.add_argument('--no-combine',dest='combine',action='store_false')
    p.add_argument('--probe-items',type=int,default=None,help='QEMU-only incomplete diagnostic stop at an emitted apply boundary')
    p.add_argument("--target-gib",type=int,default=32);p.add_argument("--memory",type=int,default=128);p.add_argument("--timeout",type=int,default=None)
    a=p.parse_args();r=run(a);print(json.dumps(r));raise SystemExit(0 if r["passed"] or r['diagnostic_completed'] else 1)
