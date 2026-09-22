"""Rebuild the bounded 16-bit handler; patch only its exact upstream byte array.

This creates an experimental derived EFI file, leaving the vendor EFI untouched.
No disks are updated and no VM is launched.
"""
from pathlib import Path
import hashlib, json, os, re, subprocess

ROOT = Path(__file__).resolve().parents[1]
def digest(data): return hashlib.sha256(data).hexdigest()

def build():
    vendor = ROOT / 'tools/vendor/uefiseven/1.30'
    output = ROOT / 'zig-out/windows7-int10-patch'
    output.mkdir(parents=True, exist_ok=True)
    temp = output / 'tmp'
    temp.mkdir(exist_ok=True)
    env = dict(os.environ, TEMP=str(temp), TMP=str(temp),
               ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(output/'zig-cache'))
    header = (vendor/'Int10hHandler.h').read_text(encoding='utf8')
    body = re.sub(r'/\*.*?\*/', '', header, flags=re.S).split('INT10H_HANDLER[] = {',1)[1].split('}',1)[0]
    old = bytes(int(h,16) for h in re.findall(r'0x([0-9a-fA-F]{2})',body))
    original = (vendor/'UefiSeven.efi').read_bytes()
    pinned = json.loads((vendor/'int10-source.json').read_text(encoding='utf8'))
    if digest(original) != pinned['efi_sha256'] or digest(old) != pinned['handler_sha256']:
        raise ValueError('Upstream EFI or handler checksum mismatch')
    if original.count(old) != 1: raise ValueError('Expected exactly one upstream handler')
    zig=str(ROOT/'tools/zig/zig.exe')
    subprocess.run([zig,'cc','-target','x86-freestanding-none','-c',str(ROOT/'tools/windows7_int10.S'),'-o',str(output/'handler.o')],env=env,check=True)
    subprocess.run([zig,'objcopy','-O','binary','--only-section=.text',str(output/'handler.o'),str(output/'handler.bin')],env=env,check=True)
    new=(output/'handler.bin').read_bytes()
    if len(new)>len(old) or new[:512] != b'\x90'*512 or old[:512] != b'\x90'*512:
        raise ValueError('Handler does not fit the original VBE table/code layout')
    offset=original.index(old)
    patched=original[:offset]+new+b'\x90'*(len(old)-len(new))+original[offset+len(old):]
    assert len(patched)==len(original)
    assert patched[:offset]==original[:offset] and patched[offset+len(old):]==original[offset+len(old):]
    (output/'win7-int10-return.efi').write_bytes(patched)
    info={'source_commit':pinned['commit'],'original_sha256':digest(original),'patched_sha256':digest(patched),
          'handler_offset':offset,'original_handler_size':len(old),'new_handler_size':len(new),
          'description':'Unsupported INT10 requests return AX=014F instead of hanging; SetMode accepts preserve-framebuffer bit.'}
    (output/'manifest.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf8')
    print(json.dumps(info))
    return output

if __name__=='__main__':build()
