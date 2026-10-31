"""Build a separate prep image from unchanged stage1/bootstrap/core thunks."""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--zig",required=True); parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--cpu", choices=("i486",), required=True)
    parser.add_argument("--wim", action="store_true", help="Build isolated workload3 WIM client; keep legacy profiles separate")
    parser.add_argument("--work-dir", type=Path)
    args=parser.parse_args(); root=Path(__file__).resolve().parents[2]
    out=(args.work_dir or root/"zig-out/minios-bios").resolve()
    if not out.is_relative_to(root/"zig-out"): raise ValueError("Build work directory must stay in isolated zig-out")
    out.mkdir(parents=True,exist_ok=True)
    output=args.output.absolute()
    if not output.is_relative_to(root/"zig-out"): raise ValueError("Output must be an isolated zig-out artifact")
    output.parent.mkdir(parents=True,exist_ok=True)
    source=root/"src/platform/bios"
    def run(*words): subprocess.run([args.zig,*map(str,words)],check=True,cwd=root)
    def asm(name,linker,entry):
        elf=out/f"{name}.elf"; binary=out/f"{name}.bin"
        run("cc","-target","x86-freestanding-none","-nostdlib","-nodefaultlibs",f"-Wl,-T,{source/linker}",f"-Wl,--entry={entry}",source/f"{name}.S","-o",elf)
        run("objcopy","-O","binary","-j",".text",elf,binary)
        return binary.read_bytes()
    stage=asm("stage1","boot_sector.ld","stage1_start")
    bootstrap=asm("bootstrap","bootstrap.ld","bootstrap_start")
    obj=out/"prep.o"; audit=out/"prep.audit.s"; elf=out/"prep.elf"; binary=out/"prep.bin"
    # compiler_rt is bundled into this freestanding object. Keep functions in
    # separate ELF sections so unused arithmetic/atomic helpers do not occupy
    # the fixed slot or push BSS into the unchanged low-memory stack reserve.
    client = "bios_wim_main.zig" if args.wim else "bios_main.zig"
    run("build-obj","-target","x86-freestanding-none",f"-mcpu={args.cpu}","-O","ReleaseSmall","-fcompiler-rt","-ffunction-sections",root/"src/prep"/client,f"-femit-bin={obj}",f"-femit-asm={audit}")
    if re.search(r"\b(?:xmm|ymm|zmm)[0-9]+\b",audit.read_text(),re.I): raise ValueError("SSE/AVX appeared in i486 BIOS payload")
    if re.search(r"^\s*cmov[a-z]*\s",audit.read_text(),re.I|re.M): raise ValueError("CMOV appeared in i486 BIOS payload")
    run("cc","-target","x86-freestanding-none",f"-mcpu={args.cpu}","-nostdlib","-nodefaultlibs",f"-Wl,-T,{root/'src/prep/prep_bios.ld'}","-Wl,--entry=core_start","-Wl,--gc-sections",source/"core.S",obj,"-o",elf)
    run("objcopy","-O","binary",elf,binary)
    spec=importlib.util.spec_from_file_location("packer",root/"tools/pack_legacy_core_slot.py"); packer=importlib.util.module_from_spec(spec); spec.loader.exec_module(packer)
    slot,metadata=packer.build_slot(bootstrap,binary.read_bytes())
    if len(stage)>440: raise ValueError("Stage1 exceeds440bytes")
    with output.open("wb") as f:
        f.truncate(1024*1024); f.write(stage.ljust(440,b"\0")); f.seek(510); f.write(b"\x55\xaa"); f.seek(64*512); f.write(slot)
    print(f"BIOS prep image {output}; payload={metadata['payload_size']} slot={len(slot)}; stage/bootstrap/core.S unchanged")
if __name__=="__main__": main()
