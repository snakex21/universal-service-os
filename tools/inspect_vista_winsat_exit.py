from pathlib import Path
import pefile, capstone
p=pefile.PE('M:/Windows/System32/WinSAT.exe'); base=p.OPTIONAL_HEADER.ImageBase
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64)
start,end=0x1000999d8,0x10009ce02
for i in md.disasm(p.get_data(start-base,end-start),start):
 if 0x100099c70<=i.address<=0x100099ce0: print(hex(i.address),i.mnemonic,i.op_str)
