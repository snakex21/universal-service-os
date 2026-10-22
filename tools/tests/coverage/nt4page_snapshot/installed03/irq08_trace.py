"""Passive bounded IRQ evidence; NIC's actual PCI IRQ is selected once at endpoint.

No MMIO/register/DMA reads are issued. PIC/PIT boot spam is drained before
the one selected PCI metadata boundary. Only public IRQ event lines remain.
"""
import json,re
EVENTS=('e1000e_irq_legacy_notify','e1000e_irq_set','e1000e_irq_clear','e1000e_irq_ims_clear_set_imc','e1000e_irq_icr_clear_nonmsix_icr_read','e1000e_irq_pending_interrupts','pic_set_irq','pic_interrupt','pic_ioport_write')
MAX_BYTES=512*1024
def selected_pci_irq(reply):
 found=[];visited=0
 def walk(value,depth=0):
  nonlocal visited
  visited+=1
  if visited>4096 or depth>16:raise ValueError('Bounded PCI metadata exceeded')
  if isinstance(value,list):
   if len(value)>256:raise ValueError('PCI list bound')
   for child in value:walk(child,depth+1)
  elif isinstance(value,dict):
   ident=value.get('id')
   if isinstance(ident,dict) and ident.get('vendor')==0x8086 and ident.get('device')==0x10c9:
    item={k:value.get(k) for k in ('bus','slot','function','irq','irq_pin')}
    if any(type(v)!=int for v in item.values()) or not 1<=item['irq']<=15 or not 1<=item['irq_pin']<=4 or not 0<=item['slot']<=31 or not 0<=item['function']<=7:raise ValueError('Actual NIC PCI IRQ unavailable')
    found.append(item)
   for k,v in value.items():
    if isinstance(v,(dict,list)):walk(v,depth+1)
 walk(reply)
 if len(found)!=1:raise ValueError('Pinned82576 must be unique')
 return found[0]
class Filter:
 def __init__(self):self.irq=None;self.bytes=0;self.dropped=0;self.before_pci_dropped=0
 def select(self,reply):
  if self.irq is not None:raise ValueError('Only one PCI boundary read')
  item=selected_pci_irq(reply);self.irq=item['irq'];return item
 def event(self,line,now):
  if type(line)!=str or len(line)>2048 or any(ord(c)<32 or ord(c)>126 for c in line):self.dropped+=1;return None
  name=line.split(' ',1)[0]
  if name not in EVENTS and name!='OWN_ACTUAL_FIRST_LOGON_BOUNDARY':return None
  if name.startswith('pic_'):
   if self.irq is None:self.before_pci_dropped+=1;return None
   if name=='pic_set_irq' and not re.search(r' master '+str(0 if self.irq>=8 else 1)+r' irq '+str(self.irq%8)+r' level [01]$',line):return None
   if name=='pic_interrupt' and not re.search(r' irq '+str(self.irq)+r' intno [0-9]+$',line):return None
   if name=='pic_ioport_write' and ' master '+str(0 if self.irq>=8 else 1)+' ' not in line:return None
  encoded=json.dumps({'monotonic_ns':now,'line':line},separators=(',',':'))+'\n'
  if self.bytes+len(encoded.encode('ascii'))>MAX_BYTES:self.dropped+=1;return None
  self.bytes+=len(encoded);return encoded
def assess(records,irq,dropped=0,error=None):
 boundary=next((x['monotonic_ns'] for x in records if x['line']=='OWN_ACTUAL_FIRST_LOGON_BOUNDARY'),None)
 counters={'canonical_ims_writes':0,'intx_assertions':0,'pic_nic_interrupts':0,'native_icr_reads':0}
 if boundary is not None and type(irq)==int and 1<=irq<=15:
  for x in records:
   if x['monotonic_ns']<=boundary:continue
   line=x['line']
   if line.startswith('e1000e_irq_set ') and 'register 0xd0:' in line.lower():counters['canonical_ims_writes']+=1
   if line=='e1000e_irq_legacy_notify IRQ line state: 1':counters['intx_assertions']+=1
   if re.fullmatch(r'pic_interrupt irq '+str(irq)+r' intno [0-9]+',line):counters['pic_nic_interrupts']+=1
   if line.startswith('e1000e_irq_icr_clear_nonmsix_icr_read '):counters['native_icr_reads']+=1
 return {'scope':'Passive public IRQ events after actual first-logon boundary, no guest MMIO read','pci_irq':irq,'after_first_logon':counters,'trace_dropped':dropped,'error':error,'irq_delivery_observed':boundary is not None and not dropped and not error and all(counters.values())}
