"""Package pinned FreeDOS binaries, complete sources and the USOS startup."""
from pathlib import Path
import hashlib,json,shutil,zipfile

def build(root: Path) -> None:
    vendor=root/'tools/vendor/freedos/1.4'
    manifest=json.loads((vendor/'manifest.json').read_text())
    out=root/'zig-out/dos-native/freedos';out.mkdir(parents=True,exist_ok=True)
    for name,want in manifest['files'].items():
        if hashlib.sha256((vendor/name).read_bytes()).hexdigest()!=want:
            raise ValueError('FreeDOS checksum mismatch: '+name)
        shutil.copyfile(vendor/name,out/name)
    with zipfile.ZipFile(vendor/'kernel.zip') as z:
        # Distribution kernel must match the supplied upstream source package.
        if (vendor/'KERNEL.SYS').read_bytes() not in [z.read(p) for p in z.namelist() if p.upper().endswith('.SYS')]:
            raise ValueError('FreeDOS distribution kernel has no matching source package')
        (out/'COPYING').write_bytes(z.read('DOC/KERNEL/COPYING'))
    with zipfile.ZipFile(vendor/'freecom.zip') as z:
        if (vendor/'COMMAND.COM').read_bytes()!=z.read('BIN/COMMAND.COM'):
            raise ValueError('FreeCOM distribution binary has no matching source package')
    with zipfile.ZipFile(vendor/'doszip.zip') as z:
        (out/'DZ.EXE').write_bytes(z.read('BIN/DZ.EXE'))
        (out/'DZ.DOS').write_bytes(z.read('BIN/dz.dos'))
        (out/'DOSZIP.TXT').write_bytes(z.read('DOC/DOSZIP/doszip.txt'))
    for src,dest in [('fdconfig.sys','FDCONFIG.SYS'),('fdauto.cmd','FDAUTO.BAT'),('tools.cmd','TOOLS.BAT'),('readme.txt','README.TXT')]:
        content=(root/'src/platform/bios/freedos'/src).read_text(encoding='ascii')
        if dest.endswith('.BAT') and any(len(line)>127 for line in content.splitlines()):
            raise ValueError('FreeDOS startup line too long: '+src)
        (out/dest).write_bytes(content.replace('\r\n','\n').replace('\n','\r\n').encode('ascii'))
    shutil.copyfile(root/'zig-out/dos-native/msdos/REBOOT.COM',out/'REBOOT.COM')
    shutil.copyfile(vendor/'manifest.json',out/'manifest.json')
    print('[PASS] FreeDOS 1.4 kernel, FreeCOM, Doszip and complete source packages verified')

if __name__=='__main__':build(Path(__file__).resolve().parents[1])
