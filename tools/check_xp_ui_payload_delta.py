"""Compare connected prior payload with the proposed UI-only replacement."""
from pathlib import Path
import gzip
from build_micro_linux import parse_newc
root=Path(__file__).resolve().parents[1]
old=parse_newc(gzip.decompress(Path('J:/EFI/USOS-XP/initramfs-xp').read_bytes()))
new=parse_newc(gzip.decompress((root/'zig-out/xp-uefi-csm/initramfs-xp').read_bytes()))
assert old.keys()==new.keys(), 'Unexpected archive membership change'
changed={name for name in old if old[name].data!=new[name].data}
ui={'usos-init','usr/bin/usos-fb-ui','usr/lib/usos/xp_menu_ui.sh','usr/lib/usos/micro_linux_ui.sh'}
assert changed and changed<=ui,changed
print('PASS: only UI pieces changed',sorted(changed),'- all XP drivers/staging/PAE bytes preserved')
