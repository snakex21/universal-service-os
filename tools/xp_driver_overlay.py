"""Build a source-bound XP SP3 setup overlay. Never edit the source ISO.

Recipe: Patch Integrator 4.2.3 (NTOSKRNL, StorPort, KMDF, GenAHCI,
Microsoft USB3, ACPI sections). Changes are emitted only to the trial bundle.
"""
from pathlib import Path
import ctypes as c, hashlib, json, re, shutil, struct, subprocess, winreg

ROOT=Path(__file__).resolve().parents[1]
DRIVERS=ROOT/'media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86'
SEVEN='C:/Program Files/7-Zip/7z.exe'
META=('TXTSETUP.SIF','DOSNET.INF','HIVESYS.INF','SETUPREG.HIV')
SELECTED=['ACPI/acpi.sys','Dependencies/ntoskrn8.sys','Dependencies/storport.sys',
 'KMDF/wdf01000.sys','KMDF/wdfldr.sys','SATA/genahci.sys','SATA/genahci.inf',
 *['USB3/'+n for n in ('ksecd8.sys','ucx01000.sys','usbd8.sys','usbhub3.sys','usbhub3.inf','usbxhci.sys','usbxhci.inf','wpprecor.sys')]]
# These original XP dependencies may otherwise be loaded by text setup but left
# uncopied (SourceDisksFiles copy flags 1,3) before the GUI welcome prompt.
BUILTIN_USB=('usbport.sys','usbd.sys','hidclass.sys','hidparse.sys')

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def decode(b): return (b.decode('utf-16'), 'utf-16') if b.startswith(b'\xff\xfe') else (b.decode('latin1'),'latin1')
def key(line):return re.split(r'[=,]',line.strip(),1)[0].strip().lower()
def edit_section(text,section,rows,replace=True):
    """Edit all blocks of a section; retain unrelated entries and block order."""
    lines=text.splitlines(); starts=[i for i,l in enumerate(lines) if l.strip().lower()=='['+section.lower()+']']
    if not starts: return text.rstrip()+'\r\n\r\n['+section+']\r\n'+'\r\n'.join(rows)+'\r\n'
    # Original Microsoft media can split SourceDisksFiles.x86 across blocks.
    # Remove replaced keys from every block and append their single replacement
    # to the last block, preserving all other source declarations.
    start=starts[-1]+1;end=next((i for i in range(start,len(lines)) if lines[i].strip().startswith('[')),len(lines))
    remove={key(r) for r in rows}
    out=[];inside=False
    for i,line in enumerate(lines):
        if i==end:out.extend(rows)
        if line.strip().startswith('['):inside=line.strip().lower()=='['+section.lower()+']'
        if not (inside and replace and key(line) in remove):out.append(line)
    if end==len(lines):out.extend(rows)
    return '\r\n'.join(out)+'\r\n'
def drop_keys(text,section,names):
    inside=False;out=[]
    for l in text.splitlines():
        if l.strip().startswith('['):inside=l.strip().lower()=='['+section.lower()+']'
        if not inside or key(l) not in names:out.append(l)
    return '\r\n'.join(out)+'\r\n'

def registry_values():
    rows=[]
    def add(path,name,value,typ=None):rows.append((path,name,typ or (4 if isinstance(value,int) else 1),value))
    for service,group in [('Wdf01000','Boot Bus Extender'),('Ucx01000','System Bus Extender'),('USBXHCI','Input Device Support'),('USBHUB3','Input Device Support'),('genahci','SCSI miniport')]:
        p='Services\\'+service
        for n,v in [('Type',1),('Start',0),('ErrorControl',1),('Group',group)]:add(p,n,v)
        add(p,'ImagePath','system32\\drivers\\'+service.lower()+'.sys',2)
    for p,n,v in [
      (r'Control\Wdf\Kmdf\1','Version','1.11'),
      (r'Control\Wdf\Kmdf\KmdfLibrary\Versions\1','Service','Wdf01000'),
      (r'Control\Wdf\Kmdf\Ucx\Versions\1\1','Service','ucx01000'),
      (r'Control\Wdf\Schema\KmdfService','Type',0),
      (r'Control\Wdf\Schema\KmdfService\Object','KeyPath',r'CurrentControlSet\Services'),
      (r'Control\Wdf\Schema\KmdfService\Object','KeyRoot','SYSTEM'),
      (r'Services\Wdf01000\Parameters','BuildNumber',0),
      (r'Services\Wdf01000\Parameters','MajorVersion',1),
      (r'Services\Wdf01000\Parameters','MinorVersion',11),
      (r'Services\genahci\Parameters','BusType',11),
      (r'Services\genahci\Parameters\PnpInterface','5',1),
    ]:add(p,n,v)
    for hw,svc,guid in [(r'pci#cc_010601','genahci','4D36E97B-E325-11CE-BFC1-08002BE10318'),(r'pci#cc_0c0330','USBXHCI','36FC9E60-C465-11CF-8056-444553540000'),(r'usb#root_hub30','USBHUB3','36FC9E60-C465-11CF-8056-444553540000'),(r'usb#usb30_hub','USBHUB3','36FC9E60-C465-11CF-8056-444553540000'),(r'usb#usb20_hub','USBHUB3','36FC9E60-C465-11CF-8056-444553540000')]:
        add('Control\\CriticalDeviceDatabase\\'+hw,'Service',svc)
        add('Control\\CriticalDeviceDatabase\\'+hw,'ClassGUID','{'+guid+'}')
    return rows

def patch_hive(path):
    # Private app hive, not HKLM/HKU. Only the disposable build copy is modified.
    adv=c.WinDLL('advapi32',use_last_error=True)
    adv.RegLoadAppKeyW.argtypes=[c.c_wchar_p,c.POINTER(c.c_void_p),c.c_uint,c.c_uint,c.c_uint]
    adv.RegLoadAppKeyW.restype=c.c_long
    handle=c.c_void_p()
    rc=adv.RegLoadAppKeyW(str(path),c.byref(handle),winreg.KEY_ALL_ACCESS,1,0)
    if rc:raise OSError(rc,'RegLoadAppKeyW build copy')
    hive=handle.value
    try:
        for p,n,t,v in registry_values():
            with winreg.CreateKeyEx(hive,'ControlSet001\\'+p,0,winreg.KEY_ALL_ACCESS) as k:
                winreg.SetValueEx(k,n,0,t,v)
                assert winreg.QueryValueEx(k,n)==(v,t)
        winreg.FlushKey(hive)
    finally:winreg.CloseKey(hive)
    # Editing must not upgrade the XP hive format or leave a dirty header.
    b=path.read_bytes()
    assert b[:4]==b'regf' and b[4:8]==b[8:12]
    assert struct.unpack_from('<II',b,20)==(1,3) or struct.unpack_from('<II',b,20)==(1,5)

CRASH_DUMP=re.compile(r'(?im)^(HKLM,"SYSTEM\\CurrentControlSet\\Control\\CrashControl","CrashDumpEnabled",0x000100[0-9a-f]{2},)[ \t]*(\d+)[ \t]*(?=\r?$)')
def disable_crash_dump(text):
    """CrashDumpEnabled=0 from text-mode on. The dump stack (dump_ntoskrn8)
    bugchecked 0x50 during GUI setup; the forced power-off that followed left
    zero-filled WinSxS files. Refuse media that do not declare exactly one value."""
    found=CRASH_DUMP.findall(text)
    if len(found)!=1:raise ValueError('HIVESYS.INF must declare CrashDumpEnabled exactly once')
    return CRASH_DUMP.sub(lambda m:m.group(1)+'0',text)

def pack_file(src,dst):
    subprocess.run(['C:/Windows/System32/makecab.exe','/D','CompressionType=MSZIP',str(src),str(dst)],check=True,stdout=subprocess.DEVNULL)
    assert dst.read_bytes()[:4]==b'MSCF'

def build_driver_overlay(iso,out):
    out.mkdir(parents=True,exist_ok=True)
    original=out/'original';original.mkdir(exist_ok=True)
    subprocess.run([SEVEN,'e',str(iso),*['I386\\'+n for n in META],r'I386\SP3.CAB','WIN51IP.SP3','-o'+str(original),'-y'],check=True,stdout=subprocess.DEVNULL)
    if not (original/'WIN51IP.SP3').exists():raise ValueError('Driver experiment currently requires XP Professional SP3')
    for n in META:assert (original/n).is_file(),n
    cabdir=out/'sp3-files';cabdir.mkdir(exist_ok=True)
    subprocess.run([SEVEN,'e',str(original/'SP3.CAB'),'-o'+str(cabdir),'-y'],check=True,stdout=subprocess.DEVNULL)
    bundle=out/'bundle';bundle.mkdir(exist_ok=True)
    hashes=''.join(sha(original/n)+'  I386/'+n+'\n' for n in META)
    bundle_id=hashlib.sha256(hashes.encode()).hexdigest()
    (bundle/'source.sha256').write_text(hashes,encoding='ascii',newline='\n')
    i386=bundle/'I386';i386.mkdir(exist_ok=True)
    raw=out/'raw';raw.mkdir(exist_ok=True)
    expected={e['file']:e['sha256'] for e in json.loads((DRIVERS/'manifest.json').read_text())['files']}
    for name in SELECTED:
        src=DRIVERS/name
        if sha(src)!=expected[name]:raise ValueError('Driver package changed: '+name)
        p=raw/src.name.upper();shutil.copyfile(src,p)
        if p.suffix=='.INF':
            s=p.read_text(encoding='latin1')
            s=re.sub(r'(?im)^1\s*=.*$', '1="USOS XP drivers",,,"\\\\I386"',s)
            # Preinstalled boot services remain available after PnP installs INF.
            s=re.sub(r'(?im)^(StartType\s*=\s*)3\b',r'\g<1>0',s)
            p.write_bytes(s.encode('latin1'))
        pack_file(p,i386/(p.name[:-1]+'_'))
    native=out/'native-usb';native.mkdir(exist_ok=True)
    fallback=out/'source-driver-cache';fallback.mkdir(exist_ok=True)
    if any(not (cabdir/n).is_file() for n in BUILTIN_USB):
        # SP3.CAB contains updated files; unchanged XP files remain in DRIVER.CAB.
        subprocess.run([SEVEN,'e',str(iso),r'I386\DRIVER.CAB','-o'+str(original),'-y'],check=True,stdout=subprocess.DEVNULL)
        subprocess.run([SEVEN,'e',str(original/'DRIVER.CAB'),*BUILTIN_USB,'-o'+str(fallback),'-y'],check=True,stdout=subprocess.DEVNULL)
    for name in BUILTIN_USB:
        src=cabdir/name if (cabdir/name).is_file() else fallback/name
        if not src.is_file():raise ValueError('Source cabinets lack native USB dependency: '+name)
        shutil.copyfile(src,native/name)
        pack_file(src,i386/(name[:-1]+'_').upper())
    names=[Path(n).name.lower() for n in SELECTED]+list(BUILTIN_USB)
    sysnames=[n for n in names if n.endswith('.sys')]
    text,encoding=decode((original/'TXTSETUP.SIF').read_bytes())
    # Avoid x86-specific entries overriding changed generic entries (and vice versa).
    for sec in ['SourceDisksFiles','SourceDisksFiles.x86']:
        text=drop_keys(text,sec,set(names))
    rows=[n+' = 1,,,,,,'+('3_' if n in ('ntoskrn8.sys','storport.sys','wdf01000.sys','wdfldr.sys','acpi.sys')+BUILTIN_USB else '4_')+',4,0,0,,1,4' if n.endswith('.sys') else n+' = 1,,,,,,,20,0,0' for n in names]
    text=edit_section(text,'SourceDisksFiles.x86',rows)
    text=edit_section(text,'FileFlags',[n+' = 16' for n in sysnames])
    text=edit_section(text,'HardwareIdsDatabase',[r'PCI\CC_010601 = "genahci"',r'PCI\CC_0C0330 = "usbxhci"',r'USB\ROOT_HUB30 = "usbhub3"',r'USB\USB30_HUB = "usbhub3"',r'USB\USB20_HUB = "usbhub3"'])
    text=edit_section(text,'SCSI.Load',['genahci = genahci.sys,4'])
    text=edit_section(text,'SCSI',['genahci = "USOS Generic SATA AHCI"'])
    for group,svc,label,files in [
      ('BootBusExtenders','wdf01000','Kernel-Mode Driver Framework 1.11',['wdf01000.sys','wdfldr.sys','ntoskrn8.sys']),
      ('BusExtenders','ucx01000','USB Controller Extension',['ucx01000.sys','wdfldr.sys','wpprecor.sys']),
      ('InputDevicesSupport','usbxhci','USB 3 xHCI Controller',['usbxhci.sys','wdfldr.sys','usbport.sys','usbd.sys','hidparse.sys','hidclass.sys']),
      ('InputDevicesSupport','usbhub3','USB 3 Hub',['usbhub3.sys','wdfldr.sys','ksecd8.sys','usbd8.sys'])]:
        text=edit_section(text,group+'.Load',[svc+' = '+svc+'.sys'])
        text=edit_section(text,group,[f'{svc} = "{label}",files.{svc},{svc}'])
        text=edit_section(text,'files.'+svc,[n+',4' for n in files])
    (i386/'TXTSETUP.SIF').write_bytes(text.encode(encoding))
    text,encoding=decode((original/'DOSNET.INF').read_bytes())
    for sec,items in [('Files',names),('FloppyFiles.1',sysnames)]:
        # DOSNET rows share d1, so their identity is the whole row, not its first field.
        text=edit_section(text,sec,['d1,'+n for n in items],replace=False)
    (i386/'DOSNET.INF').write_bytes(text.encode(encoding))
    text,encoding=decode((original/'HIVESYS.INF').read_bytes())
    reglines=[]
    for p,n,t,v in registry_values():
        flags={1:'0x00000000',2:'0x00020000',4:'0x00010001'}[t]
        encoded=hex(v) if t==4 else v
        reglines.append(f'HKLM,"SYSTEM\\CurrentControlSet\\{p}","{n}",{flags},"{encoded}"')
    text=edit_section(text,'AddReg',reglines,replace=False)
    text=disable_crash_dump(text)
    (i386/'HIVESYS.INF').write_bytes(text.encode(encoding))
    # Only disposable build files; never reuse transaction logs from an earlier hive.
    for suffix in ('.LOG','.LOG1','.LOG2'):(i386/('SETUPREG.HIV'+suffix)).unlink(missing_ok=True)
    shutil.copyfile(original/'SETUPREG.HIV',i386/'SETUPREG.HIV');patch_hive(i386/'SETUPREG.HIV')
    for suffix in ('.LOG','.LOG1','.LOG2'):(i386/('SETUPREG.HIV'+suffix)).unlink(missing_ok=True)
    # PnP can extract ACPI from SP3.CAB later, so replace its copy too.
    acpi=[p for p in cabdir.iterdir() if p.name.lower()=='acpi.sys']
    if len(acpi)!=1:raise ValueError('SP3.CAB lacks unique ACPI; refusing incomplete integration')
    shutil.copyfile(DRIVERS/'ACPI/acpi.sys',acpi[0])
    ddf=out/'sp3.ddf'
    directives=['.OPTION EXPLICIT','.Set Cabinet=on','.Set Compress=on','.Set CompressionType=MSZIP','.Set MaxDiskSize=0','.Set CabinetNameTemplate=SP3.CAB',f'.Set DiskDirectoryTemplate="{i386}"',f'.Set RptFileName="{out / "sp3.rpt"}"',f'.Set InfFileName="{out / "sp3.inf"}"']
    directives += ['"'+str(p)+'" '+p.name for p in sorted(cabdir.iterdir()) if p.is_file()]
    ddf.write_text('\n'.join(directives)+'\n',encoding='ascii')
    subprocess.run(['C:/Windows/System32/makecab.exe','/F',str(ddf)],check=True,stdout=subprocess.DEVNULL)
    (bundle/'payload.sha256').write_text(''.join(sha(p)+'  I386/'+p.name+'\n' for p in sorted(i386.iterdir()) if p.is_file()),encoding='ascii',newline='\n')
    (bundle/'replace-names.txt').write_text('\n'.join(n.upper() for n in names)+'\n',encoding='ascii',newline='\n')
    report={'id':bundle_id,'source':iso.name,'source_size':iso.stat().st_size,'drivers':SELECTED,'native_usb_dependencies':{n:sha(native/n) for n in BUILTIN_USB},'sha256':{p.relative_to(bundle).as_posix():sha(p) for p in bundle.rglob('*') if p.is_file() and p.name!='manifest.json'},'runtime_verified':False}
    (bundle/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print('XP_DRIVER_OVERLAY_BUILT',bundle_id,'SYS/INF',len(names),flush=True)
    return bundle_id,bundle
