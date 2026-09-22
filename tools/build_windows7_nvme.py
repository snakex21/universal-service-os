"""Build WinPE helpers and the Linux PE-version reader; verify pinned assets."""
from pathlib import Path
import hashlib,os,subprocess,zipfile,json
ASSET_SHA256='b6080e0b378cdc95ac6925b075a5691dd8be90d15527d4a2b394fb7c6c6e9cd9'

def build_helpers(root: Path,output: Path):
    output.mkdir(parents=True,exist_ok=True)
    temp=output/'tmp';temp.mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(temp),TMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(output/'zig-cache'))
    zig=str(root/'tools/zig/zig.exe')
    common=[zig,'cc','-target','x86_64-windows.win7-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),'-Wl,--entry,entry']
    for source,name,libraries in [
        ('windows7_nvme_unattend.c','usos-win7-unattend.exe',['xmllite','shlwapi','kernel32']),
        ('windows7_nvme_catalog.c','usos-win7-nvme.exe',['wintrust','advapi32','kernel32']),
    ]:
        subprocess.run(common+[str(root/'tools'/source)]+['-l'+lib for lib in libraries]+['-o',str(output/name)],env=env,check=True)
    for target,name in [('x86_64-linux-musl','pe-file-version'),('x86_64-windows.win7-gnu','pe-file-version.exe')]:
        subprocess.run([zig,'cc','-target',target,'-Os','-static',str(root/'tools/pe_file_version.c'),'-o',str(output/name)],env=env,check=True)
    subprocess.run([zig,'cc','-target','x86_64-windows.win7-gnu','-Os','-static',str(root/'tools/windows7_kmdf_repair.c'),'-lversion','-ladvapi32','-luser32','-o',str(output/'usos-win7-kmdf-repair.exe')],env=env,check=True)

def read_assets(root: Path):
    vendor=root/'tools/vendor/windows7-nvme'
    lock=json.loads((vendor/'manifest.json').read_text())
    archive=vendor/'assets.zip'
    if lock['archive_sha256']!=ASSET_SHA256 or hashlib.sha256(archive.read_bytes()).hexdigest()!=ASSET_SHA256:
        raise RuntimeError('Pinned Windows 7 NVMe assets checksum mismatch')
    with zipfile.ZipFile(archive) as z:
        if set(z.namelist())!=set(lock['files']):raise RuntimeError('Unexpected NVMe asset inventory')
        result={}
        for name,digest in lock['files'].items():
            if name.startswith('/') or '\\' in name or any(p in ('','.','..') for p in name.split('/')):
                raise RuntimeError('Invalid NVMe asset path')
            content=z.read(name)
            if hashlib.sha256(content).hexdigest()!=digest:raise RuntimeError('NVMe asset checksum mismatch: '+name)
            result[name]=content
        return result

if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]
    build_helpers(root,root/'zig-out/windows7-nvme')
