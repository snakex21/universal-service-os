# Complete evidence archive validation

Canonical base64 can contain two concatenated gzip archives. Generic
gzip/tar readers can accept the first while silently ignoring later tar
data, so a canonical transport frame alone does not validate its entire
container. An own synthetic native-text repro demonstrated this case;
no Windows runtime or earlier historical assessment was changed.

All four bounded NT evidence exporters now share `evidence_archive.py`.
It accepts one bounded gzip stream with its complete EOF and CRC, rejects
unused/trailing compressed data, and requires at least two zero tar end
blocks followed by zero padding only. Existing file allowlists, text
sanitization, member/total limits, transport decoding and result semantics
remain in their respective exporters. Validation precedes file writes.

Validation:122 coverage tests PASS/31.656s, with the real explicit NT35
candidate input available. New tests cover concatenated gzip inside one
canonical frame, two tar archives inside one gzip, nonzero trailers,
truncation/CRC, absent tar terminators and bounded expansion. Each of the
four exporters also accepts valid ordinary archives.

The completed real R18f BusyBox collector transport passed the same new
container checks in a metadata-only replay:
`artifacts/coverage/evidence-integrity-r18f-replay/result.json`.
It exported no additional guest files and did not rewrite the old hash
guard or runtime assessment. Active VM modules are not monkey-patched;
their start versions and any later collection/replay versions must be
recorded separately.
