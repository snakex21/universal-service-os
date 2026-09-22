"""Read-only guard for the identified Intel Vista boot hook."""
from pathlib import Path
import sys,uuid
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
h=Registry.Registry('M:/Windows/System32/config/SYSTEM')
assert h.open('MountedDevices').value('\\DosDevices\\D:').value()==b'DMIO:ID:'+uuid.UUID('73dbde99-8026-4759-a19a-fd943e891d09').bytes_le
s=h.open('Setup')
assert s.value('CmdLine').value()=='D:\\USOS\\usb.exe'
assert s.value('SetupType').value()==2 and s.value('SystemSetupInProgress').value()==1
assert s.value('SetupPhase').value()==4
assert h.open('Setup\\Status\\ChildCompletion').value('setup.exe').value()==0
print('VISTA_USB_GATE_ARMED; target D: mapping verified; no registry writes')
