# NT4 public-ID diagnostic snapshot

Own diagnostic source only. Product setup integration remains WIP. No driver,
hub, native Setup executable, private answer, resource text or hive is included.
The numeric IDs and named dialog identifiers come from the original PL CD.

The wrapper preserves exact native `setup -newsetup` launch and exit semantics.
It reads only STATIC/BUTTON/top-level dialog captions through bounded
WM_GETTEXT, never EDIT. It matches original resources in guest RAM and emits
only allowlisted public IDs and closed flags. Inserted values are never emitted.
Whole-frame mutex synchronization prevents final-child-exit interleaving.
COM failure never blocks native launch or own-file observation.

The original loader selects SYSTEM.SAV when RestartSetup>=1. Runtime09 proved
that changing this saved hive reaches the wrapper;06–08 changed the wrong hive.
Runtime10 proved UART availability with native Serial Start2-to-1 on a single
owned overlay.11 confirmed module/message1010/CP1250 oracle availability.
12 added75 exact named SETUPDLL dialogs but still did not identify the modal.
All attempts quit cleanly without UIactions. There is no NT4 desktop/LAN/HID/MSC
or physical hardware PASS. No own VM is left running at this checkpoint.

The original KERNEL32 message1010 was parsed successfully in RAM in the local
artifact application; no original bytes were exported. The standalone snapshot
contains only synthetic parser inputs. Message views, formatted insertions and
unmatched captions remain in RAM. Diagnostic literal fragments cannot authorize
ACK. Named dialog identifiers have an exact manifest allowlist.

Using configured Python/Zig paths, run each file in a fresh output folder:

```
python -I -B test_semantics.py
python -I -B test_cross_process.py
python -I -B test_message_table.py
python -I -B test_template.py
python -I -B test_named.py
python -I -B test_protocol.py
```

38 standalone host tests passed against this snapshot:7 actual-C lifecycle,
4 real separate-process WM_GETTEXT,6 bounded message-table parser with1500
mutations,9 whole-template/diagnostic-fragment,2 actual named-dialog dispatch,
and10 strict protocol tests. Separate local adapter tests cover operator and
post-quit exact paths. These are host evidence, not a Windows installation PASS.

`verification.json` records the exact build15 hash and original compiled-source
hashes separately from this LF-normalized snapshot. `public_manifest.json`
contains only original public IDs, module names and hashes. It contains no
Microsoft resource text or executable bytes. The live diagnostic application
and stopped overlays remain at the absolute paths in the NT4 report.
