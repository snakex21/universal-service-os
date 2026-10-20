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
- `download_apple.py` / `apple_integrity.py`: Apple full packages. Catalogue
  `Digest` checks the compressed XAR TOC, **not** the complete PKG. Check all
  SHA-256 blocks using Apple's HTTPS `integrityDataV1` as well; method 2 is
  a self-checking manifest, not a digital signature. Record a full-file SHA-256
  locally. These downloads are not bootable ISO files.
- `download_apple_recovery.py`: invoke the pinned existing OpenCore recovery
  utility with a documented public board ID and placeholder MLB; verify the
  signed recovery chunklist. Recovery is an online-install environment.
- `prepare_stick.py` / `boot_menu.py`: disposable qcow2 fixture and OVMF menu
  adapter. The former boots Linux directly only to construct the test stick;
  the OS flow starts from OVMF, the unmodified UEFI menu and the product
  preparation scripts. Optional guest-only printf observation lines announce
  framebuffer menus/notices. They alter no selection or disk-write decision.
  Endpoints require assessment: `ASSESS_ENDPOINT` is never desktop PASS.
  Known catalogue rows without images remain selectable, so choose the actual
  system row rather than pressing Enter on the first row.
- `write_matrix.py`: render a clearly unfinished inventory checkpoint.
  Exact-hash reviewed desktop results and separately cited hardware bindings
  are optional inputs. Import resolution and `ASSESS_ENDPOINT` never become
  desktop PASS. `test_matrix.py` checks that separation and original-PE
  architecture/LCID fallback.

The menu adapter supports a keyless ESP profile (`--profile` in fixture
creation), selected from its real row trace. Validate it first with the
production `usos-answer.exe render` CLI; time-zone identifiers are IANA
names such as `Etc/UTC`. Rejected profiles terminate the test as an adapter
error. Native support files and an optional read-only PE10 donor may be
included for the modern Windows paths. Record which donor was actually used.

`boot_menu.py --interactive` stops at a completed endpoint and blocks on
operator input. Send one JSON action, e.g. `{"keys":["ret"],"settle":20}`,
then inspect the announced `STEP_COMPLETE` frame. Finish with
`{"finish":true}` to save the final evidence and remove the disks. This is
for answering a visible keyless Setup question; do not use empty actions as
a periodic progress check. `--boot-seconds` provides one target-boot endpoint
after the actual prepared-disk notice, within the overall deadline.

Keyed tests pass only the existing private-key filename with `--private-key`
and the catalogue ID with `--key-for`. Multiple supplied candidates require
an explicit zero-based `--key-index`; no key is generated or put in argv.
The temporary profile is copied to the private disposable ESP, and its host
share is removed after construction. The key's value is absent from metadata
and logs. Keyed tests refuse interactive screenshots, and capture no screen
or VGA contents until a family-specific event proves the key page passed.
For 95/NT3/NT4/POSReady this is the successful prepared-disk notice; for
98/Me and other keyed systems it requires the first-logon notification.
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

`--auto-native` is an opt-in fixed input scenario for a known language-auto
profile with an explicitly selected WIM edition: Enter on the language
page and then the disk page. It must not be used to discover unknown UI
states. A marker and endpoint review are still required for desktop PASS.

`collect_guest_logs.py` reads only a stopped, keyless, owned test ESP
read-only. It accepts generated log names and verified images, rejects
invalid binary payloads, and records corrupt data as metadata instead of
retaining it. Its direct Linux boot is evidence collection, not an OS test.

`run_plan.py` executes an explicit NT5 case list one at a time. Its optional
`--after` subscribes to the owned prior test's cleanup-file creation using
Windows directory notifications, not repeated status-file reads. Only
one-engine NT5 paths are accepted by this queue: with a separate nested
9x trial, the total can then stay at three engines. The caller must reserve
those slots; the queue is not a global VM scheduler. Archive members are
hash checked and removed after the case. Results still require assessment.

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

Run the integrity regressions from the worktree:

```powershell
python -I -B tools/tests/coverage/test_integrity.py -v
```

The synthetic tests distinguish a valid XAR TOC digest from a whole-file
digest, reject changed TOCs/manifests/blocks, check catalogue size and ensure
CAB temporary inputs are removed. Actual-media checks and QEMU evidence are
in the local ignored `artifacts/coverage/` directory; binaries are not committed.
