"""Preserve the physical port in a same-port HID reinsertion test.

The caller must place the initial keyboard on xhci.0 port 1 and pointer on
port 2, reserving those ports from storage devices. Auto attachment can
choose a different free port after removal. This helper assigns no PASS.
"""
PORTS={'coveragekbd':'1','coveragepointer':'2'}

def pin(descriptor):
    result=dict(descriptor)
    identifier=result.get('id')
    if identifier not in PORTS or result.get('bus')!='xhci.0':
        raise ValueError('Only the two owned root HID devices may use reserved ports')
    expected='usb-kbd' if identifier=='coveragekbd' else None
    if (expected and result.get('driver')!=expected) or (not expected and result.get('driver') not in ('usb-mouse','usb-tablet')):
        raise ValueError('Unexpected HID driver')
    if result.get('port',PORTS[identifier])!=PORTS[identifier]:
        raise ValueError('Conflicting explicit HID port')
    result['port']=PORTS[identifier]
    return result
