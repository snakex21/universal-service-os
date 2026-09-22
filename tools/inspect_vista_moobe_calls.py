from pathlib import Path
import pefile,capstone,struct
data=Path('M:/Windows/System32/WinSAT.exe').read_bytes();pe=pefile.PE(data=data);base=pe.OPTIONAL_HEADER.ImageBase
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64)
funcs=[(base+e.struct.BeginAddress,base+e.struct.EndAddress) for e in pe.DIRECTORY_ENTRY_EXCEPTION]
for start,end in funcs:
 if start==0x10009857c:
  for ins in md.disasm(pe.get_data(start-base,end-start),start):print(hex(ins.address),ins.mnemonic,ins.op_str)
 if start==0x1000999d8:
  instructions=list(md.disasm(pe.get_data(start-base,end-start),start));indices=set()
  for i,ins in enumerate(instructions):
   if any(s in ins.op_str for s in ['edi','r12b']):indices.update(range(max(0,i-3),min(len(instructions),i+9)))
  for i in sorted(indices):
   ins=instructions[i];print(hex(ins.address),ins.mnemonic,ins.op_str)
for sec in pe.sections:
 if not sec.Characteristics&0x20000000:continue
 code=sec.get_data();at=0
 while True:
  at=code.find(b'\xe8',at)
  if at<0 or at+5>len(code):break
  address=base+sec.VirtualAddress+at;target=address+5+struct.unpack_from('<i',code,at+1)[0];at+=1
  if target!=0x10009836c:continue
  print('CALL',hex(address))
  for start,end in funcs:
   if start<=address<end:
    print('FUNCTION',hex(start),hex(end))
    for ins in md.disasm(pe.get_data(start-base,end-start),start):
     if address-40<=ins.address<=address+160:print(hex(ins.address),ins.mnemonic,ins.op_str)
