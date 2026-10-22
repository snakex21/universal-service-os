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
- Canonical IRQ driver89b and frozen MSC313952 are separate tests; no
  result is granted to them by this desktop/HID/network evidence.

No Server, other source/SP, fresh AUTO combined USB/network, full hardware
or X470 qualification is inferred. Microsoft modules/hives stay in RAM or
whole-disk private fixtures; no physical media is changed or branch merged.
