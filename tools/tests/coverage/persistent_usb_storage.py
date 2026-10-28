"""Explicit block nodes survive deletion of a disposable USB frontend.

Legacy -drive if=none backends may be auto-deleted with usb-storage. Named
-blockdev nodes are owned by the monitor and remain available for replug.
This helper constructs only the two image files inside the selected case.
It never assigns a guest USB PASS.
"""
from pathlib import Path
import json

STICKS=(('usabilityboot','usb-test-boot.qcow2'),('usabilityhot','usb-test-hot.qcow2'))

def block_arguments(case):
    case=Path(case).resolve()
    arguments=[]
    for name,leaf in STICKS:
        image=case/leaf
        if not image.is_file():raise FileNotFoundError(image)
        node={'driver':'qcow2','node-name':name,'read-only':False,
              'file':{'driver':'file','filename':image.as_posix()}}
        arguments.extend(('-blockdev',json.dumps(node,separators=(',',':'))))
    return arguments
