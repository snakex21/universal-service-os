"""Stage original NCPA source and own full-MAC only in a new stopped R19c overlay.

Microsoft media/INF/module bytes remain RAM or approved whole VM disks.
No hive editor, host registry write, physical disk or VM launch is used.
"""
from pathlib import Path
import hashlib,importlib.util,json,re,shutil,struct,subprocess,tempfile,warnings
import pefile
ROOT=Path(__file__).resolve().parents[2]
MATRIX=ROOT.parent/'macierz-windows'
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
BASE=COLLECTION/'_vm/r19c-nt31-usb-isolation/target.qcow2'
BASE_SHA='d736f6509fba4780e73a74ab7164dd4bfe7a1e6664ba1f0cfbc80c9e6169f644'
TAG='r24-nt31-intel-fullmac'
WORK=COLLECTION/'_vm'/TAG
OUT=ROOT/'artifacts/nt31-fullmac-runtime/r24-preparation.json'
BUILD=ROOT/'artifacts/nt31-fullmac-build/build12'
LOGGER=ROOT.parent/'nt351-net/artifacts/nt351-network/logger-dns-pinned-01/USOSLOG.EXE'
LOGGER_SHA='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7'
OEM_SHA='556698b977394922b616cbfc937db049086ef447148f10b542efd40f9320e865'
QIMG=ROOT.parent/'bety-instalacja/tools/qemu/qemu-img.exe'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def h(data):return hashlib.sha256(data).hexdigest()
def source_path(name):
    if not name.startswith('i386/'):raise ValueError('Only original I386 source is allowed')
    parts=name.split('/')[1:]
    # ISO9660 permits a terminal dot for an empty extension. FAT uses no dot.
    parts=[part[:-1] if part.endswith('.') else part for part in parts]
    if not 1<=len(parts)<=4 or not all(re.fullmatch(r'[A-Za-z0-9_$~!#%&\x27()@^`{}-]{1,8}(?:\.[A-Za-z0-9_$~!#%&\x27()@^`{}-]{1,3})?',part) for part in parts):
        raise ValueError('Source must remain 8.3: '+name)
    return 'N31SRC/'+'/'.join(part.upper() for part in parts)
def own_oem(blob,driver_size):
    if h(blob)!=OEM_SHA:raise ValueError('Original NDISLoop INF hash changed')
    text=blob.decode('cp1252')
    if 'ProductSoftwareName     = "NDISLoop"' not in text:raise ValueError('Wrong original adapter donor')
    text=re.sub(r'(?i)\bloop\.sys\b','USNET31.SYS',text)
    text=re.sub(r'(?i)ndisloop','USOSNET31',text)
    text=re.sub(r'(?i)\bloop(?!back)','USOSNET31',text)
    text=text.replace('MS Loopback','USOS Intel 82576')
    text,count=re.subn(r'(2,USNET31\.SYS\s*,\s*SIZE=)\d+',lambda m:m[1]+str(driver_size),text,flags=re.I)
    if count!=1:raise ValueError('Exact own SYS copy entry required')
    pattern=r'(\{BusType,\$\(NoTitle\),\$\(!REG_VT_DWORD\),)\$\(BusTypeNum\)(\},\s*\+)'
    own=[('BusNumber',0),('PciBus',0),('PciDevice',5),('PciFunction',0),('DebugPort',233)]
    replacement=r'\g<1>5\g<2>'+'\r\n'+''.join('                       {'+name+',$'+'(NoTitle),$(!REG_VT_DWORD),'+str(value)+'},+\r\n' for name,value in own)
    text,count=re.subn(pattern,lambda m:m[1]+'5'+m[2]+'\r\n'+''.join('                       {'+name+',$'+'(NoTitle),$(!REG_VT_DWORD),'+str(value)+'},+\r\n' for name,value in own),text)
    if count!=1:raise ValueError('Exact original hardware parameter setter required')
    if re.search(r'(?i)\bloop\.sys\b|NDISLoop|\[Files-LOOP\]',text):raise ValueError('Original loopback identity remains')
    if 'ProductSoftwareName     = "USOSNET31"' not in text or '[Files-USOSNET31]' not in text:raise ValueError('Own software/option mismatch')
    return text.encode('cp1252')
def imports_against(raw,modules):
    pe=pefile.PE(data=raw,fast_load=False);rows={}
    for entry in getattr(pe,'DIRECTORY_ENTRY_IMPORT',()):
        dll=entry.dll.decode('ascii').lower()
        if dll not in modules:raise ValueError('Unexpected import DLL '+dll)
        donor=pefile.PE(data=modules[dll],fast_load=False)
        exports={e.name.decode('ascii') for e in donor.DIRECTORY_ENTRY_EXPORT.symbols if e.name}
        names=[i.name.decode('ascii') for i in entry.imports if i.name]
        if len(names)!=len(entry.imports) or not set(names)<=exports:raise ValueError('Unavailable actual installed import '+dll)
        rows[dll]=len(names)
    return rows
def main():
    if WORK.exists() or OUT.exists():raise FileExistsError('Fresh owned R24 paths required')
    if not WORK.resolve().is_relative_to(COLLECTION/'_vm') or sha(BASE)!=BASE_SHA:raise ValueError('Pinned stopped base required')
    done=json.loads((MATRIX/'artifacts/coverage/vm/r19c-nt31-usb-isolation/completed.json').read_text(encoding='utf-8'))
    if done.get('stopped') is not True:raise ValueError('No completed writer confirmation')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('100GiB reserve required')
    pre=load('nt31_candidate_preflight',ROOT/'tools/tests/preflight_usosnet31.py');pre.check(BUILD)
    manifest=json.loads((BUILD/'build.json').read_text(encoding='utf-8'))
    if sha(LOGGER)!=LOGGER_SHA:raise ValueError('Pinned strict DNS logger required')
    media=load('nt31_stage_original_media',MATRIX/'tools/tests/coverage/driver_audit.py')
    fat=load('nt31_stage_bounded_fat',ROOT.parent/'nt351-net/tools/tests/coverage/prepare_nt351_debug.py')
    hive=load('nt31_stage_regf11',MATRIX/'tools/tests/coverage/regf11.py')
    case,=json.loads((MATRIX/'artifacts/coverage/nt31-runtime-r19/plan.json').read_text(encoding='utf-8'))
    if sha(Path(case['source']))!=case['source_sha256']:raise ValueError('Original source archive mismatch')
    WORK.mkdir(parents=True);raw=WORK/'scratch-stopped.raw'
    result=dict(scope='Prepared stopped NT31 NCPA/own82576 overlay; no Windows LAN PASS',tag=TAG,base=str(BASE),base_sha256=BASE_SHA,
        driver_sha256=manifest['sha256'],driver_size=manifest['size'],helper_sha256=manifest['helper_sha256'],logger_sha256=LOGGER_SHA,
        original_archive_sha256=case['source_sha256'],original_iso_sha256=case['member_sha256'],oem_donor_sha256=OEM_SHA,
        nic='igb',bdf='00:05.0',mac='52:54:00:55:53:01',static_ip='10.0.2.15',mask='255.255.255.0',gateway='10.0.2.2',dns='10.0.2.3',dhcp='not applicable',runtime_pass=False)
    try:
        subprocess.run([str(QIMG),'convert','-f','qcow2','-O','raw',str(BASE),str(raw)],check=True,capture_output=True)
        fs=fat.BoundedFat(raw)
        try:
            if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Exact FAT16 stopped geometry required')
            protected={}
            for name in ('CONFIG/SYSTEM','DRIVERS/USOSUSB.SYS','DRIVERS/NDIS.SYS','DRIVERS/KBDCLASS.SYS','DRIVERS/MOUCLASS.SYS','NTOSKRNL.EXE','HAL.DLL','KERNEL32.DLL','ADVAPI32.DLL','USER32.DLL','GDI32.DLL','WSOCK32.DLL'):
                protected[name]=fat.file_data(fs,'WINNT/SYSTEM32/'+name,8*1024**2)[0]
            values=hive.Hive11(protected['CONFIG/SYSTEM']).values
            if values['select']['current']!=values['select']['default'] or values['select']['current']!=(4,struct.pack('<I',1)):raise ValueError('Ambiguous actual controlset')
            if values['controlset001\\services\\i8042prt']['start']!=(4,struct.pack('<I',4)):raise ValueError('USB OS isolation changed')
            if h(protected['DRIVERS/USOSUSB.SYS'])!='f5373eb3bf829d585651bc0da7ea5b1ca9b0cf2b20a1fe74ccb5054955f3ef05':raise ValueError('Frozen USB changed')
            modules={leaf.lower():protected[leaf] for leaf in ('NTOSKRNL.EXE','HAL.DLL','KERNEL32.DLL','ADVAPI32.DLL','USER32.DLL','GDI32.DLL','WSOCK32.DLL')}
            modules['ndis.sys']=protected['DRIVERS/NDIS.SYS']
            result['installed_import_preflight']={name:imports_against(path.read_bytes(),modules) for name,path in [('driver',BUILD/'usosnet31.sys'),('helper',BUILD/'NET31CFG.EXE'),('logger',LOGGER)]}
        finally:fs.f.close()
        warnings.filterwarnings('ignore',message='pkg_resources is deprecated as an API.*')
        from pyfatfs.PyFatFS import PyFatFS
        filesystem=PyFatFS(str(raw),offset=32256,preserve_case=False,utc=True)
        payloads={}
        def add(path,data):
            if filesystem.exists(path):raise ValueError('Never overwrite existing guest file '+path)
            filesystem.makedirs(str(Path(path).parent).replace('\\','/'),recreate=True)
            filesystem.writebytes(path,data)
            if filesystem.readbytes(path)!=data:raise ValueError('Immediate source readback differs')
            payloads[path]=h(data)
        try:
            if filesystem.exists('N31SRC') or filesystem.exists('N31OEM') or filesystem.exists('USOS/NET31'):raise ValueError('Fresh guest package paths required')
            with tempfile.TemporaryDirectory(dir=WORK,prefix='original-') as temp:
                original=Path(temp)
                subprocess.run([str(media.SEVEN),'e','-y','-o'+str(original),case['source'],case['member']],check=True,capture_output=True,timeout=120)
                iso=original/Path(case['member']).name
                if sha(iso)!=case['member_sha256']:raise ValueError('Original ISO mismatch')
                with iso.open('rb') as stream:
                    volume=media.media.ISO(stream);total=0;count=0;normalized=[]
                    for name,(lba,size,directory) in sorted(volume.entries.items()):
                        if directory or not name.startswith('i386/'):continue
                        destination=source_path(name)
                        if destination[7:].lower()!=name[5:]:normalized.append(dict(original=name,staged=destination))
                        total+=size;count+=1
                        if count>4096 or total>192*1024**2:raise ValueError('Bound original source staging')
                        stream.seek(lba*media.media.BLOCK);blob=stream.read(size)
                        if len(blob)!=size:raise ValueError('Original source truncated')
                        add(destination,blob)
                    unpack=media.cab.unpack;media.cab.unpack=lambda b,member=None:unpack(b,member,scratch=WORK/'packed')
                    donor=media.binary(volume,'i386/oemnadlb.in_');oem=own_oem(donor,manifest['size'])
                    add('N31OEM/OEMSETUP.INF',oem);result.update(original_source_files=count,original_source_bytes=total,private_oem_sha256=h(oem),iso_empty_extension_normalization=normalized)
            for i in range(1,51):
                for folder in ('N31SRC','N31OEM'):
                    p=folder+'/DISK'+str(i)
                    if not filesystem.exists(p):add(p,b'')
            own={'USNET31.SYS':(BUILD/'usosnet31.sys').read_bytes(),'NET31CFG.EXE':(BUILD/'NET31CFG.EXE').read_bytes(),'USOSLOG.EXE':LOGGER.read_bytes(),
                'NET31.ON':(TAG+'\r\n').encode('ascii'),
                'TESTNET.CMD':b'@echo off\r\nc:\r\ncd \\USOS\\NET31\r\necho NT31_REAL_GUEST>POST.LOG\r\nver>>POST.LOG\r\nping -n 3 10.0.2.2>>POST.LOG\r\nUSOSLOG.EXE /once /nohook /nodbg /nodisk /out C:\\USOS\\NET31\\NET31.LOG\r\necho NATIVE_COMMANDS_ISSUED>>POST.LOG\r\ntype POST.LOG\r\n',
                'README.TXT':b'Owned NT31 Intel test. Install adapter via NCPA Other C:\\N31OEM.\r\nUse C:\\N31SRC for original NT31 network files. Add original TCP/IP.\r\nSet IP10.0.2.15 mask255.255.255.0 gw10.0.2.2 DNS10.0.2.3.\r\nRun C:\\USOS\\NET31\\NET31CFG.EXE /configure before required reboot.\r\nAfter reboot run C:\\USOS\\NET31\\TESTNET.CMD. No DHCP in NT31.\r\n'}
            add('N31OEM/USNET31.SYS',own['USNET31.SYS'])
            for name,data in own.items():add('USOS/NET31/'+name,data)
        finally:filesystem.close()
        fs=fat.BoundedFat(raw)
        try:
            for name,before in protected.items():
                if fat.file_data(fs,'WINNT/SYSTEM32/'+name,8*1024**2)[0]!=before:raise ValueError('Protected guest file changed '+name)
            for path,wanted in payloads.items():
                c,attr,size=fs.find(path)
                if size:
                    data=fat.file_data(fs,path,128*1024**2)[0]
                    if h(data)!=wanted:raise ValueError('Independent FAT readback differs')
                elif wanted!=h(b''):raise ValueError('Missing staged file')
        finally:fs.f.close()
        target=WORK/'target.qcow2'
        subprocess.run([str(QIMG),'convert','-f','raw','-O','qcow2','-B',str(BASE),'-F','qcow2',str(raw),str(target)],check=True,capture_output=True)
        subprocess.run([str(QIMG),'compare','-f','raw','-F','qcow2',str(raw),str(target)],check=True,capture_output=True)
        shutil.copyfile(BASE.parent/'vars.fd',WORK/'vars.fd')
        subprocess.run([str(QIMG),'create','-q','-f','qcow2','-F','qcow2','-b',str(BASE.parent/'stick.qcow2'),str(WORK/'stick.qcow2')],check=True,capture_output=True)
        result.update(overlay=str(target),overlay_sha256=sha(target),vars_sha256=sha(WORK/'vars.fd'),stick_sha256=sha(WORK/'stick.qcow2'),protected_guest_files_unchanged=True,staged_readback_pass=True,payload_manifest_sha256=h(json.dumps(payloads,sort_keys=True).encode('utf-8')),base_unchanged=sha(BASE)==BASE_SHA)
        if not result['base_unchanged']:raise ValueError('Base changed')
        (WORK/'fixture.json').write_bytes((json.dumps(dict(folder='Windows NT 3.1',private_profile=False,system='windows-nt-3-1',result={'result':'PASS'},preparation='R24 own overlay; original NetworkControlPanel still required',manifest=str(OUT)),indent=2)+'\n').encode('utf-8'))
        OUT.parent.mkdir(parents=True,exist_ok=True)
    finally:
        if raw.exists() and raw.resolve().parent==WORK.resolve():raw.unlink()
    result.update(scratch_raw_removed=True,standalone_microsoft_modules_exported=False)
    OUT.write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
