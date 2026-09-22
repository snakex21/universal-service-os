"""Fast archive and menu-return checks. No device access, formatting or VM."""
from pathlib import Path
import gzip, os, subprocess, sys
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'tools'))
from build_micro_linux import parse_newc
base=root/'zig-out/xp-uefi-csm'
entries=parse_newc(gzip.decompress((base/'initramfs-xp').read_bytes()))
assert entries['usr/bin/usos-fb-ui'].data==(root/'zig-out/micro-linux/usos-fb-ui').read_bytes()
assert entries['usr/lib/usos/xp_menu_ui.sh'].data==(root/'tools/xp_menu_ui.sh').read_bytes()
assert entries['usr/lib/usos/micro_linux_ui.sh'].data==(root/'tools/micro_linux_ui.sh').read_bytes()
work=base/'menu-checks';work.mkdir(exist_ok=True)
shell='C:/Program Files/Git/bin/bash.exe'
for name in ('usos-init','usr/lib/usos/xp_menu_ui.sh','usr/lib/usos/legacy_xp_staging.sh','usr/lib/usos/micro_linux_ui.sh'):
    path=work/(Path(name).name+'.sh');path.write_bytes(entries[name].data)
    subprocess.run([shell,'-n',str(path)],check=True)
def posix(path):return '/'+path.drive[0].lower()+path.as_posix()[2:]
stub=work/'fake-ui.sh';stub.write_text('#!/bin/sh\necho fake-render >&2\n[ "$FAKE_RC" != 0 ] || echo 1\nexit "$FAKE_RC"\n')
state=work/'state.txt';state.write_text('title=TEST\nitem=Disk|read only\n')
harness=work/'check.sh'
harness.write_text('''#!/bin/bash
set -eu
enable_emergency_input() { :; }
sync() { :; }
xp_stage_set() { printf '%s\\n' "$1" >> "$USOS_XP_TRACE_DIR/phases"; }
stop() { exit 99; }
. "$MENU_SOURCE"
if usos_xp_menu "$MENU_STATE"; then
    [ "$USOS_MENU_RESULT" = 1 ] || exit 90
    exit 0
else
    exit 1
fi
''')
for rc,expected in ((0,0),(1,1),(3,99)):
    trace=work/str(rc);trace.mkdir(exist_ok=True)
    env=dict(os.environ,USOS_XP_TRACE_DIR=posix(trace),USOS_FB_UI=posix(stub),FAKE_RC=str(rc),MENU_SOURCE=posix(root/'tools/xp_menu_ui.sh'),MENU_STATE=posix(state))
    result=subprocess.run([shell,str(harness)],env=env,capture_output=True)
    assert result.returncode==expected,(rc,result.returncode,result.stderr)
    log=(trace/'menu-events.log').read_text()
    assert f'menu-return={rc}' in log and 'fake-render' in log
    assert (trace/'menu-state.txt').read_bytes()==state.read_bytes()
print('PASS: packaged renderer/scripts, shell syntax, menu selection/cancel/failure log and return handling; no target writes')
