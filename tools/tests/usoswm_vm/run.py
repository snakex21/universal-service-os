"""SPDX-License-Identifier: GPL-3.0-or-later
Fresh file-backed VM, serial evidence events and blocking process completion.

No progress polling. No physical disks or network exposed to the guest.
"""
from pathlib import Path
import argparse,hashlib,io,json,os,socket,subprocess,time,struct,threading
import pycdlib

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'zig-out/watermark/vm-tools'
TOOLS=ROOT/'tools'
SOURCE=Path(__file__).resolve().parent
ARCH='amd64'
NAMESPACE='urn:schemas-microsoft-com:unattend'
QMP_LOCK=threading.RLock()
def answer(control=False):
    text=r'''<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
<settings pass="windowsPE"><component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><SetupUILanguage><UILanguage>pl-PL</UILanguage></SetupUILanguage><InputLocale>pl-PL</InputLocale><SystemLocale>pl-PL</SystemLocale><UILanguage>pl-PL</UILanguage><UserLocale>pl-PL</UserLocale></component><component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk><CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions><ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>WMTEST</Label><Letter>C</Letter><Active>true</Active></ModifyPartition></ModifyPartitions></Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>
<UserData><AcceptEula>true</AcceptEula><FullName>USOS VM</FullName><Organization>USOS</Organization></UserData>
<RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd.exe /d /c for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %d:\USOSVM.TAG start "" /b %d:\USOS\WMTEST\setup-ui.exe</Path></RunSynchronousCommand></RunSynchronous>
<ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
</component></settings>
<settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>USOS-WM-VM</ComputerName><TimeZone>Central European Standard Time</TimeZone></component>
<component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd.exe /d /c for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %d:\USOSVM.TAG xcopy %d:\USOS C:\USOS\ /e /i /y</Path></RunSynchronousCommand><RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>cmd.exe /d /c bcdedit /set {current} testsigning on</Path><WillReboot>Always</WillReboot></RunSynchronousCommand></RunSynchronous></component></settings>
<settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<OOBE><HideEULAPage>true</HideEULAPage><NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE></OOBE>
<UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Password><Value>Local-VM-Only-2026!</Value><PlainText>true</PlainText></Password><Name>USOS</Name><Group>Administrators</Group><DisplayName>USOS VM</DisplayName></LocalAccount></LocalAccounts></UserAccounts>
<AutoLogon><Password><Value>Local-VM-Only-2026!</Value><PlainText>true</PlainText></Password><Enabled>true</Enabled><LogonCount>3</LogonCount><Username>USOS</Username></AutoLogon>
<FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd.exe /d /c start "" C:\USOS\WMTEST\wmprobe.exe</CommandLine><Description>Private cosmetic evidence test</Description></SynchronousCommand></FirstLogonCommands>
</component></settings></unattend>
'''
    if control:
        text=text.replace('cmd.exe /d /c bcdedit /set {current} testsigning on','cmd.exe /d /c exit /b 0').replace('<WillReboot>Always</WillReboot>','<WillReboot>Never</WillReboot>')
    return text.replace('processorArchitecture="amd64"','processorArchitecture="'+ARCH+'"')
def qmp_receive(f):
    while True:
        line=f.readline()
        if not line:raise RuntimeError('QMP closed')
        value=json.loads(line)
        if 'return' in value or 'error' in value:return value
def qmp_call(f,cmd,args=None):
    with QMP_LOCK:
        f.write((json.dumps({'execute':cmd,**({'arguments':args} if args else {})})+'\n').encode());f.flush()
        result=qmp_receive(f)
        if 'error' in result:raise RuntimeError(result)
        return result

def pe_console_helper(stream):
    # One scheduled action, no screen/status queries: open WinPE's normal
    # console and start the optional-key UI helper from our read-only CD.
    punctuation={':':'shift-semicolon','\\':'backslash','.':'dot',' ':'spc','-':'minus','%':'shift-5','(':'shift-9',')':'shift-0','"':'shift-apostrophe'}
    def type_text(text):
        for char in text:
            key=char if char.isalnum() else punctuation[char]
            qmp_call(stream,'human-monitor-command',{'command-line':'sendkey '+key+' 40'});threading.Event().wait(.06)
        qmp_call(stream,'human-monitor-command',{'command-line':'sendkey ret'})
    with QMP_LOCK:
        qmp_call(stream,'human-monitor-command',{'command-line':'sendkey shift-f10'});threading.Event().wait(1)
        type_text(r'for %d in (d e f g h i j k l m n o p q r s t u v w x y z) do if exist %d:\usosvm.tag start "" %d:\usos\wmtest\setup-ui.exe')
        threading.Event().wait(1);type_text('exit')
    print('One scheduled WinPE helper invocation sent',flush=True)
def build():
    tmp=WORK/'tmp';tmp.mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),ZIG_GLOBAL_CACHE_DIR=str(WORK/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(WORK/'zig-local'))
    exe=WORK/'wmprobe.exe'
    target=('x86' if ARCH=='x86' else 'x86_64')+'-windows.vista-gnu'
    subprocess.run([str(TOOLS/'zig/zig.exe'),'cc','-target',target,'-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(TOOLS/'zig/lib/libc/include/any-windows-any'),str(SOURCE/'probe.c'),'-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-luser32','-ladvapi32','-lshell32','-luxtheme','-o',str(exe)],env=env,check=True)
    subprocess.run([str(TOOLS/'zig/zig.exe'),'cc','-target',target,'-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(TOOLS/'zig/lib/libc/include/any-windows-any'),str(SOURCE/'setup-ui.c'),'-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-luser32','-ladvapi32','-o',str(WORK/'setup-ui.exe')],env=env,check=True)
    return exe
def answer_floppy(path,data):
    image=bytearray(1440*1024)
    image[:3]=b'\xeb\x3c\x90';image[3:11]=b'USOSWM  '
    struct.pack_into('<HBHBHHBHHHII',image,11,512,1,1,2,224,2880,0xf0,9,18,2,0,0)
    image[38]=0x29;image[43:54]=b'USOSWMTEST ';image[54:62]=b'FAT12   ';image[510:512]=b'\x55\xaa'
    fat=bytearray(9*512);fat[:3]=b'\xf0\xff\xff'
    clusters=(len(data)+511)//512
    for c in range(2,clusters+2):
        value=c+1 if c<clusters+1 else 0xfff;pos=c*3//2
        pair=struct.unpack_from('<H',fat,pos)[0]
        pair=(pair&0x000f)|(value<<4) if c&1 else (pair&0xf000)|value
        struct.pack_into('<H',fat,pos,pair)
    image[512:10*512]=fat;image[10*512:19*512]=fat
    # AUTOUNATTEND.XML needs a VFAT long-name entry plus its short alias.
    alias=b'AUTOUN~1XML';checksum=0
    for byte in alias:checksum=(((checksum&1)<<7)+(checksum>>1)+byte)&255
    name='Autounattend.xml'.encode('utf-16-le')+b'\0\0';name+=b'\xff\xff'*((26-len(name)//2))
    entries=[]
    for index in (2,1):
        entry=bytearray(32);entry[0]=index|(0x40 if index==2 else 0);entry[11]=0x0f;entry[13]=checksum
        chunk=name[(index-1)*26:index*26];entry[1:11]=chunk[:10];entry[14:26]=chunk[10:22];entry[28:32]=chunk[22:26];entries.append(entry)
    short=bytearray(32);short[:11]=alias;short[11]=0x20;struct.pack_into('<H',short,26,2);struct.pack_into('<I',short,28,len(data));entries.append(short)
    image[19*512:19*512+96]=b''.join(entries);image[33*512:33*512+len(data)]=data
    path.write_bytes(image)
def main():
    global WORK,TOOLS,ARCH
    ap=argparse.ArgumentParser();ap.add_argument('os',choices=['vista','server2008','win7','server2008r2']);ap.add_argument('--media',type=Path,required=True);ap.add_argument('--tool-root',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--component',type=Path);ap.add_argument('--control',action='store_true');ap.add_argument('--arch',choices=['amd64','x86'],default='amd64');ap.add_argument('--accel',choices=['whpx','tcg'],default='tcg');ap.add_argument('--pe-console-helper',action='store_true');ap.add_argument('--limit-seconds',type=int,default=3600);a=ap.parse_args()
    if a.media.suffix.lower()!='.iso' or not a.media.is_file():raise ValueError('A regular ISO file is required')
    if a.limit_seconds<300:raise ValueError('Minimum diagnostic deadline is 300 seconds')
    if not a.control and (a.arch!='amd64' or a.os not in ('vista','server2008') or not a.component):raise ValueError('Component trial requires Vista/2008 amd64 and --component; use --control elsewhere')
    ARCH=a.arch
    WORK=a.out.resolve();WORK.mkdir(parents=True,exist_ok=False);TOOLS=a.tool_root.resolve()
    folder=WORK
    target=folder/'target.qcow2'
    if target.exists():raise RuntimeError('Existing private target: do not overwrite')
    probe=build()
    iso=pycdlib.PyCdlib();iso.new(interchange_level=3,joliet=3,vol_ident='USOSWMTEST')
    for path in ('/USOS','/USOS/WMTEST','/USOS/USOSWM'):iso.add_directory(path,joliet_path=path)
    files={'/AUTOUNATTEND.XML;1':answer(a.control).encode(),'/USOSVM.TAG;1':b'USOS-WATERMARK-PRIVATE\n','/USOS/WMTEST/WMPROBE.EXE;1':probe.read_bytes(),'/USOS/WMTEST/SETUP_UI.EXE;1':(WORK/'setup-ui.exe').read_bytes()}
    # Joliet keeps the actual Windows filename; ISO9660 uses an underscore.
    files['/USOS/WMTEST/setup-ui.exe;1']=files.pop('/USOS/WMTEST/SETUP_UI.EXE;1')
    for name in (() if a.control else ('usoswm.exe','usoswm-desktop.dll','usoswm-register.exe')):
        component=a.component/name
        if not component.is_file():raise FileNotFoundError(component)
        files['/USOS/USOSWM/'+name.upper()+';1']=component.read_bytes()
    for name,data in files.items():iso.add_fp(io.BytesIO(data),len(data),iso_path=name.upper().replace('-','_'),joliet_path=name.removesuffix(';1'))
    support=folder/'answer.iso';iso.write(str(support));iso.close()
    floppy=folder/'answer.img';answer_floppy(floppy,answer(a.control).encode())
    subprocess.run([str(TOOLS/'qemu/qemu-img.exe'),'create','-q','-f','qcow2',str(target),'24G'],check=True)
    media=a.media.resolve()
    snapshot={'source':{name:hashlib.sha256((SOURCE/name).read_bytes()).hexdigest() for name in ('run.py','probe.c','setup-ui.c')},'control':a.control,'arch':a.arch,'accel':a.accel,'own_files':{name:hashlib.sha256(raw).hexdigest() for name,raw in files.items() if name.lower().endswith(('.exe;1','.dll;1'))}}
    (folder/'input-manifest.json').write_text(json.dumps(snapshot,indent=2))
    serial=socket.socket();serial.bind(('127.0.0.1',0));serial.listen();serial.settimeout(a.limit_seconds);sp=serial.getsockname()[1]
    qmp=socket.socket();qmp.bind(('127.0.0.1',0));qmp.listen();qmp.settimeout(60);qp=qmp.getsockname()[1]
    with socket.socket() as allocation:allocation.bind(('127.0.0.1',0));hp=allocation.getsockname()[1]
    cmd=[str(TOOLS/'qemu/qemu-system-x86_64.exe'),'-machine','pc','-accel',a.accel,'-cpu','max' if a.accel=='tcg' else 'qemu64,-xsave','-smp','2','-m','3072','-vga','std','-display','none','-nic','none','-boot','order=dc,menu=off','-drive',f'file={target},format=qcow2,if=ide,index=0','-drive',f'file={media},media=cdrom,readonly=on,if=ide,index=2','-drive',f'file={support},media=cdrom,readonly=on,if=ide,index=3','-drive',f'file={floppy},format=raw,if=floppy,readonly=on','-serial',f'tcp:127.0.0.1:{sp},server=off','-qmp',f'tcp:127.0.0.1:{qp},server=off','-monitor',f'tcp:127.0.0.1:{hp},server=on,wait=off','-rtc','base=2009-07-01T12:00:00,clock=host']
    (folder/'command.json').write_text(json.dumps(cmd,indent=2))
    started=time.monotonic()
    with (folder/'qemu.log').open('wb') as log:
        proc=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
        qf=None;helper_timer=None
        try:
            ser,_=serial.accept();ser.settimeout(a.limit_seconds);q,_=qmp.accept();q.settimeout(60);qf=q.makefile('rwb',buffering=0);json.loads(qf.readline());qmp_call(qf,'qmp_capabilities')
            (folder/'process.json').write_text(json.dumps({'pid':proc.pid,'started':time.time(),'hmp_port':hp}))
            time.sleep(3);qmp_call(qf,'human-monitor-command',{'command-line':'sendkey spc'})
            if a.pe_console_helper:
                helper_timer=threading.Timer(297,pe_console_helper,args=(qf,));helper_timer.daemon=True;helper_timer.start()
            print(a.os+' VM started; awaiting guest evidence events, no progress polling',flush=True)
            with (folder/'serial.log').open('wb') as events:
                sf=ser.makefile('rb')
                while True:
                    line=sf.readline()
                    if not line:break
                    events.write(line);events.flush()
                    text=line.decode(errors='replace').strip()
                    print(text,flush=True) # Guest-pushed events, never a status query.
                    if text.startswith(('WM_BASELINE_','WM_FILTERED_','WM_OPT_OUT_')) and text!='WM_BASELINE_COMPLETE':
                        shot=folder/(text.lower()+'.ppm');qmp_call(qf,'screendump',{'filename':str(shot)})
                        from PIL import Image
                        with Image.open(shot) as im:im.save(shot.with_suffix('.png'))
                        ser.sendall(b'A')
                    if text=='WM_BASELINE_COMPLETE':break
            result=proc.wait(timeout=max(1,a.limit_seconds-(time.monotonic()-started)))
            (folder/'result.json').write_text(json.dumps({'exit':result,'seconds':round(time.monotonic()-started,1)}))
            print('VM completed',a.os,result,flush=True)
        except (TimeoutError,subprocess.TimeoutExpired) as error:
            # The attempt has ended. Capture its failure endpoint before
            # closing our process, rather than polling its progress.
            try:
                if qf is not None:
                    shot=folder/'timeout.ppm';qmp_call(qf,'screendump',{'filename':str(shot)})
                    from PIL import Image
                    with Image.open(shot) as im:im.save(shot.with_suffix('.png'))
            finally:
                (folder/'result.json').write_text(json.dumps({'status':'timeout','error':type(error).__name__,'seconds':round(time.monotonic()-started,1)}))
            raise
        finally:
            if helper_timer:helper_timer.cancel()
            if proc.returncode is None:
                proc.terminate();proc.wait(timeout=60)
            serial.close();qmp.close()
if __name__=='__main__':main()
