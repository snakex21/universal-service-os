"""Static inspection only; never execute Vista binaries on the host."""
import pefile,capstone,re
p=pefile.PE('M:/Windows/System32/oobe/msoobe.exe');base=p.OPTIONAL_HEADER.ImageBase
for address in [0x100004e70,0x100010508]:
 b=p.get_data(address-base,512);text=b.decode('utf-16le',errors='replace').split('\0')[0]
 print('STRING',hex(address),text)
for lib in p.DIRECTORY_ENTRY_IMPORT:
 for imp in lib.imports:
  if imp.address==0x100001048:print('IMPORT',imp.name)
targets={}
for text in ['SkipMachineOOBE','SkipUserOOBE','Unattend','OOBE']:
 needle=text.encode('utf-16le')+b'\0\0';pos=0
 while (pos:=p.__data__.find(needle,pos))>=0:
  targets[base+p.get_rva_from_offset(pos)]=text;pos+=len(needle)
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64);md.skipdata=True
funcs=[(base+x.struct.BeginAddress,base+x.struct.EndAddress) for x in p.DIRECTORY_ENTRY_EXCEPTION]
matched=set()
for sec in p.sections:
 if not sec.Characteristics&0x20000000:continue
 for address,size,mnemonic,ops in md.disasm_lite(sec.get_data(),base+sec.VirtualAddress):
  match=re.search(r'\[rip ([+-]) (0x[0-9a-f]+)\]',ops)
  if not match:continue
  ref=address+size+int(match[2],16)*(1 if match[1]=='+' else -1)
  if ref not in targets or not targets[ref].startswith('Skip'):continue
  print('REFERENCE',targets[ref],hex(address))
  for start,end in funcs:
   if start<=address<end and start not in matched:
    matched.add(start);print('FUNCTION',hex(start),hex(end))
    for ins in md.disasm_lite(p.get_data(start-base,end-start),start):
     if address-100<=ins[0]<=address+200:print(hex(ins[0]),ins[2],ins[3])
