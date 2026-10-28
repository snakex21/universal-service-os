# NT 3.51: USB HID with the corrected NIC IRQ — QEMU only

R27 cold-boots a new overlay of completed R26. No guest driver, hive,
hardware, cache or hub source was changed. Installed own network SYS is
`f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf`,
17,024 bytes. Hardware i8042 is present; the inherited i8042prt service
is Start4, as verified for the unchanged R26/R18f SYSTEM.

The actual Program Manager session passed these manual checks:

- Keyboard removed: Alt-F does not open the menu (operator06).
- Keyboard inserted: Alt-F opens File (operator08).
- Mouse removed: keyboard Esc/Alt-F still closes/opens File (09/10).
- Absent mouse movement/click does not move the pointer (11).
- Mouse inserted: pointer moves to the origin (13), then movement and
  left click open File (15). The first click in14 landed in Main because
  of pointer acceleration; that frame remains, and15 supplies menu proof.

Native Shutdown reaches the safe-to-turn-off screen (17), before explicit
QMP quit and process rc0. The baseline backing chain remains unchanged.
Post-exit readonly collection verifies the exact installed f579 SYS and
recovers five own texts. The normal 2048 MiB plus 8 GiB reserve guard ran.

Manual assessment and hashes of completed per-action frames are in
`artifacts/nt351-irq-r27/evaluation.json`; preparation/collector/assessment
scripts remain alongside it. Completed command, actions, frames and
result are in `macierz-windows/artifacts/coverage/vm/r27-nt351-irq-hid-regression/`.
The retained preflight's generic scope label still names an IRQ snapshot;
the actual command/actions and assessment explicitly identify this HID run.

This qualifies HID replug with the corrected installed network driver.
The passive R27 network capture is not a new LAN qualification; R26 is
the separate LAN evidence. The runner's generic installed_runtime_pass
remains false. No fresh installer/cache, MSC, Server or X470 result is
inferred. No physical media, Microsoft module or USB hub code was changed.
