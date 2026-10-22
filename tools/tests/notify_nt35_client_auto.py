"""One exact future artifact event or metadata-only owned-image retention."""
from pathlib import Path
import ctypes,importlib.util,json,os,stat,sys,time
ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'artifacts/coverage/nt35-client-auto-fresh01'
TAG='nt35-client-auto-fresh01'
CASE=Path(r'G:\USOS-Kolekcja\_vm')/TAG
OUT=ROOT/'artifacts/coverage/vm'/TAG
spec=importlib.util.spec_from_file_location('nt35_exact_notification',HERE/'notify_core.py')
n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)

def main():
    mode=sys.argv[1];names={'target':'target.qcow2','vars':'vars.fd','stick':'stick.qcow2'}
    if mode in names:
        source=CASE/names[mode];link=source.with_name(source.stem+'-retained'+source.suffix)
        n.CASE=CASE;n.SOURCE=source;n.LINK=link
        paths=[source];kind='retain'
    elif mode=='cleanup':paths=[OUT/'cleanup.json'];kind='cleanup'
    elif mode=='endpoint':paths=[OUT/'endpoint.png',OUT/'cleanup.json'];kind='endpoint'
    else:
        number=int(mode)
        if not 1<=number<=128:raise ValueError('Invalid operator step')
        paths=[OUT/f'operator-{number:02}.png'];kind='operator'
    started=time.time();matched=n.wait_created(paths,kind)
    result=dict(event='COMPLETED',mode=mode,path=str(matched),started_unix=started,completed_unix=time.time())
    if kind=='retain':
        for p in (CASE,source,link):n.exact(p)
        if source.parent!=CASE or link.parent!=CASE or os.path.lexists(link):raise ValueError('Exact absent retention destination required')
        metadata=source.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_file_attributes&0x400:raise ValueError('Regular non-reparse image required')
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.CreateHardLinkW.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_void_p]
        kernel.CreateHardLinkW.restype=ctypes.c_int
        if not kernel.CreateHardLinkW(str(link),str(source),None):raise ctypes.WinError(ctypes.get_last_error())
        retained=link.lstat()
        if (metadata.st_dev,metadata.st_ino)!=(retained.st_dev,retained.st_ino):raise ValueError('Retention identity mismatch')
        result.update(retained=str(link),metadata_identity_verified=True,source_content_read=False)
    (HERE/(mode+'-notification.json')).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result),flush=True)

if __name__=='__main__':main()
