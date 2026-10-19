"""Build the native plan frontend; no Windows packages are built or downloaded."""
from pathlib import Path
import os,subprocess

def build(root: Path, out: Path, *, host=False):
    out.mkdir(parents=True,exist_ok=True)
    temp=out/'tmp';temp.mkdir(exist_ok=True)
    env=dict(os.environ,TMP=str(temp),TEMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
    zig=env.get('USOS_ZIG',str(root/'tools/zig/zig.exe'))
    exe=out/('legacy-stage-plan.exe' if host and os.name=='nt' else 'legacy-stage-plan')
    src=root/'src/platform/win32_legacy/usosadd'
    target=[] if host else ['-target','x86_64-linux-musl','-static']
    subprocess.run([zig,'cc',*target,'-O2','-Wall','-Wextra','-Werror','-Wno-misleading-indentation',
                    '-I'+str(src),str(root/'tools/addons/legacy_stage_plan.c'),str(root/'tools/addons/legacy_stage_iso.c'),
                    *[str(src/n) for n in ('str.c','ini.c','detect.c','plan.c')],'-o',str(exe)],env=env,check=True)
    return exe
