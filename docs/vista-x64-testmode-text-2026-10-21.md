# Vista x64: test-mode text via user32.dll.mui strings - TRIED, NOT USED (2026-10-21)

Status: **not used. Ineffective on the X470.** The code stays on the unmerged
branch `feat/vista-x64-testmode-text` (c62965db, 2713a22c, ec77e929) and is not
part of the integration branch. The installer does **not** run
`blank_testmode_text`; the Vista x64 path keeps **usoswm** staged and
registered (overpaint, outline drag per session, shutdown cover), which is
the X470 PASS solution (build B261021-162947, see
`tools/nt6/usoswm/README.md`).

## What was tried

Analysed read-only on files from the user's own Vista SP2 PL x64 media
(`user32.dll` 6.0.6002, `pl-PL\user32.dll.mui` 6.0.6001.18000, `win32k.sys`
6.0.6002), local policy of 2026-10-13:

- `user32!UpdatePerUserSystemParameters` loads the desktop texts once per
  process and passes them to win32k. With `CODEINTEGRITY_OPTION_TESTSIGN` it
  uses string **738** (`Tryb testu` / `Test Mode`, the corners) and **722 /
  723** (the version line `Microsoft (R) Windows (R) (Kompilacja ...)`).
  Safe mode uses 719 for the corner text.
- Attempt 1: set 722/723/738 to **empty** in the installed
  `System32`/`SysWOW64` `<lang>\user32.dll.mui` (in place, backup semantics,
  backup + SHA-256 read-back, PE checksum recomputed). X470: the native text
  showed permanently (4 corners + top line), worse than before, partly because
  usoswm had been removed from the path at the same time.
- Attempt 2: set the strings to a **single space** (a zero-length entry makes
  `LoadString` return 0), also patch the WinSxS copies, add a read-only
  `--report`. Host-checked with `LoadStringW` on the patched copies
  (722/723/738 = one space, other strings unchanged).

## Result on hardware

No effect on the X470 (Vista SP2 PL x64, CSMWrap, test mode): the test-mode
texts were still drawn. The text shown on the hardware therefore does not come
from the `user32.dll.mui` files that were patched (not from the loaded copies
of strings 722/723/738); its real source is elsewhere and was not identified.
The string approach is closed.

## What stays

- usoswm on the Vista x64 path (staged under `C:\USOS\usoswm`, registered by
  the x64 OOBE gate). X470 2026-10-21: no test-mode text visible anywhere,
  including window drag and shutdown.
- The DATA marker `Systems\Windows\<system>\Unattended\testmode-watermark-on.txt`
  keeps its usoswm meaning (opt-out of the overpaint).
- Not carried over: `tools/vista_testmode_text.h`, `blank_testmode_text()` in
  `tools/windows_vista_install.c`, the offline harness and its tests, and the
  removal of usoswm from `tools/build_windows_vista_support.py` / the OOBE gate.
