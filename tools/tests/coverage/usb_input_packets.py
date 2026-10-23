"""Pure decoder for completed QEMU USBmon PCAP reports. No guest PASS here."""
import re
import struct

def completed_interrupt_reports(data):
    if len(data)<24:raise ValueError('Truncated PCAP header')
    endian={b'\xd4\xc3\xb2\xa1':'<',b'\xa1\xb2\xc3\xd4':'>',
            b'\x4d\x3c\xb2\xa1':'<',b'\xa1\xb2\x3c\x4d':'>'}.get(data[:4])
    if endian is None:raise ValueError('Unsupported PCAP magic')
    major,minor,_,_,snaplen,link=struct.unpack_from(endian+'HHIIII',data,4)
    if (major,minor)!=(2,4) or link!=220 or snaplen<64:
        raise ValueError('Expected USBmon 64-byte PCAP linktype220')
    at=24;reports=[];count=0
    while at<len(data):
        if at+16>len(data):raise ValueError('Truncated record header')
        _,_,size,_=struct.unpack_from(endian+'IIII',data,at);at+=16;count+=1
        if count>1000000 or size<64 or size>snaplen or at+size>len(data):
            raise ValueError('Invalid/truncated USB record')
        packet=data[at:at+size];at+=size
        status,length,captured=struct.unpack_from(endian+'iII',packet,28)
        if captured<64 or captured>len(packet):raise ValueError('Invalid USB capture length')
        if packet[8]==ord('C') and packet[9]==1 and packet[10]&0x80 and status==0:
            report=packet[64:captured]
            if len(report)>length:raise ValueError('Report exceeds completed transfer length')
            reports.append(report)
    return reports

def key_presses(reports):
    previous=set();pressed=[]
    for report in reports:
        if len(report)!=8:continue
        current=set(report[2:])-{0}
        if current & {1,2,3}:raise ValueError('Keyboard rollover/error report')
        for usage in report[2:]:
            if usage and usage not in previous:
                pressed.append(usage);previous.add(usage)
        previous=current
    return pressed

def public_token_seen(reports,token):
    if not re.fullmatch(r'USB[A-Z0-9]{1,24}',token):
        raise ValueError('Only an explicit public USB challenge token is accepted')
    expected=[ord(c)-ord('A')+4 if c.isalpha() else 39 if c=='0' else 29+int(c) for c in token]
    observed=key_presses(reports)
    return any(observed[start:start+len(expected)]==expected for start in range(len(observed)))

def mouse_facts(reports):
    movement=0;down=0;up=0;was_down=False;valid=0
    for report in reports:
        if len(report) not in (3,4):continue
        valid+=1;dx,dy=struct.unpack_from('bb',report,1)
        movement+=bool(dx or dy)
        is_down=bool(report[0]&1)
        down+=is_down and not was_down;up+=was_down and not is_down
        was_down=is_down
    return dict(completed_reports=valid,movement_reports=movement,left_down=down,left_up=up)
