# NT4 Workstation PL: completed normal USOS installation — QEMU only

The exact502075392-byte source ISO is
`Windows NT 4.0\Windows NT 4.0 Workstation PL.iso`, SHA256
`7aae3d7c36619c4edab58c8dccf9d350c78639f88afa36ae6b21e2e9cee9611b`.
Candidate03 uses the normal OVMF/USOS/micro-Linux/CSMWrap setup flow,
the selected private answer profile and separate original SP6a input.
No key or account-file contents are exported as evidence.

The native Polish desktop is reviewed on completed operator02. Native
safe shutdown09 and QMP exit0 precede stopped retained-target validation.
The original result remains ASSESS_ENDPOINT, with no error; its missing
first-logon token and false network flags are not rewritten. The desktop
assessment is an explicit visual review, not a network-gate override.
Evidence: `artifacts/coverage/nt4-runtime-candidate03/desktop-review.json`
and `desktop-matrix-update.json`. All66 previous results remain unchanged;
one exact-source desktop record raises reviewed desktop rows from12 to13.

The stopped retained target hash is
`cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21`.
The original short NTFS hardlink directory-entry length was stale;
read-only opening and qemu-img confirm the full460390400-byte image.
The earlier keyless harness failure and candidate02 Setup failure remain
historical results. Sourcefix a4313b36/3863468b changes the temporary
Setup IP from192.0.2.1, rejected by original TCPCFG, to198.51.100.1.
Fullbuild03 still fails on unrelated missing Win7 assets despite589/589
host tests; the trial explicitly uses the completed own EFI graph output
d96cc2a0…ad77 with unchanged frozen initrd and other290 cache files.

Later qualification stays separate from the fresh desktop record:

- HID01, fix/nt4-usb0c53a3ed: keyboard/mouse out/in, i8042prtStart4,
  USB2d455, native safe shutdown12/exit0 and stopped readback PASS.
  This is a BIOS cold overlay, distinct from the original warm handoff.
- Network05 versus unchanged06 uses matched cold hardware/firmware and
  the same03 parent. NDISLoopStart2 gives DHCP/ping4/4; Start3 gives no
  adapter. Sourcefix f00b1597 changes takeover to automatic start.
- Network07 qualifies the new hidden helper, global DHCP DNS fallback,
  actual logon token, TESTNET_DONE and matched DHCP/ICMP/DNS traffic using
  the old4f2 SYS. Winver/operator09 confirms Build1381/Service Pack6 and
  the separate Service Pack6a label. Native safe12/QMP0 and strict
  readonly collection complete the separate LAN qualification.
- Network08 changes only the own SYS to canonical89b/21248 B. Native
  DHCP/ping4/4 below10ms, a fresh own log, actual token/TESTNET_DONE,
  DHCP DORA/ICMP and strict configuredDNS qualify LAN independently.
  Native safe16/QMP0 and stopped readback precede successful readonly
  collection08b. The first collector's literal old-size refusal remains
  historical; the narrow generated guest guard now pins21248 and89b.
  Source/evidence commits a2c12add/1e60b91c; usability evidence [S18].
  Passive114IMS/57INTx/57assertedC0 clears are recorded separately;
  full hardware IRQ route remains unqualified, automaticfalse retained.
- Frozen MSC313952/43648 B passes separate MSC04 startup/hotplug,
  Write/Flush/Close/read and persisted reinsert (62073133/[S17]).
  A new Explorer window is needed to enumerate changed drives; automatic
  Explorer refresh does not have PASS.
- Combo01 (6457ab4b/[S19]) qualifies keyboard/mouse negative/out/in,
  movement/click and all the above storage operations on the **same**
  frozen313952. Native safe25/QMP0, actual payload and persisted bytes
  confirmed by stopped readback, both parents unchanged. i8042prtStart4;
  NDISLoopStart3, therefore this USB test does not grant a LAN result.
  Final target SHA256:
  `dc757988b9634acaa03c5a4cb90d64e268c7109e62bdd88ea73b52cd8d0493fa`.
  Completed evidence: `nt4-usb-hid/artifacts/nt4-combo/evaluation.json`.

Completed coexistence09 now has its own **basic LAN+HID+MSC PASS** in one
installed BIOS/q35/AHCI/igb VM. Actual frozenUSB313952/43648B and NET89b/21248B
were read back; i8042prt Start4, NDISLoop/Workstation Start2, Server/Browser
Start4. Negative keyboard/mouse removal controls, typing/movement/click after
reinsertion, all three MSC stages and persisted ROUNDTRIP are native proofs.
The final native ping after all USB operations replies4/4 (16ms then three
<10ms). Native safe-off36, QMP exit0 and stopped readback precede the strict
readonly collector30.970s PASS. Actual first-logon/TESTNET_DONE, matched DORA,
gateway and configuredDNS10.0.2.3:53/id706F/questionfrogfind all pass.

Root independently reviewed native operator31 (persisted file) and33 (ping),
then cross-checked the frozen payload pins, exact three MSC status0 values,
strict collection flags and unchanged parent08. Completed target SHA256:
`6c4e80a34c20544c314cb3ad88a0e0222320bd0550351d2f4fbc7f3c95e35743`.
Own evaluation JSON:
`nt4-net/artifacts/nt4-success-review/candidate09-tuple-evaluation.json`,
SHA256 `3792ae307bd09cf87751b24d5618e4a16e7f90a97e82e1b1dda49ae5c9ef1a64`.
Strict collection:
`artifacts/coverage/nt4-installed09-network-excerpt/collection.json`,
SHA256 `c6f8e11b6e8c0a4686b05382fdc859fe612e6201687f3e714e1c874d33ae7d59`.

The new Explorer right pane enumerates actual drives after removal/reinsert,
but its left tree can retain stale E:. Automatic refresh remains unqualified.
HTTP/browser, full IRQ route, complete fresh AUTO and X470 are not granted
PASS by this basic coexistence test. Historical raw generic false fields
are preserved; the own evaluation is an explicit separate qualification.

No Server, other source/SP, fresh AUTO combined USB/network, full hardware
or X470 qualification is inferred. Microsoft modules/hives stay in RAM or
whole-disk private fixtures; no physical media is changed or branch merged.
