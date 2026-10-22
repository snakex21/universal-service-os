# Stopped NT3.1/3.5 hive diagnostics

`tools/tests/coverage/regf11.py` is an in-memory REGF **1.1-only** helper
for owned, stopped test disk images. The caller must inspect the actual
hive header: an OS version does not establish its hive format. Existing
modern `xp_hive.py` behavior is unchanged.

REGF1.1 cell payloads include an additional four-byte prefix. The reader
indexes allocated cells within validated hive bins before following any
reference, bounds file size/tree depth/counts, rejects cycles and duplicate
paths, and requires clean sequence numbers and a correct header checksum.
It handles old `li` lists, inline and external values, including zero-length
values without dereferencing their absent data. Its only edit operation
replaces an existing expected DWORD; a fresh parse must differ in exactly
that value, and all bytes outside its four-byte location must remain equal.
It never calls host registry APIs or writes files itself.

The layout reference is the public [libregf format specification](https://github.com/libyal/libregf/blob/main/documentation/Windows%20NT%20Registry%20File%20(REGF)%20format.asciidoc),
sections for version1.1 named keys, values, lists and data cells. Eight
synthetic tests pass, covering both storage forms and malformed input.

Actual stopped readback: normal USOS case `r19-nt31-desktop-ps2` completed
installation to Program Manager Version3.1 and native safe shutdown, then
QMP quit/return code0. Its SYSTEM is REGF1.1, current/default controlset1.
The source image SHA256 remained
`606806fb88568b3b11debec29741f146f25307db19b13ef0feb883ba2b7d4e3a`.
The installed own USB driver is32256bytes, SHA256
`f5373eb3bf829d585651bc0da7ea5b1ca9b0cf2b20a1fe74ccb5054955f3ef05`,
identical to the frozen `f28a3fd8155b82dd1be22608f6ef17e82437ad1d`
NT31 binary. USB Start0, i8042prt Start1, both class services Start1;
both classes have ConnectMultiplePorts1 and MaximumPortsServiced3.
Only selected service metadata, hashes and our own POST/DONE/SOURCE text
were exported. Hive and system module bytes stayed in RAM or whole disk
scratch on owned G; scratch was removed after the operation.

Separate R19c preparation changes only the existing i8042prt Start DWORD
from1 to4 at SYSTEM file offset96064. Full hive content/byte checks and
`qemu-img compare` against its new overlay pass; own USB SYS and baseline
remain unchanged. Hardware i8042 remains available for NTDETECT. This
preparation and the PS/2 R19 desktop do **not** establish USB runtime PASS.
No merge, push or physical media deployment was performed.

Local evidence:
`artifacts/coverage/nt31-runtime-r19/{desktop-evaluation,stopped-readback,usb-preparation}.json`.
HID removal/reinsertion belongs to the separate R19c runtime assessment.
