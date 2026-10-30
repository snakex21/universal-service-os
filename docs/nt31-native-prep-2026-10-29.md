<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# NT 3.1 native preparation, 2026-10-29

Base `claude/nt-native` at `2d7f2a238b5c663f083f8e5285c75adfc36689ac`.
This delivers tested preparation components, **not a complete native NT31
installation**. Native routing stays disabled. No QEMU installation, physical
disk access, merge, push or deployment in this round.

## Seven-point audit

| Area | Established result | Delivered / remaining |
|---|---|---|
| 1. Compression | Original WS and Advanced Server INF files use SZDD A, not CAB/MSZIP. Own decoder agrees with 7-Zip; six patched INF copies also decode identically with 7-Zip. | Bounded 16 MiB SZDD reader and literal writer; original CD untouched. NT351 fixed-Huffman CAB writer is not the NT31 writer. |
| 2. RAM | Existing native plan uses 64 MiB. Hook byte 508=4. Original SETUPLDR contains AH88/E801 instruction sequences; NTLDR._ decoded contains MAXMEM but no NUMPROC. | Actual resident code emulated for AH88, E801 and E820 caps. Presence of MAXMEM string alone is not a complete installed-loader runtime proof; no claim that text Setup obeys answer-file MAXMEM. |
| 3. E820/video/century | Common hook clips RAM, reserves only F0000–FFFFF in the VGA hole and conditionally copies CMOS 32h→37h. NT4 sources explain descriptor and century mechanisms. | No exact NT31 source tree in the provided materials; do not identify an NT31 HAL binary implementation from NT4 source alone. NT31's original text loader legacy-sizing evidence is stronger than an assumption that it consumes E820. No new reproduction of Video0 STOP on NT31. |
| 4. Text and GUI responder | Text setup is SETUPAPP in the BIOS loader, before an NT driver could inject input. Policy covers Welcome/express/partition/FAT/path/restart with exact page conditions and bounds. GUI rules use actual original MAIN.CPL/NCPA.CPL controls. | Policy tested in compiled C; **resident INT16 injection still missing**. GUI candidate handles Date/Time and AS new domain, with profile config, only recognized windows. No NT31 GUI runtime PASS. |
| 5. Network | NT31 is an NDIS 3.0 full MAC, not an NDIS miniport. Existing driver is Intel82576/10C9, UP only, explicit CF8 BDF and NdisMapIoSpace. Original kernel exports ZwFlushKey and MmMapIoSpace. | Separate candidate adds durable initialization and 1/2/5/10 s breadcrumbs at PASSIVE_LEVEL, serialized by mutex. All imports match original NT31. **No I211/1539 support or general PCI enumeration**, no silent direct mapping/resource bypass. NT31 stock TCP/IP is static; DHCP is not promised. |
| 6. USB | Existing `build-nt31.cmd` targets PE3.10 and legacy kernel/HAL exports. Existing NT31 SYS imports match original CD. Own NT31 INF patch selects Start=0 (Keyboard Port), unlike NT35/NT4 Start=1. | INF registration is late GUI Setup; earlier GUI HID is not established. The old build script's destructive workdir preparation was not invoked. No USB source/binary changes. |
| 7. BOOT.INI / usosnt3 | Generic helper builds as PE3.10 with imports present on NT31; `/polish` remains usable in principle. Generic `/finish` assumes Start=1 and NUMPROC-based idempotence absent in NT31 NTLDR. | Added explicit NT31 refusal **before logging/USB mutation** for `/finish`; full NT31-specific finish is not implemented. Use future `/NODEBUG /MAXMEM=64` route, not copied NUMPROC assumptions. |

## Source preparation and safety

`tools/nt31_native_source.py` accepts a compressed or plain INF and writes a
new, separate output only. Original input and existing destination are never
overwritten. Existing USOS NT31 INF transformation functions are reused;
Advanced Server selection must match original `STF_PRODUCT=LanmanNT`.
Profile text rejects controls, quotes and shell-expansion characters.
For AS, patch INITIAL/HARDWARE/NTLANMAN/OEMNADLB before boot; WS uses the
first two. Metadata of both original media and each tested patched output is
in the local audit, without those Microsoft files in outputs or git.

`--gui-answerer` optionally inserts startup after the single verified
LoadSetupLibrary anchor. Independently stage own USOSANS31.EXE under
`C:\USOS\NT3` in a future native installer. Its optional NATIVE31.INI resides
beside it, `[native] domain=USOSDOMAIN` (or a configured uppercase 1–15
character name). Date/Time preserves the date and selected zone and clicks
OK only for valid year 1990–2099. AS selects the recognized new-domain radio
and checks it before filling its name. Unknown dialogs are recorded, never
answered. No edit text/product key is recorded. Limits: 30 s between repeated
actions, 6 h lifetime, 1 MiB log. Other editions/languages need measured rules.

The text policy alone does not send keys. A resident INT16 hook with
preserved vectors/registers, BIOS concurrency and cleanup must be designed
before enabling native NT31. Installing an NT boot driver cannot solve input
required before the NT kernel exists. Keep the production route closed.

## Network diagnostics and isolation

DriverEntry RegistryPath + `Parameters\NativeDiag` records Stage/Status/
Value/Sequence; no hardcoded NDIS wrapper memory offsets. Points 1/2:
DriverEntry/RegisterMac; 3: AddAdapter/CPU count; 4: validated explicit BDF;
5: map status/address; 6: reset; 7: started/ring; 0x1F: failure; 0x20: alive
RX/timer counts. Polling thread writes after KeLowerIrql and outside its
NDIS spin lock. Presence of an export is import compatibility, not proof that
I211 mapping or delivery works. UP/82576 restrictions are retained.

Protected `usosnet351n.sys` stays byte-identical to base, SHA-256
`e52edc18170249741f0490f17c085cff4eee5f2269a4b7263dca9d43baaed095`.
No NT351 net sources/build351/INF/registry/network tests were changed or
rebuilt. Shared source code in this branch has no network change; only the
separate src31 candidate is built. Original shared Win95/NT4 SYS unchanged.

## Tests and provenance

Build through `build.bat` with `USOS_NT31_NATIVE_PREP=1`, explicit WDK/Zig
paths, fresh own artifacts output and original-media export metadata. Eleven
Python contracts pass; sixteen compiled C page/GUI policy cases pass. Eight
source checks (four INF per original medium) agree with 7-Zip, and six
actually transformed copies agree after decoding. NT31 GUI, network, USB
and generic helper imports match original CD exports. The hook is executed
in Unicorn (4 legacy sizing cases and 20 E820/video cases), **not QEMU**.
Original dialog IDs are independently parsed from both supplied CD images.

Own implementation; compression mechanism inferred from local NT5 XP SP1
`base/win32/lz32/winlza/{lzexp.c,lz_header.h,lzcommon.h,lzcommon.c}` under
`doors/Microsoft source code/nt5src/Source/XPSP1/NT`. NT4 boot/HAL context:
`private/ntos/boot/startup/i386/{su.asm,eisac.c}`,
`private/ntos/boot/lib/i386/memory.c`,
`private/ntos/boot/bldr/i386/parsboot.c`,
`private/ntos/nthals/halx86/i386/ixcmos.asm` and MPS include.
NT4 `private/ntos/ndis/ndis30/wrapper.c` is architecture context only;
actual NT31 export/ABI and dialog facts come from original media. No exact
NT31 source, no Internet, no Microsoft files added to git or outputs.

Before X470: implement native text input, I211 support/resource qualification
and NT31 finish, then stage the source copies/helper/Start0 registration in
one reviewed native route. Offline collect USOSANS.TXT beside answerer,
Setup/POST logs when created, BOOT.INI, SYSTEM hive NativeDiag, sector-2
E820; report yes/no for Setup, input, desktop, USB, static-IP HTTP, restart
and cold boot. Current code does not qualify those hardware results. STOP
after the preparation report.
