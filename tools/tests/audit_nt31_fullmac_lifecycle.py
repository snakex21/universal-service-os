"""New original-media measurement: full-MAC resources, bindings and teardown.

Expanded Microsoft modules stay in RAM. Only hashes, names, RVAs and bounded
instruction metadata are retained. This script never launches QEMU.
"""
from pathlib import Path
import hashlib,json,shutil,subprocess,tempfile
import importlib.util

ROOT=Path(__file__).resolve().parents[2]
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
OWN=Path(r'G:\USOS-Kolekcja\_audit\nt31-fullmac-lifecycle').resolve()
OUT=ROOT/'artifacts/nt31-fullmac-contract/lifecycle-01.json'
NDIS=('NdisRegisterMac','NdisDeregisterMac','NdisRegisterAdapter','NdisDeregisterAdapter',
      'NdisOpenConfiguration','NdisReadConfiguration','NdisCloseConfiguration',
      'NdisMapIoSpace','NdisUnmapIoSpace','NdisAllocateSharedMemory','NdisFreeSharedMemory',
      'NdisAllocateMemory','NdisFreeMemory','NdisInitializeInterrupt','NdisRemoveInterrupt','NdisSynchronizeWithInterrupt',
      'NdisInitializeTimer','NdisSetTimer','NdisCancelTimer','NdisCompleteOpenAdapter','NdisCompleteCloseAdapter',
      'NdisCompleteSend','NdisCompleteRequest','NdisCompleteReset','EthCreateFilter','EthDeleteFilter',
      'EthNoteFilterOpenAdapter','EthDeleteFilterOpenAdapter','EthFilterAdjust','EthChangeFilterAddresses',
      'EthFilterIndicateReceive','EthFilterIndicateReceiveComplete','NdisReadPciSlotInformation',
      'NdisWritePciSlotInformation','NdisPciAssignResources','NdisReadPciSlotInformation')
HAL=('HalGetBusData','HalGetBusDataByOffset','HalSetBusData','HalSetBusDataByOffset',
     'HalAssignSlotResources','HalTranslateBusAddress','HalGetAdapter','HalGetInterruptVector','KeGetCurrentIrql')
KERNEL=('IoReportResourceUsage','KeInitializeDpc','KeInsertQueueDpc','KeRemoveQueueDpc','KeInitializeTimer',
        'KeSetTimer','KeCancelTimer','KeInitializeEvent','KeWaitForSingleObject','KeSetEvent',
        'MmAllocateContiguousMemory','MmGetPhysicalAddress','MmMapIoSpace','MmUnmapIoSpace',
        'KeRaiseIrql','KfRaiseIrql','KeLowerIrql','KfLowerIrql')

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def protected_binaries():
    rows={}
    for tree,leaf in (('nt351-net','usosnet4.sys'),('nt351-net','usosnet.sys'),('nt351-net','usosnet351.sys'),('nt35-net','usosnet35.sys')):
        path=ROOT.parent/tree/'tools/nt/usosnet/bin/i386'/leaf;rows[str(path)]=digest(path)
    return rows

def main():
    if OUT.exists():raise FileExistsError('Never overwrite a completed original-media measurement')
    if not OWN.is_relative_to(Path(r'G:\USOS-Kolekcja\_audit').resolve()):raise ValueError('Owned audit scratch required')
    if shutil.disk_usage(OWN.anchor).free<100*1024**3:raise ValueError('100GiB reserve required')
    OWN.mkdir(parents=True,exist_ok=True)
    parent=load('nt31_original_contract',Path(__file__).with_name('audit_nt31_fullmac.py'))
    media=load('nt31_lifecycle_media',MATRIX/'tools/tests/coverage/driver_audit.py')
    decoder=load('nt31_lifecycle_decoder',ROOT.parent/'nt351-net/tools/tests/audit_nt351_ndis_exports.py')
    decoder.SELECTED=NDIS;decoder.CALLS=set(NDIS)|set(HAL)|set(KERNEL)|{'NdisInitializeWrapper','NdisTerminateWrapper','NdisStallExecution'}
    unpack=media.cab.unpack;media.cab.unpack=lambda blob,member=None:unpack(blob,member,scratch=OWN/'packed')
    case,=json.loads((MATRIX/'artifacts/coverage/nt31-runtime-r19/plan.json').read_text(encoding='utf-8'))
    if case['system']!='windows-nt-3-1' or digest(Path(case['source']))!=case['source_sha256']:raise ValueError('Pinned original archive required')
    before=protected_binaries()
    report=dict(scope='Static full-MAC lifecycle/resource contract only; no Intel implementation or runtime PASS',
        archive_sha256=case['source_sha256'],iso_sha256=case['member_sha256'],script_sha256=digest(Path(__file__)),modules={},protected_binaries=before)
    with tempfile.TemporaryDirectory(prefix='original-',dir=OWN) as temporary:
        work=Path(temporary).resolve()
        if not work.is_relative_to(OWN):raise ValueError('Temporary path escaped owned audit')
        subprocess.run([str(media.SEVEN),'e','-y','-o'+str(work),case['source'],case['member']],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=120)
        iso=work/Path(case['member']).name
        if digest(iso)!=case['member_sha256']:raise ValueError('Pinned original ISO required')
        with iso.open('rb') as stream:
            volume=media.media.ISO(stream)
            for leaf,selected in (('ndis.sys',NDIS),('ne2000.sys',()),('hal.dll',HAL),('ntoskrnl.exe',KERNEL)):
                blob,member=media.module_from_iso(volume,leaf)
                if blob is None:raise ValueError('Original module absent '+leaf)
                sha=hashlib.sha256(blob).hexdigest()
                if leaf in parent.PINS and sha!=parent.PINS[leaf]:raise ValueError('Original module pin changed')
                pe=decoder.pefile.PE(data=blob,fast_load=False);base=pe.OPTIONAL_HEADER.ImageBase
                md=decoder.capstone.Cs(decoder.capstone.CS_ARCH_X86,decoder.capstone.CS_MODE_32);md.detail=True;md.skipdata=True
                exports={e.name.decode('ascii'):e.address for e in pe.DIRECTORY_ENTRY_EXPORT.symbols if e.name} if hasattr(pe,'DIRECTORY_ENTRY_EXPORT') else {}
                rvas={name:exports[name] for name in selected if name in exports}
                if leaf=='ne2000.sys':
                    rvas={'RegisterAdapterHelper':0x940,'RemoveAdapter':0x1b40,'UnloadMac':0x1b10,
                          'OpenAdapter':0xcd0,'CloseAdapter':0xf50,'Request':0x10f0,
                          'Timer220':0x3600,'Timer138':0x4c50,'Timer188_1d0':0x22f0}
                cfg={name:decoder.control_flow(md,pe,rva,limit=4000 if name in ('NdisRegisterAdapter','IoReportResourceUsage') else 2000) for name,rva in rvas.items()}
                iat={i.address:i.name.decode('ascii') for m in getattr(pe,'DIRECTORY_ENTRY_IMPORT',()) for i in m.imports if i.name}
                thunks={}
                if leaf in ('ndis.sys','ne2000.sys'):
                    for section in pe.sections:
                        if section.Characteristics&0x20000000:
                            for inst in md.disasm(section.get_data(),base+section.VirtualAddress):
                                if inst.mnemonic=='jmp' and len(inst.operands)==1 and inst.operands[0].type==decoder.X86_OP_MEM:
                                    mem=inst.operands[0].mem
                                    if not mem.base and not mem.index and mem.disp in iat:thunks[hex(inst.address-base)]=iat[mem.disp]
                info=decoder.instructions(blob,False) if leaf in ('ndis.sys','ne2000.sys') else {}
                report['modules'][leaf]=dict(member=member,sha256=sha,image_base=hex(base),exports_rva={n:hex(v) for n,v in sorted(exports.items())},
                    selected_presence={n:n in exports for n in selected},import_iat={hex(at-base):name for at,name in iat.items()},import_thunks=thunks,
                    direct_cfg=cfg,import_call_contexts=info.get('import_call_contexts',[]))
    if protected_binaries()!=before:raise ValueError('Protected other OS bin changed')
    report.update(temporary_iso_removed=not work.exists(),expanded_microsoft_files_persisted=False,protected_binaries_unchanged=True,runtime_pass=False)
    encoded=(json.dumps(report,indent=2)+'\n').encode('utf-8')
    if len(encoded)>12*1024**2:raise ValueError('Metadata output bound exceeded')
    OUT.write_bytes(encoded)
    print(json.dumps(dict(result='AUDIT_COMPLETE',output=str(OUT),metadata_bytes=len(encoded),temporary_iso_removed=report['temporary_iso_removed'],
        summaries={leaf:dict(sha256=info['sha256'],selected_presence=info['selected_presence'],cfg={n:dict(instructions=len(c['instructions']),truncated=c['truncated']) for n,c in info['direct_cfg'].items()}) for leaf,info in report['modules'].items()}),indent=2))

if __name__=='__main__':main()
