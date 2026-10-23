"""Collect input transport evidence after verified key acceptance.

Keep i8042 available for the old kernel's initialization. A successful HID
test still requires guest-visible input, completed USB reports after replug,
and no PS2 input in the audited interval. This module never assigns PASS.
"""
from pathlib import Path
import json
import time

PS2_EVENTS=('ps2_keyboard_event','ps2_put_keycode','ps2_mouse_send_packet')
HID_IDS={'coveragekbd':'keyboard','coveragepointer':'mouse'}

class UsbInputAudit:
    def __init__(self,qmp,output,*,post_key_boundary=False,positive_control=False):
        if not post_key_boundary or not positive_control:
            raise ValueError('Verified post-key boundary and positive trace control required')
        self.qmp=qmp;self.output=Path(output)
        self.started=False;self.generations={kind:0 for kind in HID_IDS.values()}

    def __getattr__(self,name):
        return getattr(self.qmp,name)

    def record(self,kind,**values):
        with (self.output/'input-audit-events.jsonl').open('a',encoding='utf-8') as log:
            log.write(json.dumps(dict(kind=kind,host_time_ns=time.time_ns(),**values))+'\n')

    async def begin(self):
        if self.started:return
        # Actions, not state/progress queries. An unavailable trace is fatal.
        for event in PS2_EVENTS:
            await self.qmp.command('trace-event-set-state',
                {'name':event,'enable':True,'ignore-unavailable':False})
        self.started=True
        self.record('audit_begin',ps2_events=list(PS2_EVENTS),guest_input_pass=False)

    async def delete_device(self,device):
        if device in HID_IDS:await self.begin()
        result=await self.qmp.delete_device(device)
        if device in HID_IDS:self.record('hid_removed',device=HID_IDS[device])
        return result

    async def command(self,name,arguments=None):
        arguments=dict(arguments or {})
        device=HID_IDS.get(arguments.get('id')) if name=='device_add' else None
        if device:
            if not self.started:raise ValueError('Reinsert requires the audited removal first')
            generation=self.generations[device]+1
            capture=self.output/f'{device}-after-replug-{generation:02}.pcap'
            if capture.exists():raise FileExistsError('Refusing to overwrite input evidence')
            arguments['pcap']=str(capture.resolve())
        result=await self.qmp.command(name,arguments)
        if device:
            self.generations[device]=generation
            self.record('hid_reinserted',device=device,generation=generation,pcap=capture.name)
        return result
