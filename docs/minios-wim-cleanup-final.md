# MiniOS 1b-2: post-report image cleanup

The final report RAPORT-MINIOS-ETAP1B2.md was saved before cleanup. It contains
the full immutable plan and exact removal result, including every path, size,
SHA256, file identity and attributes. No cleanup occurred before that report.

- All 355 explicitly selected test images/vars were exclusively opened and
  hashed before the plan was appended. The separate execute phase rechecked
  every image before its first deletion. Removal completed: 355, failed: 0.
- Removed logical sizes total 143,932,442,624 B. This is not a claim about
  physical space recovered from sparse images. Every removed path is absent.
- All 1,365 retained sentinel files have identical size and SHA256 after
  cleanup, including both original install.wim inputs. Logs, JSONL, captures,
  manifests and previous failure evidence remain. The 42 application sources
  and six final compiled artifacts also retain their exact sealed hashes.
- The final aggregate pool, including conservative opaque ACL reservations,
  is 7,176,240,678 B. Observed free Kioxia space after cleanup was
  227,501,805,568 B; the 100 GiB reserve remained satisfied.
- All VM, build and native helper operations had completed before cleanup.
  No physical disk, other VM, source media, cache, key or historical Git
  driver/certificate was deleted by this operation.

Runtime-relative evidence (no payloads are committed):

| Receipt | SHA256 |
|---|---|
| cleanup-plan01.json | 6e5912c13af51d04c32fc0e6494dc9f9f727a18e7219aa590354cd49fae7cedc |
| cleanup-result01.json | ecfbeb37ee07bcf1cd9dd3a2c9440d5972bdd06e6b36f5568b081233a00613d5 |
| retained-sentinels01.json | 466d58d2add929461afcca8f907db09396f92507a3b4b90e3b9c287ad246d2b8 |
| retained-sentinels-after-cleanup01.json | 921258a2888368b1eefbd10f752156bb01f40ca31dcc73f291d11a22322b257c |

The earlier portable acceptance manifest is a snapshot at report production,
when all images were retained. Its receipt pins and test outcomes remain
unchanged; this note and the final report record their later disposition.
Stage closed. No next-stage work, merge, push or deployment is authorized.
