import gzip
from pathlib import Path
from build_micro_linux import parse_newc
e=parse_newc(gzip.decompress(Path('J:/EFI/USOS/micro-linux/initramfs-usos').read_bytes()))
for name in ['init','usr/lib/usos/legacy_xp_staging.sh']:
    print(name)
    if name=='init':print(e[name].data.decode())
    for i,line in enumerate(e[name].data.decode().splitlines(),1):
        if any(x in line for x in ['mount ESP','mount -t vfat','BOOTSTRAP','repair','SOURCE_OPEN','TEST_INI','legacy_image','CMDLINE','LEGACY_ACTION=']):print(i,line)
