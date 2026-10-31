"""File-only QEMU fixtures. Does not mount disks or accept physical devices.

Prepare immutable bases once; every run uses fresh qcow2 overlays. Runtime
completion is subprocess.wait/communicate, never progress polling or QMP.
"""
from __future__ import annotations
import argparse
import contextlib
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import struct
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "zig-out/minios-cases"
QEMU = REPO / "tools/qemu"

def configure(workspace: Path, qemu_dir: Path) -> None:
    global ROOT, QEMU
    for path in (workspace, qemu_dir):
        if not path.is_absolute() or path == Path(path.anchor) or str(path).startswith("\\\\"):
            raise ValueError("Explicit local workspace/tool directories are required")
        for node in (path, *path.parents):
            if node.exists() and (node.is_symlink() or (getattr(node.lstat(), "st_file_attributes", 0) & 0x400)):
                raise ValueError("Reparse/symlink directory refused")
    ROOT, QEMU = workspace.resolve(), qemu_dir.resolve()
SECTOR = 512
LARGE_SIZE = 128 * 1024 * 1024 + 123
PATTERN = bytes((n * 37 + 11) & 255 for n in range(65536))

def checked(path: Path) -> Path:
    if any(c in str(path) for c in ",\r\n\0"):
        raise ValueError("Comma and control characters are forbidden in QEMU file paths")
    path = Path(os.path.abspath(os.path.normpath(str(path))))
    if not path.is_relative_to(ROOT) or path == ROOT:
        raise ValueError(f"Only a new owned case under {ROOT} is accepted")
    for parent in (path, *path.parents):
        if parent.exists() and parent.is_symlink():
            raise ValueError("Symlinks are forbidden")
        if parent.exists() and os.name == "nt" and parent.lstat().st_file_attributes & 0x400:
            raise ValueError("Reparse points are forbidden")
        if parent == ROOT.parent:
            break
    return path

def save(path: Path, value) -> None:
    with checked(path).open("x", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, indent=2)
        f.write("\n")

def run_command(args: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout)

def hash_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(1024 * 1024): h.update(block)
    return h.hexdigest()

class FatBuilder:
    """Small own FAT32 image writer for controlled ASCII fixture names only."""
    start = 2048
    total = 524288
    spc = 4
    reserved = 32
    fat_sectors = 2048
    cluster_bytes = spc * SECTOR
    data_sector = start + reserved + 2 * fat_sectors
    capacity = (total - reserved - 2 * fat_sectors) // spc

    def __init__(self, path: Path):
        self.f = checked(path).open("x+b")
        self.f.truncate((self.start + self.total) * SECTOR)
        self.fat = bytearray(self.fat_sectors * SECTOR)
        struct.pack_into("<II", self.fat, 0, 0x0ffffff8, 0xffffffff)
        self.cursor = 2
        self.dirs: dict[str, tuple[int, list[bytes]]] = {}
        self.mkdir("", 0)
        self.mkdir("EFI", 2)
        self.mkdir("EFI/BOOT", self.dirs["EFI"][0])
        self.mkdir("FIXTURES", 2)

    def write_at(self, offset: int, data: bytes) -> None:
        self.f.seek(offset)
        self.f.write(data)

    def cluster_offset(self, cluster: int) -> int:
        return (self.data_sector + (cluster - 2) * self.spc) * SECTOR

    def allocate(self, count: int) -> int:
        if count == 0: return 0
        first = self.cursor
        if first + count > self.capacity + 2: raise ValueError("FAT fixture full")
        for c in range(first, first + count):
            struct.pack_into("<I", self.fat, c * 4, c + 1 if c + 1 < first + count else 0x0fffffff)
        self.cursor += count
        return first

    @staticmethod
    def entry(name: str, cluster: int, size: int, directory: bool = False) -> bytes:
        e = bytearray(32)
        if name in (".", ".."): short = name.encode().ljust(11)
        else:
            name, _, ext = name.upper().partition(".")
            if len(name) > 8 or len(ext) > 3: raise ValueError("Only 8.3 names in fixture ESP")
            short = name.encode().ljust(8) + ext.encode().ljust(3)
        e[:11] = short
        e[11] = 0x10 if directory else 0x20
        struct.pack_into("<H", e, 20, cluster >> 16)
        struct.pack_into("<H", e, 26, cluster & 0xffff)
        struct.pack_into("<I", e, 28, size)
        return bytes(e)

    def mkdir(self, path: str, parent: int) -> None:
        cluster = self.allocate(1)
        entries = [] if not path else [self.entry(".", cluster, 0, True), self.entry("..", parent, 0, True)]
        self.dirs[path] = (cluster, entries)
        if path:
            directory, _, name = path.rpartition("/")
            self.dirs[directory][1].append(self.entry(name, cluster, 0, True))

    def add(self, path: str, size: int, blocks) -> str:
        first = self.allocate((size + self.cluster_bytes - 1) // self.cluster_bytes)
        self.f.seek(self.cluster_offset(first))
        h = hashlib.sha256()
        written = 0
        for block in blocks:
            if written + len(block) > size: raise ValueError("Fixture source too long")
            self.f.write(block); h.update(block); written += len(block)
        if written != size: raise ValueError("Fixture source short")
        directory, _, name = path.rpartition("/")
        self.dirs[directory][1].append(self.entry(name, first, size))
        return h.hexdigest()

    def finish(self) -> None:
        mbr = bytearray(512)
        mbr[446:462] = struct.pack("<B3sB3sII", 0x80, b"\xfe\xff\xff", 0xef, b"\xfe\xff\xff", self.start, self.total)
        mbr[510:] = b"\x55\xaa"
        self.write_at(0, mbr)
        bpb = bytearray(512)
        bpb[:11] = b"\xeb\x58\x90USOSPREP"
        struct.pack_into("<HBHBHHBHHHII", bpb, 11, 512, self.spc, self.reserved, 2, 0, 0, 0xf8, 0, 63, 255, self.start, self.total)
        struct.pack_into("<IHHIHH", bpb, 36, self.fat_sectors, 0, 0, 2, 1, 6)
        bpb[64] = 0x80; bpb[66] = 0x29
        struct.pack_into("<I", bpb, 67, 0x53505250)
        bpb[71:82] = b"USOSPREP   "
        bpb[82:90] = b"FAT32   "
        bpb[510:] = b"\x55\xaa"
        self.write_at(self.start * 512, bpb)
        self.write_at((self.start + 6) * 512, bpb)
        info = bytearray(512)
        struct.pack_into("<I", info, 0, 0x41615252)
        struct.pack_into("<III", info, 484, 0x61417272, self.capacity - (self.cursor - 2), self.cursor)
        struct.pack_into("<I", info, 508, 0xaa550000)
        for n in (1, 7): self.write_at((self.start + n) * 512, info)
        for n in range(2): self.write_at((self.start + self.reserved + n * self.fat_sectors) * 512, self.fat)
        for cluster, entries in self.dirs.values():
            data = b"".join(entries)
            if len(data) + 32 > self.cluster_bytes: raise ValueError("Fixture directory full")
            self.write_at(self.cluster_offset(cluster), data.ljust(self.cluster_bytes, b"\0"))
        self.f.flush(); os.fsync(self.f.fileno()); self.f.close()

def blocks(path: Path):
    with path.open("rb") as f:
        while b := f.read(65536): yield b

def large_blocks():
    remaining = LARGE_SIZE
    while remaining:
        b = PATTERN[:min(len(PATTERN), remaining)]
        yield b; remaining -= len(b)

def prepare(case: Path, arch: str, kind: str, efi: Path, size: int, profile: str = "stage1a") -> None:
    checked(case)
    if profile not in ("stage1a", "scale-firmware", "scale-tree150k"): raise ValueError("Unknown firmware workload profile")
    if size < 512 * 1024 * 1024 or size % 512: raise ValueError("Target size must be aligned and >=512MiB")
    if shutil.disk_usage(ROOT.parent).free < 100 * 1024**3: raise ValueError("Workspace reserve below100GiB")
    case.mkdir(parents=True, exist_ok=False)
    token = secrets.token_hex(32)
    cfg = f"USOSPREP_QEMU_ONLY\nmode={kind}\ntarget_sectors={size//512}\ntoken={token}\n".encode()
    if profile != "stage1a": cfg += f"profile={profile}\n".encode()
    hashes = {}
    if arch == "bios":
        if efi.stat().st_size != 1024*1024: raise ValueError("Expected the isolated1MiB prep BIOS build artifact")
        boot=checked(case/"esp-base.raw")
        with efi.open("rb") as source, boot.open("x+b") as f:
            shutil.copyfileobj(source,f,65536); f.truncate(256*1024*1024)
            cfg_binary=bytearray(512); cfg_binary[:16]=b"USOSPREP BIOS v1"
            struct.pack_into("<IIQ",cfg_binary,16,0 if kind=="gpt" else 1,512,size//512)
            cfg_binary[32:96]=token.encode(); struct.pack_into("<QQQQ",cfg_binary,96,2056*512,LARGE_SIZE,2048*512,64)
            cfg_binary[128:130]=b"\x81\x80"
            struct.pack_into("<I", cfg_binary, 132, {"stage1a":0,"scale-firmware":1,"scale-tree150k":2}[profile])
            f.seek(1024*512); f.write(cfg_binary)
            if profile == "stage1a":
                f.seek(2048*512); small=bytes(range(64)); f.write(small); hashes["small"]=hashlib.sha256(small).hexdigest()
                f.seek(2056*512); h=hashlib.sha256()
                for block in large_blocks(): f.write(block); h.update(block)
                hashes["large"]=h.hexdigest()
            f.flush(); os.fsync(f.fileno())
        hashes["bios_build"]=hash_file(efi)
    else:
        esp = FatBuilder(case / "esp-base.raw")
        hashes["efi"] = esp.add(f"EFI/BOOT/{'BOOTX64' if arch=='x86_64' else 'BOOTIA32'}.EFI", efi.stat().st_size, blocks(efi))
        esp.add("USOSPREP.CFG", len(cfg), [cfg])
        if profile == "stage1a":
            hashes["small"] = esp.add("FIXTURES/SMALL.BIN", 64, [bytes(range(64))])
            hashes["large"] = esp.add("FIXTURES/LARGE.BIN", LARGE_SIZE, large_blocks())
        esp.finish()
    with checked(case / "target-base.raw").open("x+b") as f:
        f.truncate(size)
        f.write(b"USOSPREP TARGET v1\n" + token.encode() + b"\n")
        f.flush(); os.fsync(f.fileno())
    save(case / "prepared.json", {"arch":arch,"kind":kind,"size":size,"token":token,"hashes":hashes,"efi":str(efi),"profile":profile,"qemu_only":True})
    # Reuse exactly the host oracle's path manifest, but pass the actual ESP
    # fixture hashes (its64-byte pattern intentionally differs from hostcase).
    module_name = "host_case.py" if profile == "stage1a" else "scale_case.py"
    spec=importlib.util.spec_from_file_location("minios_firmware_manifest",Path(__file__).with_name(module_name))
    host=importlib.util.module_from_spec(spec); spec.loader.exec_module(host)
    expected = host.manifest(hashes["small"], hashes["large"]) if profile == "stage1a" else host.manifest("tree150k" if profile == "scale-tree150k" else "firmware")
    save(case/"manifest.json",expected)

def extract_log(esp: Path, destination: Path) -> bool:
    with esp.open("rb") as f:
        f.seek(FatBuilder.start * 512); boot=f.read(512)
        spc=boot[13]; reserved=struct.unpack_from("<H",boot,14)[0]; spf=struct.unpack_from("<I",boot,36)[0]
        base=FatBuilder.start*512; data=base+(reserved+boot[16]*spf)*512
        f.seek(base+reserved*512); fat=f.read(spf*512)
        def chain(cluster):
            visited=set()
            while 2 <= cluster < 0xffffff8:
                if cluster in visited or len(visited)>100000: raise ValueError("FAT chain cycle")
                visited.add(cluster); yield cluster
                cluster=struct.unpack_from("<I",fat,cluster*4)[0]&0xfffffff
        def read_cluster(c):
            f.seek(data+(c-2)*spc*512); return f.read(spc*512)
        for c in chain(struct.unpack_from("<I",boot,44)[0]):
            entries=read_cluster(c)
            for n in range(0,len(entries),32):
                entry=entries[n:n+32]
                if entry[:11] != b"USOSPREPLOG": continue
                first=struct.unpack_from("<H",entry,20)[0]<<16 | struct.unpack_from("<H",entry,26)[0]
                size=struct.unpack_from("<I",entry,28)[0]
                with checked(destination).open("xb") as out:
                    for cluster in chain(first):
                        chunk=read_cluster(cluster)[:size]; out.write(chunk); size-=len(chunk)
                        if size==0: return True
                raise ValueError("Short log chain")
    return False

def execute(case: Path, memory: int, timeout: int, cpu: str | None = None, entropy_input: bool = True) -> bool:
    checked(case)
    prepared=json.loads((case / "prepared.json").read_text())
    run=checked(case / f"run-{memory}m")
    run.mkdir(exist_ok=False)
    # Fresh OS CSPRNG input for EVERY formatting operation, independent of the
    # target marker and immutable bases. fw_cfg is transport, not an RNG.
    entropy = secrets.token_bytes(64) if entropy_input else None
    if entropy is not None:
        with checked(run / "entropy.bin").open("xb") as f: f.write(entropy)
    qimg=QEMU / "qemu-img.exe"
    for name in ("esp", "target"):
        run_command([str(qimg),"create","-f","qcow2","-F","raw","-b",str(case/f"{name}-base.raw"),str(run/f"{name}.qcow2")])
    bios=prepared["arch"]=="bios"
    cpu = cpu or ("486" if bios else "max")
    if cpu not in ("486", "pentium", "pentium2", "pentium3", "qemu32", "qemu64", "max"):
        raise ValueError("Explicit supported QEMU CPU model required")
    vars_source=QEMU/"share"/"edk2-i386-vars.fd"
    if not bios: shutil.copyfile(vars_source, run/"vars.fd")
    code=QEMU/"share"/("bios-256k.bin" if bios else f"edk2-{'x86_64' if prepared['arch']=='x86_64' else 'i386'}-code.fd")
    exe=QEMU/f"qemu-system-{'x86_64' if prepared['arch']=='x86_64' else 'i386'}.exe"
    args=[str(exe),"-machine","pc" if bios else "q35","-accel","tcg,thread=multi","-cpu",cpu,"-smp","1","-m",str(memory),"-nodefaults","-display","none","-no-reboot","-nic","none"]
    if bios: args += ["-bios",str(code)]
    else: args += ["-drive",f"if=pflash,format=raw,readonly=on,file={code}","-drive",f"if=pflash,format=raw,file={run/'vars.fd'}"]
    if entropy_input: args += ["-fw_cfg",f"name=opt/usosprep-entropy,file={run/'entropy.bin'}"]
    args += ["-drive",f"if=none,id=esp,format=qcow2,file={run/'esp.qcow2'}","-device","ide-hd,drive=esp,bus=ide.0,bootindex=1",
          "-drive",f"if=none,id=target,format=qcow2,file={run/'target.qcow2'}","-device","ide-hd,drive=target,bus=ide.1",
          "-device","VGA","-serial",f"file:{run/'serial.log'}","-debugcon",f"file:{run/'debug.log'}","-global","isa-debugcon.iobase=0xe9",
          "-d","guest_errors,cpu_reset","-D",str(run/"qemu-events.log"),
          "-device","isa-debug-exit,iobase=0xf4,iosize=0x04"]
    start=time.monotonic(); timed_out=False; interrupted=False
    with (run/"qemu.stdout").open("xb") as stdout, (run/"qemu.stderr").open("xb") as stderr:
        proc=subprocess.Popen(args,stdout=stdout,stderr=stderr,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
        status=None
        try:
            status=proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out=True
        except KeyboardInterrupt:
            interrupted=True
        finally:
            if status is None:
                # Never inspect/poll a running process. On timeout, Ctrl+C,
                # or another wait exception, terminate only this owned child
                # and block until its actual handle signals completion.
                try: proc.kill()
                except ProcessLookupError: pass
                status=proc.wait()
    run_command([str(qimg),"convert","-f","qcow2","-O","raw",str(run/"esp.qcow2"),str(run/"esp-closed.raw")])
    if bios:
        with (run/"esp-closed.raw").open("rb") as f:
            f.seek(1025*512); text=f.read(1023*512).split(b"\0",1)[0]
        found=bool(text)
        if found:
            with checked(run/"USOSPREP.LOG").open("xb") as f: f.write(text)
    else: found=extract_log(run/"esp-closed.raw", run/"USOSPREP.LOG")
    pass_marker = b"USOSPREP SCALE PASS" if prepared.get("profile", "").startswith("scale-") else b"USOSPREP PASS;"
    application_pass = not timed_out and not interrupted and status == 33 and found and pass_marker in (run/"USOSPREP.LOG").read_bytes()
    selected_entropy = None
    if found:
        for line in (run/"USOSPREP.LOG").read_text(errors="replace").splitlines():
            if line.startswith("ENTROPY source="): selected_entropy = line.split()[1].split("=",1)[1]
    save(run/"completed.json", {"command":args,"returncode":status,"expected_pass_returncode":33,"application_pass":application_pass,"profile":prepared.get("profile", "stage1a"),"timed_out":timed_out,"interrupted":interrupted,"elapsed_seconds":time.monotonic()-start,"log_extracted":found,"firmware_sha256":hash_file(code),"vars_source_sha256":None if bios else hash_file(vars_source),"entropy_source":selected_entropy,"fw_cfg_input_source":"host OS CSPRNG; fresh64bytes per run; may be unused when EFI or CPU RNG succeeds" if entropy_input else None, "entropy_sha256":hashlib.sha256(entropy).hexdigest() if entropy is not None else None,"qemu_only":True})
    print(json.dumps({"run":str(run),"returncode":status,"application_pass":application_pass,"timed_out":timed_out,"log_extracted":found}))
    return application_pass

@contextlib.contextmanager
def exclusive_read(path: Path):
    """Hold a Windows no-sharing handle: active QEMU images are rejected."""
    if os.name != "nt": raise ValueError("Cleanup requires the approved Windows image workspace")
    import msvcrt
    api=ctypes.WinDLL("kernel32",use_last_error=True)
    api.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
    api.CreateFileW.restype=ctypes.c_void_p
    api.CloseHandle.argtypes=[ctypes.c_void_p]
    handle=api.CreateFileW(str(path),0x80000000,0,None,3,0,None)
    if handle==ctypes.c_void_p(-1).value: raise OSError(ctypes.get_last_error(),"Image is inaccessible or still in use: "+str(path))
    try: fd=msvcrt.open_osfhandle(handle,os.O_RDONLY|os.O_BINARY)
    except BaseException:
        api.CloseHandle(handle); raise
    with os.fdopen(fd,"rb") as file: yield file

def cleanup(case: Path) -> dict:
    case=checked(case)
    prepared=json.loads((case/"prepared.json").read_text())
    if prepared.get("qemu_only") is not True: raise ValueError("Missing owned QEMU case marker")
    runs=[p for p in case.iterdir() if p.is_dir() and p.name.startswith("run-")]
    if not runs: raise ValueError("No completed guest run; refusing image cleanup")
    for run in runs:
        checked(run)
        receipt=json.loads((run/"completed.json").read_text())
        if receipt.get("qemu_only") is not True or not isinstance(receipt.get("returncode"),int):
            raise ValueError("Guest completion was not recorded")
    root_names=("esp-base.raw","target-base.raw","blank-base.qcow2","host-cow.qcow2","target.raw","small.bin","large.bin")
    run_names=("esp.qcow2","target.qcow2","esp-closed.raw","target-closed.raw","vars.fd","small.bin","large.bin","entropy.bin")
    candidates=[case/name for name in root_names]
    candidates += [run/name for run in runs for name in run_names]
    files=[]
    # Validate ALL paths and acquire ALL no-sharing handles before deleting
    # anything, so an active child causes a clean refusal of the whole plan.
    with contextlib.ExitStack() as locks:
        for path in candidates:
            checked(path)
            if not path.exists(): continue
            if not path.is_file(): raise ValueError("Expected regular image file: "+str(path))
            source=locks.enter_context(exclusive_read(path))
            h=hashlib.sha256(); size=0
            while block:=source.read(1024*1024): h.update(block); size+=len(block)
            files.append({"path":str(path.relative_to(case)),"bytes":size,"sha256":h.hexdigest()})
        save(case/"cleanup.json",{"state":"validated-plan","files":files,"total_bytes":sum(f["bytes"] for f in files),"qemu_only":True})
    removed=[]
    try:
        for item in files:
            path=checked(case/item["path"])
            # Reacquire the no-sharing handle immediately before unlinking;
            # no recursive deletion and no glob expansion is used.
            with exclusive_read(path): pass
            path.unlink(); removed.append(item["path"])
    except BaseException as error:
        save(case/"cleanup.failed.json",{"removed":removed,"error":repr(error)})
        raise
    result={"state":"complete","removed":removed,"removed_bytes":sum(f["bytes"] for f in files),"qemu_only":True}
    save(case/"cleanup.completed.json",result)
    return result

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--workspace",type=Path,required=True)
    p.add_argument("--qemu-dir",type=Path,required=True)
    commands=p.add_subparsers(dest="action",required=True)
    a=commands.add_parser("prepare"); a.add_argument("case",type=Path); a.add_argument("--arch",choices=("x86_64","ia32","bios"),required=True); a.add_argument("--kind",choices=("gpt","mbr"),required=True); a.add_argument("--efi","--program",type=Path,required=True); a.add_argument("--size",type=int,default=2*1024**3); a.add_argument("--profile",choices=("stage1a","scale-firmware","scale-tree150k"),default="stage1a")
    a=commands.add_parser("run"); a.add_argument("case",type=Path); a.add_argument("--memory",type=int,default=64); a.add_argument("--timeout",type=int,default=1800)
    a=commands.add_parser("cleanup"); a.add_argument("case",type=Path)
    args=p.parse_args()
    configure(args.workspace,args.qemu_dir)
    if args.action=="prepare": prepare(args.case,args.arch,args.kind,args.efi,args.size,args.profile)
    elif args.action=="run":
        if not execute(args.case,args.memory,args.timeout): raise SystemExit(1)
    else: print(json.dumps(cleanup(args.case)))
if __name__=="__main__": main()
