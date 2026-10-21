"""Read a stopped R20 disk, then optionally change only i8042prt Start on a new overlay.

Microsoft hive/driver contents stay in RAM or a temporary owned raw disk on G:.
No host registry APIs are called. Version detection precedes hive parsing.
"""
from pathlib import Path
import argparse, hashlib, importlib.util, json, shutil, struct, subprocess, tempfile

ROOT=Path(__file__).resolve().parents[3]
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
BASE=COLLECTION/'_vm/r20-nt35-preserved/target.qcow2'
WORK=COLLECTION/'_vm/r20b-nt35-usb-isolation'
OUT=ROOT/'artifacts/nt35-network'
DRIVER='e1aa69a3ec8e3da802013131abbb6fefc9f466da6f4eeb66fe15ec47e60421c5'
USB='2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1'

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

h=load('nt35_stopped_fat',Path(__file__).with_name('prepare_nt351_debug.py'))

def read_hive(data):
    if data[:4]!=b'regf' or data[4:8]!=data[8:12] or h.hive.checksum(data)!=struct.unpack_from('<I',data,508)[0]:
        raise ValueError('Unclean or invalid SYSTEM hive')
    version=struct.unpack_from('<II',data,20)
    if version==(1,1):
        reader=load('nt35_regf11',MATRIX/'tools/tests/coverage/regf11.py').Hive11(data)
        return reader.values,reader,version
    if version==(1,2):return h.hive.read_hive_content(data),None,version
    raise ValueError('Only measured REGF1.1/1.2 SYSTEM formats are allowed')

def replace_start(data,values,reader,key):
    if reader is not None:return reader.replace_dword(key,'start',1,4)
    found=[]
    for path,at,nk,node in h.hive._nodes(data):
        rel=path.split('\\',1)[1].lower() if '\\' in path else ''
        if rel!=key:continue
        count,vlist=struct.unpack_from('<II',nk,36);entries=h.hive._cell(data,vlist)
        for i in range(count):
            off=struct.unpack_from('<I',entries,4*i)[0];vk=h.hive._cell(data,off)
            nlen=struct.unpack_from('<H',vk,2)[0];flags=struct.unpack_from('<H',vk,16)[0]
            if h.hive._name(vk[20:20+nlen],flags&1).lower()!='start':continue
            length,where,kind=struct.unpack_from('<III',vk,4)
            if kind!=4 or length&0x7fffffff!=4:raise ValueError('Start is not one existing DWORD')
            found.append(h.hive.HBIN+off+12 if length&0x80000000 else h.hive.HBIN+where+4)
    if len(found)!=1:raise ValueError('Ambiguous Start storage')
    at=found[0];changed=bytearray(data);struct.pack_into('<I',changed,at,4)
    return bytes(changed),at

def scoped_services(values,number):
    result={}
    for service in ('i8042prt','kbdclass','mouclass','usosusb','ndisloop','ndisloop1'):
        key=f'controlset{number:03d}\\services\\{service}';node=values.get(key,{})
        result[service]={}
        for name in ('start','type','group','dependonservice','dependongroup','imagepath'):
            if name not in node:continue
            kind,raw=node[name]
            result[service][name]={'type':kind,'value':struct.unpack('<I',raw)[0] if kind==4 and len(raw)==4 else raw.decode('utf-16le').rstrip('\0') if kind in (1,2,7) else raw.hex()}
        if service in ('kbdclass','mouclass'):
            params=values.get(key+'\\parameters',{})
            result[service]['parameters']={n:struct.unpack('<I',params[n][1])[0] for n in ('connectmultipleports','maximumportsserviced') if n in params and params[n][0]==4 and len(params[n][1])==4}
    return result

def main(prepare=False):
    previous=MATRIX/'artifacts/coverage/vm/r20-nt35-network-hid'
    record_path=OUT/('r20b-usb-isolation-preparation.json' if prepare else 'r20-stopped-input-readback.json')
    if record_path.exists() or prepare and WORK.exists():raise FileExistsError('Fresh owned evidence required')
    prior=json.loads((previous/'result.json').read_text(encoding='utf-8'))
    meta=json.loads((previous/'fixture.json').read_text(encoding='utf-8'))
    if prior.get('qemu_returncode')!=0 or not (previous/'cleanup.json').is_file():raise ValueError('Baseline writer completion absent')
    if meta.get('private_profile') is not False or meta.get('folder')!='Windows NT 3.5':raise ValueError('Explicit keyless NT35 required')
    if BASE.resolve().parent!=COLLECTION/'_vm/r20-nt35-preserved':raise ValueError('Unexpected stopped base')
    if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('Less than100GiB disk free')
    def digest(path):
        with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
    base_hash=digest(BASE)
    if prepare:
        measured=json.loads((OUT/'r20-stopped-input-readback.json').read_text(encoding='utf-8'))
        if measured.get('base_sha256')!=base_hash or measured.get('base_unchanged') is not True:
            raise ValueError('Stopped readback does not pin this exact base')
    scratch_parent=COLLECTION/'_vm/r20-stopped-analysis';scratch_parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fat-',dir=scratch_parent) as tmp:
        raw=Path(tmp)/'stopped.raw'
        subprocess.run([str(h.QIMG),'convert','-f','qcow2','-O','raw',str(BASE),str(raw)],check=True)
        fs=h.BoundedFat(raw)
        try:
            if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Unexpected NT35 FAT16 layout')
            system,offsets=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
            driver,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet35.sys',16384)
            usb,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosusb.sys',32128)
            if len(driver)!=16384 or hashlib.sha256(driver).hexdigest()!=DRIVER:raise ValueError('Installed own LAN hash differs')
            if len(usb)!=32128 or hashlib.sha256(usb).hexdigest()!=USB:raise ValueError('Installed frozen USB hash differs')
            cluster_size=fs.csize
        finally:fs.f.close()
        values,reader,version=read_hive(system)
        current=values['select']['current'];default=values['select']['default']
        if current!=default or current[0]!=4 or len(current[1])!=4:raise ValueError('Ambiguous current/default controlset')
        number=struct.unpack('<I',current[1])[0]
        if not 1<=number<=999:raise ValueError('Invalid controlset number')
        services=scoped_services(values,number)
        record=dict(base=str(BASE),base_sha256=base_hash,hive_version=version,current=number,default=number,
            services=services,driver_sha256=DRIVER,usb_sha256=USB,stopped=True,ms_hive_or_driver_exported=False)
        if prepare:
            key=f'controlset{number:03d}\\services\\i8042prt'
            if values[key].get('start')!=(4,struct.pack('<I',1)):raise ValueError('i8042prt Start must be1')
            for service in ('kbdclass','mouclass','usosusb'):
                node=values[f'controlset{number:03d}\\services\\{service}']
                if node.get('start')!=(4,struct.pack('<I',1)):raise ValueError('Own USB/classes must remain Start1')
                if service!='usosusb' and any(n in node for n in ('dependonservice','dependongroup')):raise ValueError('Unreviewed class dependency')
            changed,at=replace_start(system,values,reader,key)
            expected={k:dict(v) for k,v in values.items()};expected[key]['start']=(4,struct.pack('<I',4))
            if read_hive(changed)[0]!=expected or changed[:at]!=system[:at] or changed[at+4:]!=system[at+4:]:raise ValueError('Unexpected hive content or byte diff')
            with raw.open('r+b') as stream:
                for index,offset in enumerate(offsets):stream.seek(offset);stream.write(changed[index*cluster_size:(index+1)*cluster_size])
                stream.flush()
            fs=h.BoundedFat(raw)
            try:
                if h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)[0]!=changed:raise ValueError('Changed SYSTEM readback mismatch')
                for name,data in (('usosnet35.sys',driver),('usosusb.sys',usb)):
                    if h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/'+name,len(data))[0]!=data:raise ValueError('Own SYS changed')
            finally:fs.f.close()
            WORK.mkdir()
            subprocess.run([str(h.QIMG),'convert','-f','raw','-O','qcow2','-B',str(BASE),'-F','qcow2',str(raw),str(WORK/'target.qcow2')],check=True)
            subprocess.run([str(h.QIMG),'compare','-f','raw','-F','qcow2',str(raw),str(WORK/'target.qcow2')],check=True)
            meta.update(stopped_parent=str(BASE),i8042prt_start=4,usb_input_isolation=True)
            (WORK/'fixture.json').write_bytes((json.dumps(meta,indent=2)+'\n').encode('utf-8'))
            record.update(overlay=str(WORK/'target.qcow2'),key=key,before=1,after=4,hive_value_offset=at,
                hive_only_one_dword_changed=True,own_sys_unchanged=True,raw_overlay_qemu_compare_pass=True,
                system_before_sha256=hashlib.sha256(system).hexdigest(),system_after_sha256=hashlib.sha256(changed).hexdigest())
    if digest(BASE)!=base_hash:raise ValueError('Stopped base changed')
    record.update(base_unchanged=True,scratch_raw_removed=True)
    record_path.write_bytes((json.dumps(record,indent=2)+'\n').encode('utf-8'))
    print(json.dumps(record,indent=2),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--prepare',action='store_true')
    main(parser.parse_args().prepare)
