# Current NT351 stopped-target driver pin

Future collection expects the17024-byte own usosnet351 SYS
`f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a`.
This is the original-NDIS stub handling fix used in completed installed
R18f. The new helper marker guard changes only its EXE, not this SYS.
NT35/NT4 pins, file allowlists and runtime assessment rules are unchanged.

The older dc882795 candidate is no longer the expected future input.
Original R18f collector mismatch metadata is preserved: later manual
readback qualified f39 explicitly, and this change does not rewrite that
older collection. Hash match still never establishes desktop/USB/LAN PASS.

Tests check the actual candidate bytes using USOSNET351_TEST_DRIVER,
with explicit skip if unavailable, and reject the former pin. Local
qualification supplies the real path and requires zero skips.
