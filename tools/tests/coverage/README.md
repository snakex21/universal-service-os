# Media coverage helpers

Local research tools for `codex/macierz-windows`; not an installer release.
The matrix is an explicitly incomplete checkpoint until every required
installation and exact-image hardware binding has been assessed.

- `inventory.py`: SHA-256 of the Windows library and the allowed collection;
  prune scratch and macOS trees, reuse unchanged input hashes on the second pass.
- `media_probe.zig`: run production optical/identity parser APIs and export the
  real catalogue with `--catalog`. Its legacy API output is **not** evidence
  that the UEFI UI calls that parser; the UI currently chooses legacy entries
  from their catalogue folders. Actual UI results come from QEMU traces.
- `inspect_media.py`: bounded metadata and binary versions, archive member
  SHA-256; extract archives only into owned collection scratch and remove them.
- `driver_audit.py`: original NT5 prerequisite audit, reusing `pe`/`resolve`
  from `check_nt52_driver_imports.py`, including forwarder chains. It does not
  prove ABI/runtime compatibility or that source-bound XP edits can be applied
  to another SP. No Microsoft source tree is needed.
- `unpack_bytes.py`: the Windows 7-Zip build cannot seek CAB stdin; use a
  temporary owned G: input instead. Decompressed PE bytes stay in memory.
- `discover_downloads.py` / `download_media.py`: one-time Windows download plan,
  published whole-file hash validation, collection index; refuse replacement
  of existing media. The plan/report is written before transfer.
- macOS download / recovery helpers are not part of this branch (macOS DLC, separate).
- `prepare_stick.py` / `boot_menu.py`: disposable qcow2 fixture and OVMF menu
  adapter. The former boots Linux directly only to construct the test stick;
  the OS flow starts from OVMF, the unmodified UEFI menu and the product
  preparation scripts. Optional guest-only printf observation lines announce
  framebuffer menus/notices. They alter no selection or disk-write decision.
  Append the observer to both boot routes: the general micro-Linux initrd
  and the separate `EFI/USOS-XP/initramfs-xp` used by NT5. Record the frozen
  bundles and verify the own UI script bases before applying that overlay.
  Endpoints require assessment: `ASSESS_ENDPOINT` is never desktop PASS.
  Known catalogue rows without images remain selectable, so choose the actual
  system row rather than pressing Enter on the first row.
- `write_matrix.py`: render a clearly unfinished inventory checkpoint.
  Exact-hash reviewed desktop results and separately cited hardware bindings
  are optional inputs. Import resolution and `ASSESS_ENDPOINT` never become
  desktop PASS. `test_matrix.py` checks that separation and original-PE
  architecture/LCID fallback.
- `synchronize_nt5.py`: make a separate private input cache when an older
  external NT5 package has a settings reader incompatible with the frozen
  production menu/base. Use that exact micro-Linux base and kernel plus all
  262 package-specific entries carried unchanged in the measured snapshot.
  Check the CPIO round-trip and record base/kernel/package hashes. The old
  cache is untouched. This is fixture reconciliation, never a release;
  SP3/SP4 control runs still have to validate the resulting flow.

The menu adapter supports a keyless ESP profile (`--profile` in fixture
creation), selected from its real row trace. Validate it first with the
production `usos-answer.exe render` CLI; time-zone identifiers are IANA
names such as `Etc/UTC`. Rejected profiles terminate the test as an adapter
error. Native support files and an optional read-only PE10 donor may be
included for the modern Windows paths. Record which donor was actually used.

`boot_menu.py --interactive` stops at a completed endpoint and blocks on
operator input. Launch the runner with an open TTY (`exec_command tty:true`);
redirecting its output to a log does not replace that input channel. The
runner rejects a missing TTY before allocating a VM, and EOF before an
explicit finish is an adapter error. Send one JSON action, e.g. `{"keys":["ret"],"settle":20}`,
then inspect the announced `STEP_COMPLETE` frame. Finish with
`{"finish":true}` to save the final evidence and remove the disks. This is
for answering a visible Setup question after the capture boundary; do not use empty actions as
a periodic progress check. `--boot-seconds` provides one target-boot endpoint
after the actual prepared-disk notice, within the overall deadline.

Keyed tests pass only the existing private-key filename with `--private-key`
and the catalogue ID with `--key-for`. Multiple supplied candidates require
an explicit zero-based `--key-index`; no key is generated or put in argv.
The temporary profile is copied to the private disposable ESP, and its host
share is removed after construction. The key's value is absent from metadata
and logs. Keyed tests capture no screen
or VGA contents until a family-specific event proves the key page passed.
For 95/NT3/NT4/POSReady this is the successful prepared-disk notice; for
98/Me and other keyed systems it requires the first-logon notification.
Manual operation of a keyed 95/NT3/NT4/POSReady case is allowed only after
that verified prepared-disk boundary. Keyed NT5/NT6 cases need the exact
nonce line from the first-logon observer before any manual frame/input.
Staging or a log merely containing that nonce does not satisfy the gate.
Staging alone does not prove Setup accepted a key. Keep incomplete images private until
cleanup; never attach or commit them.

Optional first-logon notifications are test instrumentation, not desktop
PASS. `--first-logon-observer` uses the existing `user_script` option and
an own read-only scripts CD for NT5/NT6+. The test-only
`--legacy-first-logon` overlay adds a RunOnce batch for profile-based
98/98SE/Me, preserving the original installation answers. Only an exact
per-test COM1 token allows the endpoint; visually review that frame.
Neither mechanism edits a Windows binary. Record its use with the result.

`--ps2-input` is an explicit alternative to the default xHCI USB input.
`--accel whpx` uses an already available Windows hypervisor, with a different
CPU model recorded in command.json/result.json. It never enables host
features or silently falls back to TCG. A QMP startup/quit probe is only a
hypervisor availability check, not evidence that a guest OS boots.
The own-menu `probe_reset.py` trial currently fails to regain the first
frame within 45 s in WHPX, while TCG regains it in about 3 s with the same
OVMF and CPU flags. Use TCG for the coverage matrix; no Windows failure is
inferred from this emulator limitation.

`--auto-native` is an opt-in fixed input scenario for a known language-auto
profile with an explicitly selected WIM edition: Enter on the language
page and then the disk page. It must not be used to discover unknown UI
states. A marker and endpoint review are still required for desktop PASS.

`collect_guest_logs.py` reads only a stopped, keyless, owned test ESP
read-only. It accepts generated log names and verified images, rejects
invalid binary payloads, and records corrupt data as metadata instead of
retaining it. Its direct Linux boot is evidence collection, not an OS test.

`run_plan.py` executes an explicit case list one at a time.
NT5/Win7 targets default to **32 GiB virtual capacity**, still thin qcow2.
The actual NT5 partition planner requires at least 10 GiB total and an
8 GiB contiguous reservation. An 8 GiB whole disk is not a valid fixture;
explicit undersized NT5 cases are rejected. Legacy nested cases keep 4 GiB.
Its optional
`--after` subscribes to the owned prior test's cleanup-file creation using
Windows directory notifications, including a future case directory, not
repeated status-file reads. Default lanes accept only flat NT5/NT6 flows.
Vista / Server 2008 x86 use the reviewed `vista_csmwrap_prepare.sh` and
`vista_csmwrap_target.sh` route: prepare the target's staging WinPE and boot
it through CSMWrap in the same outer emulator. They do not start the nested
9x/NT4 QEMU installer. The PE10 donor architecture must match x86.
`--nested` explicitly reserves a two-engine lane for 9x/NT3/NT4/POSReady;
the default lane rejects these products. One flat lane and one nested lane
can stay at three engines. The caller must reserve those slots; this is
not a global VM scheduler. Archive members are
hash checked and removed after the case. Results still require assessment.
`--after-file` can instead wait for an owned terminal plan manifest, which
also covers an older runner rejecting a fixture before QEMU starts.
An optional `service_pack` input supplies the unchanged, hash-checked
prerequisite under the filename expected by the NT4 preparation flow.

For USB/LAN tests a case can set `nic: "igb"` (82576 / 8086:10C9, present in
the actual usosnet source and INF), `usability_usb: true`, and
`usb_pointer: "mouse"`. The default pointer remains a tablet for other
cases; NT4 boot-protocol HID tests require the relative USB mouse. Two
owned thin FAT16 sticks contain START.TXT / HOTPLUG.TXT. The first attaches
only after USOS prepared the selected target; the second attaches with
`{"usb":"insert","settle":5}` and detaches with `{"usb":"remove","settle":5}`.
Device removal awaits DEVICE_DELETED, including an event preceding the
command reply. No host USB device is forwarded.

At a verified desktop use `{"hid":{"device":"keyboard","state":"remove"},"settle":2}`
and the corresponding `insert`; `device: "mouse"` does the same for the
owned pointer. `{"pointer":{"dx":100,"dy":60},"settle":2}` sends relative
movement with the mouse variant. Check actual key input and pointer motion
and clicks after reconnecting. An optional `"click":"left"` (or right/middle)
inside `pointer` sends a button-down/up pair through the same emulated mouse.
The event schema follows the [QEMU QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#command-input-send-event).
Review the guest driver log too; QMP acknowledging an action
is not a functional PASS. PS/2 hardware remains available to NTDETECT, so
typing while USB is absent does not prove USB routing. The action journal
stores only key counts, never the text typed. These actions are test
operations, not periodic progress sampling.

NT4 and native fixtures do not require an unrelated XP initrd. NT5 fixtures
still require their separate package. Frozen feature inputs must be named
and hashed independently; a newer repository base does not make an older
asset cache a newly built release.

Framebuffer menus use an explicit allowlist. The disk-mode dialog chooses
its first row (keep partitions / use unallocated space on the blank owned
target). An unknown dialog stops the adapter instead of silently consuming
the entire timeout. A product failure ends an interactive case without
opening an unverified keyed Setup frame; that failure remains in metadata.

`collect_nt4_failure: true` plus the explicit frozen `--evidence-assets`
allows an **explicitly keyless NT3/NT4 diagnostic case only** to collect the inner Setup's
saved screen/logs before disk cleanup. It runs one read-only Linux collector
after outer and nested QEMU have ended, within the reserved two-engine lane.
The folder must exactly match the allowlist in `usability_aux.py`, and
`private_profile` must be the boolean `false`, never an absent or false-like
value. It never runs on a keyed test. This diagnostic can reveal the Setup question;
it is not a completed installation or USB test. Collection failure is saved
separately and never prevents normal image cleanup.

In an NT5/NT6 interactive usability case, the boot-test stick can first attach
after verified first logon. That initial insertion is **not** USB-at-start
PASS: explicitly reboot with it attached and review the file after boot.
Its attachment event is recorded separately from the prepared-disk route.

An optional `usability_logger` and required exact `logger_sha256` add the
own GUI logger to the scripts CD. The test-only script copies it under
`%SystemDrive%\USOS\Coverage`, runs one snapshot to USABILITY.TXT and then
emits the first-logon nonce. Copy/diagnostic failure does not turn the nonce
into network PASS: inspect the completed log independently. This is fixture
instrumentation through the existing user_script option, not installer
staging or a release build. The normal installed LAN helper remains GUI-only.

An optional `driver_zip` plus exact `driver_zip_sha256` supplies a private
`Other/package/...` archive under collection `_assets`. The fixture validates
paths, Windows aliases, links, collisions, bounds and SHA-256, copies the
unchanged files to normal `DATA/Drivers/<system>` and reads them back.
Production Setup chooses the matching INF; the adapter does not install a
driver on the host. Inputs and licenses stay outside Git. This option does
not imply vendor redistribution rights or runtime compatibility.

All new media/scratch is under `G:\USOS-Kolekcja`; other G: paths are never
traversed. No physical disk is attached to a writable VM. Keep at least 100 GiB
free and 8 GiB available host RAM, at most three VMs globally. VM disks are
thin qcow2 and are removed after saving each result; NVRAM is removed too.
Wait for serial input, QMP replies or process completion. Do not sample logs,
screenshots or process status to collect progress. A bounded endpoint image
is not evidence that Windows itself hung.

Local defaults reference the development PC's assets and collection; pass
explicit inputs. Keep product keys in the private test-key directory and do
not place them in tool arguments, Git, logs or unknown-state screenshots.

An unanswered USOS `form` now ends an automatic case immediately. In
particular, a keyless NT4 case otherwise waits at the USOS key form, before
any native installer starts. Do not mistake that timeout for an NT4 error.
`collect_nt4_text` accepts a keyed NT4 failure/timeout but exports only four
explicit native text logs from the stopped disposable FAT16 target. The
guest strips non-ASCII bytes, key-shaped strings and numeric runs before
transport; the host validates that rule again. No screens, answers or hives
are exported. This deliberately loses numeric error codes and accented
characters. Existing keyed screenshot restrictions are unchanged.

An explicit plan `usb_only_input: true` with `ps2_input: false` adds
`--usb-only-input`. This uses the verified q35 `i8042=off` property;
contradictory flags fail before a fixture or disk is opened. Result metadata
records `usb_only_input` and `ps2_controller_enabled`. Earlier/default runs
keep their PS/2 controller and must not establish USB input solely through
a successful `sendkey` or mouse action. Disabling PS/2 is only a fixture
precondition, not proof of successful HID input or an automatic PASS.

Run the integrity regressions from the worktree:

```powershell
python -I -B tools/tests/coverage/test_integrity.py -v
```

The synthetic tests distinguish a valid XAR TOC digest from a whole-file
digest, reject changed TOCs/manifests/blocks, check catalogue size and ensure
CAB temporary inputs are removed. Actual-media checks and QEMU evidence are
in the local ignored `artifacts/coverage/` directory; binaries are not committed.
