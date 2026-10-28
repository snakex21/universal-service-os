# NT4 combo01: same frozen313952 HID and MSC qualification [S19]

Completed **QEMU HID+MSC PASS on the same USOSUSB.SYS binary**. The result
binds to the exact NT4 Workstation PL/build4.0.1381.1/pl-PL x86/csmwrap row
identified by [S14]. It does not combine HID1.3 evidence with a different MSC
package. Sources and report are in `nt4-usb-hid`, branch `fix/nt4-usb`, commit
`6457ab4b`, following the separate MSC04 qualification `62073133` [S17].

This is an installed BIOS/q35/AHCI overlay, not a complete fresh USOS AUTO
flow. **i8042 hardware remains present, i8042prt Start4, NDISLoop Start3**.
LAN, combined LAN coexistence, fresh AUTO, Server and X470 receive no PASS
from this result. LAN08b [S18] retains its separate result and limitations.

## Actual HID and storage actions

| Completed action | Native proof |
|---|---|
| USB keyboard baseline | operator03: Run field contains `nt4combo` |
| Keyboard removal, negative AB input | operator04: field remains `nt4combo`; AB absent |
| Same keyboard reinserted, actual CD input | operator05/06: `nt4combocd` |
| Mouse removed, live USB keyboard, negative motion | operator07: ` mouseout` appended; rel100/100 leaves cursor unchanged |
| Same relative mouse reinserted, actual movement/click | operator08/09/10: movement then left click opens Start |
| Startup FAT16 medium | STARTUP11:0; native Notepad12 displays START.TXT payload |
| Desktop hotplug and write/read | HOT14:0; new Explorer14 shows D:/E:; native Notepad15/16 displays HOTPLUG/ROUNDTRIP |
| Removal after closing Notepad17 | DEVICE_DELETED18; unobscured new Explorer19 shows D: without E: |
| Same backend/serial/port reinserted | REPLUG21:0; new Explorer21 shows E: again; native Notepad22 displays persisted ROUNDTRIP |
| Mouse remains live after MSC replug | actual left click23 opens Start |
| Safe completion | native Shutdown24, safe-off25, TTY98310 closed exit0/QMP quit |

Topology on xhci.0: startup MSC port1, hot MSC port2, keyboard port3, relative
mouse port4. The hot medium uses the persistent named block backend from
`d62eb0c6`; only the USB device is removed/reinserted. Both own media are
64MiB, MBR type06/FAT16 with matching BPB/root labels and private markers.
They begin with the same initial pins as MSC04: boot cabf0e03…1a28,
hot29760ec7…e44c. No physical USB access occurs.

The quiet GUI observer discovers one uniquely labelled/marked FAT volume,
performs one explicit stage and writes its log beside the EXE. It uses
WriteFile, successful FlushFileBuffers and CloseHandle, then a new read.
REPLUG reads without rewriting the file. Each exact COM1 completion is a
new armed future; no volume-wait or progress loop. The old MSC04 log prefix
is preserved, and only the new three-stage tail qualifies combo01.

## Preparation and stopped readback

The closed MSC04 target is the COW parent. The only preboot target delta is
one existing SYSTEM DWORD: i8042prt Start1→4, hive offset143284,
raw offset351415732. Restoring that DWORD makes the entire raw identical
to the parent; modified raw/COW compare also passes. Independent readback
confirms the full SYSTEM delta and identical contents of 2056 other files,
including the same own SYS/helper/marker/log. No new target files were added.

Stopped readback confirms Select Current/Default1, i8042prt Start4,
usosusb/kbdclass/mouclass Start1, NDISLoop Start3. Actual installed imports
resolve against original modules read only in RAM: 38 for USB,14 for the
observer. Runtime Windows registry changes are expected; the one-DWORD
binary comparison applies before boot. Both parents remain unchanged.
Own whole-disk scratch was removed from exact owned G paths; no standalone
MS hive/module, private answer/key or Setup frame was exported.

| Pin | SHA256 |
|---|---|
| USOSUSB.SYS,43648B | `3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1` |
| Quiet MSC4TEST.EXE,5120B | `75cef5e2e8be39b1cdc3d52a0f414464a86cd85fb0513de1139133fc3ac6429e` |
| Completed combo01 target | `dc757988b9634acaa03c5a4cb90d64e268c7109e62bdd88ea73b52cd8d0493fa` |
| Unchanged MSC04 parent | `a6807a432891b47ea20a4eb1650fc981ae8b7fdade6cec138d9ef03818b1de5c` |
| Unchanged original candidate03 ancestor | `cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21` |
| Persisted ROUNDTRIP bytes | `003fd2202119eff8ac1e0e241942c8a9ce4ad2465f57339143e3557eb84efe15` |
| Evaluation JSON | `6f62966a186768d892bee8266e7c000ca9779e18fc60f813a1e3e407e4c9c8c1` |
| Preparation JSON | `feb754b23a8ba4fc5b6d5b5905330d8bbdcba9808fffedf4fbc8c3dd6631eb99` |
| Stopped readback JSON | `e215e3772da2de0dcf52357b46d4288bb4625449029073edd8978e1689902d71` |
| New own three-stage log tail | `0a9f495480f5e7b0964878b5537bf65671802d90ec9f7bd4e9c5a89d3894ccb4` |
| Runtime result JSON | `f4858b0863cbc0dec4c70a3011acbe1dc4bf6bcd68f66da629469783d4ebadd1` |
| Actual command JSON | `312a07313e4643cf65aa4be7a5af8bb3964a9232b639ce010c165c26807c778b` |

Metadata lives under
`C:\Users\ASRock\usos-work\nt4-usb-hid\artifacts\nt4-combo`;
native frames, command/result/completed and exact stage completions under
`C:\Users\ASRock\usos-work\nt4-usb-hid\artifacts\coverage\vm\nt4-installed03-usb-combo01`.
Evaluation pins 19 selected native frames. Detailed source/report:
`nt4-usb-hid/docs/nt4-usb-combined-qualification.md`.

The matrix update verifies all19 frame pins and five evaluation metadata
pins. Regeneration from MAIN SHA256
`9d8d4d1a7b02a4e84fcb6c9c75f4afef91a218b4f0a0550121ecff30b162cff9`
preserves96 inventory identities,95 other rows byte for byte and the NT4 LAN
cell byte for byte; only exact NT4 PL USB/HID cells change. Classification
suite15/15 and diff check pass. Local verification record:
`usability-usb-net/artifacts/usability-s19/validation.json`.

## Boundaries retained

Existing Explorer does not refresh automatically; a new window enumerates
actual letters. **Automatic Explorer refresh is not PASS**. WinM minimized
the Microsoft welcome window before operator19, without changing the driver.
Small FAT16 fixtures do not qualify other filesystems, large files, power
loss or physical topology. No driver/hub source or frozen SYS was edited or
rebuilt. A normal2GiB guard plus8GiB reserve and real PTY preceded the VM;
operator JSON stays within450 encoded bytes. Two operator contract tests
pass; all operation waits use exact future events/blocking completion.

S17 remains the separate MSC04/PS2-allowed Start1 history, including incomplete
MSC03 framing timeout. S14 remains the separate HID1.3/2d455 history. S19
adds same313952 HID+MSC proof only; it leaves S18 LAN/IRQ scope unchanged.
The separate final LAN+HID+MSC tuple requires its own completed evidence.
After integration/review, user questions T1/T2/T4/T5 and persisted-file replug
accept yes/no. Operator VM proof does not certify physical X470 use.

This evidence update runs no VM, performs no cleanup and changes no shared
root report, cache, SYS, physical medium, merge, push or deployment.
