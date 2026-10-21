"""Hash-bound original NT3.1 full-MAC ABI audit; expanded modules stay in RAM."""
from pathlib import Path
import hashlib, importlib.util, json, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[2]
MATRIX = Path(r'C:\Users\ASRock\usos-work\macierz-windows')
OWN = Path(r'G:\USOS-Kolekcja\_audit\nt31-fullmac-contract').resolve()
OUT = ROOT/'artifacts/nt31-fullmac-contract/result.json'
PINS = {'ndis.sys':'9f34331567762728ed67b25733583c248c635220d475b74014fda8f653556950',
        'ne2000.sys':'c5fbffbf5d8de7b35f6812f46c176490c568853f2ea564bc363f5c826e17d7cb'}
SELECTED = ('NdisRegisterMac','NdisRegisterAdapter','NdisAllocateSharedMemory',
            'NdisMapIoSpace','NdisInitializeTimer','NdisSetTimer',
            'EthCreateFilter','EthFilterIndicateReceive','EthFilterIndicateReceiveComplete')

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    if OUT.exists():raise FileExistsError('Completed audit must not be overwritten')
    if not OWN.is_relative_to(Path(r'G:\USOS-Kolekcja\_audit').resolve()):raise ValueError('Scratch escaped')
    if shutil.disk_usage(OWN.anchor).free<100*1024**3:raise ValueError('100GiB reserve required')
    OWN.mkdir(parents=True,exist_ok=True)
    media=load('nt31_original_media',MATRIX/'tools/tests/coverage/driver_audit.py')
    decoder=load('nt31_fullmac_decoder',Path(r'C:\Users\ASRock\usos-work\nt351-net\tools\tests\audit_nt351_ndis_exports.py'))
    decoder.SELECTED=SELECTED;decoder.CALLS=set(SELECTED)|{'NdisInitializeWrapper','NdisDeregisterAdapter','NdisDeregisterMac'}
    unpack=media.cab.unpack
    media.cab.unpack=lambda blob,member=None:unpack(blob,member,scratch=OWN/'packed')
    cases=json.loads((MATRIX/'artifacts/coverage/nt31-runtime-r19/plan.json').read_text(encoding='utf-8'))
    case,=[c for c in cases if c['system']=='windows-nt-3-1']
    source=Path(case['source'])
    if digest(source)!=case['source_sha256']:raise ValueError('Archive mismatch')
    report=dict(scope='Original full-MAC ABI audit only; no own Intel implementation or network runtime PASS',
                archive_sha256=case['source_sha256'],iso_sha256=case['member_sha256'],modules={},
                public_declaration_reference='https://github.com/reactos/reactos/blob/master/sdk/include/ddk/ndis.h',
                script_sha256=digest(Path(__file__)))
    with tempfile.TemporaryDirectory(prefix='original-',dir=OWN) as temporary:
        work=Path(temporary).resolve()
        if not work.is_relative_to(OWN):raise ValueError('Temporary path escaped')
        subprocess.run([str(media.SEVEN),'e','-y','-o'+str(work),str(source),case['member']],
                       check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=120)
        iso=work/Path(case['member']).name
        if digest(iso)!=case['member_sha256']:raise ValueError('ISO mismatch')
        with iso.open('rb') as stream:
            volume=media.media.ISO(stream)
            for leaf in PINS:
                blob,member=media.module_from_iso(volume,leaf)
                if blob is None or hashlib.sha256(blob).hexdigest()!=PINS[leaf]:raise ValueError('Original module mismatch')
                pe=decoder.pefile.PE(data=blob,fast_load=False)
                md=decoder.capstone.Cs(decoder.capstone.CS_ARCH_X86,decoder.capstone.CS_MODE_32);md.detail=True
                info=decoder.instructions(blob,export_functions=leaf=='ndis.sys')
                rvas={name:int(rva,0) for name,rva in info['exports_rva'].items() if name in SELECTED}
                if leaf=='ne2000.sys':rvas={'DriverEntry':pe.OPTIONAL_HEADER.AddressOfEntryPoint}
                cfg={name:decoder.control_flow(md,pe,rva,limit=800) for name,rva in rvas.items()}
                if leaf=='ne2000.sys':
                    # Exact DriverEntry stores: independently compare the public
                    # 56-byte full-MAC declaration with this original module.
                    base=pe.OPTIONAL_HEADER.ImageBase;mapped=pe.get_memory_mapped_image()
                    stores={}
                    for item in cfg['DriverEntry']['instructions']:
                        rva=int(item['rva'],0)
                        instruction=next(md.disasm(mapped[rva:rva+15],base+rva,count=1))
                        ops=instruction.operands
                        if instruction.mnemonic=='mov' and len(ops)==2 and ops[0].type==decoder.X86_OP_MEM and ops[1].type==decoder.X86_OP_IMM:
                            mem=ops[0].mem
                            if not mem.base and not mem.index:stores[mem.disp]=(rva,ops[1].imm)
                    fields=('OpenAdapter','CloseAdapter','Send','TransferData','Reset','Request',
                            'QueryGlobalStatistics','UnloadMac','AddAdapter','RemoveAdapter')
                    callbacks={}
                    for index,name in enumerate(fields):
                        at,value=stores[base+0x5610+8+index*4]
                        if not base<=value<base+len(mapped):raise ValueError('Unexpected original callback pointer')
                        callbacks[name]=dict(table_field_offset=8+index*4,store_rva=hex(at),callback_rva=hex(value-base),
                                             cfg=decoder.control_flow(md,pe,value-base,limit=800))
                    cfg['callbacks']=callbacks
                report['modules'][leaf]=dict(sha256=PINS[leaf],member=member,entry_rva=hex(pe.OPTIONAL_HEADER.AddressOfEntryPoint),
                    selected_direct_cfg=cfg,import_call_contexts=info['import_call_contexts'])
    report.update(temporary_iso_removed=not work.exists(),expanded_microsoft_files_persisted=False,runtime_pass=False)
    OUT.parent.mkdir(parents=True,exist_ok=True)
    OUT.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(result='AUDIT_COMPLETE',output=str(OUT),temporary_iso_removed=report['temporary_iso_removed'],
                          selected={leaf:list(info['selected_direct_cfg']) for leaf,info in report['modules'].items()},runtime_pass=False)),flush=True)

if __name__=='__main__':main()
