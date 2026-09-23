"""Unit tests: pinned cabinets and hives are reproducible and keep content."""
from pathlib import Path
import ctypes as c, os, shutil, subprocess, sys, tempfile, time, winreg
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import xp_cab, xp_hive

work=Path(tempfile.mkdtemp(prefix='xp-repro-'))
try:
    # Cabinets: same content, different file times -> same bytes after pinning.
    src=work/'DRIVER.SYS';src.write_bytes(b'driver payload '*300)
    cabs=[]
    for i,stamp in enumerate((1_600_000_000,1_700_000_000)):
        os.utime(src,(stamp,stamp));dst=work/f'{i}.SY_'
        subprocess.run(['C:/Windows/System32/makecab.exe','/D','CompressionType=MSZIP',str(src),str(dst)],check=True,stdout=subprocess.DEVNULL)
        cabs.append(dst)
    assert cabs[0].read_bytes()!=cabs[1].read_bytes(),'makecab no longer records file times'
    for p in cabs:xp_cab.pin(p)
    assert cabs[0].read_bytes()==cabs[1].read_bytes()
    assert [e[4:6] for e in xp_cab.entries(cabs[0].read_bytes())]==[xp_cab.PINNED_STAMP]
    # A file taken from a source cabinet keeps that cabinet's stamp.
    xp_cab.pin(cabs[1],{'driver.sys':(0x2e21,0xb061)})
    assert xp_cab.entries(cabs[1].read_bytes())[0][4:6]==(0x2e21,0xb061)
    subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(cabs[1]),'-o'+str(work/'out'),'-y'],check=True,stdout=subprocess.DEVNULL)
    assert (work/'out/DRIVER.SYS').read_bytes()==src.read_bytes()
    try:xp_cab.entries(b'not a cabinet');raise AssertionError('accepted junk')
    except ValueError:pass

    # Hives: two edits at different times -> identical bytes after pinning.
    adv=c.WinDLL('advapi32');adv.RegLoadAppKeyW.argtypes=[c.c_wchar_p,c.POINTER(c.c_void_p),c.c_uint,c.c_uint,c.c_uint]
    def edit(path,values):
        h=c.c_void_p();assert adv.RegLoadAppKeyW(str(path),c.byref(h),winreg.KEY_ALL_ACCESS,0,0)==0
        try:
            for key,name,value in values:
                with winreg.CreateKeyEx(h.value,key,0,winreg.KEY_ALL_ACCESS) as k:winreg.SetValueEx(k,name,0,winreg.REG_DWORD,value)
            winreg.FlushKey(h.value)
        finally:winreg.CloseKey(h.value)
        for suffix in ('.LOG1','.LOG2'):Path(str(path)+suffix).unlink(missing_ok=True)
    original=work/'original.hiv';edit(original,[('ControlSet001\\Services\\Old','Start',3)])
    copies=[]
    for i in range(2):
        time.sleep(1.1)
        p=work/f'edited{i}.hiv';shutil.copyfile(original,p);edit(p,[('ControlSet001\\Services\\New','Start',0)]);copies.append(p)
    a,b=(xp_hive.pin_hive(p.read_bytes(),original.read_bytes()) for p in copies)
    assert copies[0].read_bytes()!=copies[1].read_bytes(),'registry no longer stamps edit times'
    assert a==b
    content=xp_hive.read_hive_content(a)
    assert content['controlset001\\services\\new']=={'start':(4,(0).to_bytes(4,'little'))}
    assert content['controlset001\\services\\old']=={'start':(4,(3).to_bytes(4,'little'))}
    assert xp_hive.read_hive(a)['controlset001\\services\\new'][0]==xp_hive.PINNED_FILETIME
    assert xp_hive.read_hive(a)['controlset001\\services\\old'][0]==xp_hive.read_hive(original.read_bytes())['controlset001\\services\\old'][0]
    assert xp_hive.checksum(a)==int.from_bytes(a[0x1fc:0x200],'little')
    try:xp_hive.read_hive(b'junk'*1024);raise AssertionError('accepted junk')
    except ValueError:pass
    print('PASS: pinned cabinets and hives are byte-reproducible; contents, source stamps and unchanged keys preserved')
finally:shutil.rmtree(work,ignore_errors=True)
