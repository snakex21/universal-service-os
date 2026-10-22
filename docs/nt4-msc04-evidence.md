# NT4 MSC04: startup, hot-plug and persisted reinsert [S17]

QEMU only, for the exact NT4 Workstation PL media identified in [S14].
`fix/nt4-usb` commit `62073133` qualifies a separate installed BIOS/q35/AHCI
overlay of the completed candidate03. This is a completed storage test;
HID01 [S14] uses a different USB binary and remains a separate qualification.

## Actual storage results

- The FAT16/MBR startup medium appeared as D:; native Notepad opened
  START.TXT (operator05). The armed one-shot observer returned STARTUP:0.
- A second medium attached at the desktop appeared as E: in a new Explorer
  window. Native Notepad opened HOTPLUG.TXT (operator09); HOT:0.
- The own GUI observer performed WriteFile, FlushFileBuffers, successful
  CloseHandle and a new read. Native Notepad displayed ROUNDTRIP (operator10).
- After closing Notepad, removal completed through DEVICE_DELETED. A new
  Explorer window showed only D: (operator12).
- Reinserting the same named block backend/serial/port brought E: back
  (operator14). REPLUG:0 performs a read without rewriting the file; native
  Notepad displayed the persisted ROUNDTRIP (operator15).
- Native Shutdown16, safe-off17, QMP quit/exit0, error null. Independent
  stopped FAT readback confirms the persisted bytes and unchanged parent.

Both own fixtures are 64 MiB, MBR type06/FAT16, with verified BPB/root labels
and private volume markers. Letters are discovered once by the observer;
they are not assumed for writes. Logs are beside the EXE. Host execution
refuses the wrong OS. The named hot backend survives device removal.

## Exact payloads and proof pins

| Item | SHA256 |
|---|---|
| Frozen own USOSUSB.SYS, 43648 B | `3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1` |
| Own MSC4TEST.EXE, 5120 B | `75cef5e2e8be39b1cdc3d52a0f414464a86cd85fb0513de1139133fc3ac6429e` |
| Completed target | `a6807a432891b47ea20a4eb1650fc981ae8b7fdade6cec138d9ef03818b1de5c` |
| Persisted ROUNDTRIP bytes | `003fd2202119eff8ac1e0e241942c8a9ce4ad2465f57339143e3557eb84efe15` |
| Evaluation JSON | `dad5a4945a94f7331a35851eab8d4108a05135d928e7e1dbaca869f9785bf542` |
| Stopped readback JSON | `99c6c424fe3a700936b8a03100d4a7ca90a9860ad8053ba16190a2644ecef05e` |
| Runtime result JSON | `782b63e0867bc5dd8d3dda67225d1d6c140ef14d957d3ee376f6e06603d2b233` |

The JSONs and native frames are under
`nt4-usb-hid/artifacts/nt4-msc/` and
`nt4-usb-hid/artifacts/coverage/vm/nt4-installed03-usb-msc04/`.
Detailed source/report: `nt4-usb-hid/docs/nt4-usb-msc-qualification.md`.
An independent agent review checked all 16 proof/frame pins, actual observer
I/O ordering, frozen source/fixture and the stopped readback without a blocker
for this stated scope.

## Qualification boundaries

PS/2 was allowed: i8042prt Start1, USB/kbdclass/mouclass Start1, NDISLoop
Start3. Before boot, SYSTEM and 2051 other original files were byte-identical;
only the own USB SYS changed and two own observer files were added. The
original parent cf04 remained unchanged. Actual imports resolved: 38 for
USB, 14 for the observer. Driver/hub sources and the frozen SYS were not
edited or rebuilt. No standalone MS module/hive was exported.

Existing Explorer did not refresh automatically; a new window showed the
current drives. Automatic shell notification is **not PASS**. The small
FAT16 fixtures do not qualify large files, other filesystems, power loss,
hub topology, LAN, Winver, hardware or the complete fresh AUTO flow. HID on
this same frozen313952 is being checked separately in combo01.

MSC03 remains an incomplete historical attempt: startup read succeeded,
but an unterminated BIOS prefix caused strict COM framing rejection and
harness timeout, without native Shutdown. MSC04 fixes the own observer's
leading CRLF/COM flush; the parser's exact token gates remain unchanged.

After integration and review, hardware questions are T1 (startup read),
T2 (desktop attach/read), and: after removal/reinsertion, is the previously
saved file still readable? Each accepts yes/no. This document does not
authorize physical deployment.
