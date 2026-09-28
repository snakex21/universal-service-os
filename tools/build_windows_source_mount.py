"""Build the WinPE helpers for Vista and later without a C runtime."""
from pathlib import Path
import os,subprocess
def build(root: Path, output: Path):
    output.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy()
    temp=output/'tmp';temp.mkdir(exist_ok=True)
    env['TEMP']=env['TMP']=str(temp)
    env['ZIG_GLOBAL_CACHE_DIR']=str(root/'tools/cache/zig-global')
    env['ZIG_LOCAL_CACHE_DIR']=str(output/'zig-cache')
    for arch in ('x86_64','x86'):
        subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target',arch+'-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin',
          '-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_setup_logging.c'),
          '-Wl,--entry,entry','-lkernel32','-ladvapi32','-o',str(output/('usos-log-'+arch+'.exe'))],env=env,check=True)
        subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target',arch+'-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin',
          '-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_source_mount.c'),
          '-Wl,--entry,entry','-lkernel32','-ladvapi32','-o',str(output/('usos-source-'+arch+'.exe'))],env=env,check=True)
        subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target',arch+'-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin',
          '-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_setup_launcher.c'),
          '-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-ladvapi32','-luser32','-lgdi32','-o',str(output/('usos-launch-'+arch+'.exe'))],env=env,check=True)
        subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target',arch+'-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin',
          '-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_usb_report.c'),
          '-Wl,--entry,entry','-lkernel32','-ladvapi32','-lsetupapi','-lcfgmgr32','-o',str(output/('usos-usb-report-'+arch+'.exe'))],env=env,check=True)
    # The profile answers' commands without console windows (x64 targets only).
    subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin',
      '-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_hidden_run.c'),
      '-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-ladvapi32','-o',str(output/'usos-run-hidden.exe')],env=env,check=True)
if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]
    build(root,root/'zig-out/windows-source-mount')
