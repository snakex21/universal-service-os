# Windows 95 RTM wizard profiles — normal installation pending

The fresh normal RTM PL test reached welcome and directory selection, then
its 90-minute phase-one deadline. DOS preparation and Patcher9x completed;
Windows files were not copied. A separate flat, sanitized diagnostic
revealed a Product ID page: RTM has one edit and requests the full
`xxxxx-OEM-xxxxxxx-xxxxx` form. The existing OSR2.1 PL guard recognizes a
different, three-field COA page and therefore correctly sent no key here.

A separate `coa-single` fingerprint uses the RTM heading and static label
at `(214,212,260,16)`, above the edit at y=235. Its handler clears one edit
and emits the full OEM form through the existing discarded monitor. It
retains the 17-digit source-shape check, pre-copy bound and one shared key
attempt across both COA variants. Unknown pages receive no key. The old
three-field handler is unchanged.

The diagnostic used the exact RTM PL ISO SHA-256
`6cb14073c3090c5168c17cf28e845fac4f5c017699edb59a185b8f340454d313`.
All known private key forms were removed and rescanned in a stopped-disk
clone before viewing. Raw files and screenshots stayed in private G:
collection scratch; only static-label hashes are included here. The flat
diagnostic uses PS/2 and proves neither normal installation nor USB.

Eleven host input-policy tests cover both forms, complete single-edit key
sequence, shared attempt limit, copy bound and absence of key text in logs.
Six native matcher cases using the actual keyless RTM frames pass: single
COA, recovery, welcome and busy; modifying edit-field pixels leaves the
COA match intact, while modifying its static label rejects it. Images stay
in private collection scratch. Both static Linux helpers were rebuilt.
The normal r18 retry also stopped at its phase-one deadline (5451.42 s
host elapsed). It emitted welcome and directory events, then the product
reported Preparation stopped and withheld restart. No desktop or network
capture was reached. Sending Enter on a matched page is not proof that
the guest advanced.

A subsequent private flat calibration r20 observed only public heading
pixels at `(104,90,480,24)` and metadata about the Next button. It never
saved full private frames or edit pixels. Its synthetic privacy test
verified those bounds and that an edit-only change produced no output.
The original ProductID was retained in this diagnostic disk, so the
normal private-answer route could be examined without sanitizing it into
a different sequence.

This exposed a missing RTM setup-type heading: `a07c4a33fc5c5f22`,
"Opcje programu Instalator". The existing OSR2.1 fingerprint differs.
Explicitly answering that page advanced to the native `coa-single`
two-label match. One full OEM attempt then advanced to the matched owner
page (`202c4cd89699d426`), confirming key acceptance in this flat
diagnostic. The same shared one-attempt policy was retained; no value or
scancode sequence was logged. The diagnostic ended deliberately at that
completed boundary with QEMU exit 0. Its PS/2 input does not prove USB.

The new setup-type fingerprint contains only static heading metadata.
Heading paint can precede the enabled Next button; the diagnostic
distinguished their states, but an early Enter has not been established
as the cause of either normal failure. The confirmed missing page was
setup-type. A fresh normal test with both RTM profiles, installed desktop,
USB, network, second boot and independent OSR1 EN coverage is still
required. No full release build, merge, push or physical-disk write.

The expanded native matcher audit passes eleven cases, including three
partially painted headings rejected before the complete RTM setup-type
heading is recognized. The input-policy suite passes eleven cases.
The RFB test cleanup now tolerates Windows resetting a rejected peer
before local shutdown; exit status and output assertions still run.
