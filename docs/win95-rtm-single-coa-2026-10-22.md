# Windows 95 RTM single-field Product ID — runtime pending

The fresh normal RTM PL test reached welcome and directory selection, then
its 90-minute phase-one deadline. DOS preparation and Patcher9x completed;
Windows files were not copied. A separate flat, sanitized diagnostic
revealed the next page: RTM has one Product ID edit and requests the full
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
The real key acceptance, normal installed desktop and OSR1 EN UI remain
unverified. No full release build, merge, push or physical-disk write.
