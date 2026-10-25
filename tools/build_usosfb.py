"""Build the source950 pre-desktop coordinator with pinned OpenWatcom."""
from pathlib import Path
import argparse,hashlib,json,os,subprocess,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from build_usosadd import openwatcom386,check_exe
ROOT=Path(__file__).resolve().parents[1]
def build(out=None):
    out=Path(out or ROOT/'zig-out/dos-native/win9x').resolve();out.mkdir(parents=True,exist_ok=True)
    work=ROOT/'zig-out/usosfb-build';work.mkdir(parents=True,exist_ok=True)
    ow=openwatcom386();source=ROOT/'src/platform/win32_legacy/usosfb.c'
    assert source.read_bytes().isascii()
    env=dict(os.environ,WATCOM=str(ow),INCLUDE=f'{ow/"h"};{ow/"h/nt"}',TEMP=str(work),TMP=str(work),PATH=str(ow/'binnt64')+os.pathsep+os.environ.get('PATH',''))
    obj=work/'usosfb.obj';exe=out/'USOSFB.EXE'
    subprocess.run([str(ow/'binnt64/wcc386.exe'),'-q','-bt=nt','-mf','-3r','-zl','-s','-os','-zq','-w4','-we','-wcd=202','-fo='+str(obj),str(source)],env=env,cwd=work,check=True)
    lnk=work/'usosfb.lnk'
    lnk.write_text('\n'.join(['format windows nt','runtime windows=4.0','option quiet','option start=_fb_start','option stack=64k','option map='+str(work/'usosfb.map'),f'libpath {ow/"lib386/nt"}','library kernel32,user32,advapi32','file '+str(obj),'name '+str(exe)])+'\n',encoding='utf-8')
    subprocess.run([str(ow/'binnt64/wlink.exe'),'@'+str(lnk)],env=env,cwd=work,check=True)
    mapped=(work/'usosfb.map').read_text(encoding='utf-8',errors='replace').lower()
    assert 'clib' not in mapped and 'plib' not in mapped
    info=check_exe(exe);info.update(bytes=exe.stat().st_size,sha256=hashlib.sha256(exe.read_bytes()).hexdigest())
    (work/'manifest.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8');print(json.dumps(info));return exe
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path);args=p.parse_args();build(args.out)
