"""One explicit installed07 qualification pin set; original strict NT4 policy.

Only the two own EXE pins change. Paths, guest sanitizer, host grammar,
actual first-logon boundary, TESTNET_DONE and matched DHCP/DNS gates remain
the original collector's. No historic assessment is reinterpreted.
"""
from pathlib import Path
import importlib.util
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
LOGGER='fe4ffa555e1cc837185156e7b76639d86b14580150663fd310c35ce3807c94c2'
OBSERVER='82279b889053a68f42f18fdaeb0a1c0b5a76a00ce21e2685bedb9cb18dc38284'
def collector():
 path=MATRIX/'tools/tests/coverage/collect_nt4_success.py'
 s=importlib.util.spec_from_file_location('own_nt4_network07_strict_policy',path);c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
 if c.LOGGER_SHA256!='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7' or c.OBSERVER_HELPER_SHA256!='37e7a0f69846d9bab18a718f7d66c3fd937f0f35913d2b0eb22f2d7ce4eae0e9':raise ValueError('Unexpected original collector pin contract')
 if c.DRIVER_SHA256!='4f2eb16b71753baab740302025b9e8ba02c38a676670b13626c757bdb3700f8d' or c.DRIVER_BYTES!=21376:raise ValueError('07 must keep the old runtime driver')
 c.LOGGER_SHA256=LOGGER;c.OBSERVER_HELPER_SHA256=OBSERVER
 return c
