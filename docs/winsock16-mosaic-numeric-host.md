# Mosaic Win16: hosts beginning with a digit

Independent binary review, 2026-10-24. This is an application parser defect,
confirmed in the original Mosaic 1.0 and 2.0 alpha2 executables. No Mosaic
binary was changed. No Trumpet or Microsoft source was used.

## Observed failure and cause

The completed Mosaic 1.0 QEMU capture supplied by the main test run showed a
SYN to `68.0.222.39`, although DNS for `68k.news` should give
`134.209.213.152`. The original program decides whether a host is numeric by
checking only its first character. `68k.news` therefore takes its numeric
IPv4 path and never calls `gethostbyname` for that URL.

In the numeric path, `sscanf(host, "%d.%d.%d.%d", ...)` converts only `68`.
The failed conversion count produces an error message, but execution then
copies all four local integer values into the socket address. The remaining
three values are uninitialized stack contents. Their particular values are
not stable and must not be used as a compatibility rule in Winsock.

## Original executable evidence

Mosaic 1.0 executable: 573952 bytes, SHA-256
`9d7ac5b6400261a657c8bf95bd9fdbd8b12b603bb8b0dcaece21476b5909d75b`.
Its NE segment 2 begins at file offset `0xF240`.

| NE address | Original behavior |
| --- | --- |
| `0002:44BC` | Start of the host/port parsing routine identified by the adjacent `HTParseInet()` trace string |
| `0002:4553`–`456A` | Check only whether the first host character is between ASCII `0` and `9` |
| `0002:459C` | Scan four decimal components using the format string at DGROUP offset `0x3641` |
| `0002:45A4`–`45B3` | Compare conversion count with four; emit `Invalid Host string!` when unequal |
| `0002:45B8`–`45E0` | Copy all four local low bytes to `sin_addr`, including after failed conversion |
| `0002:45EF` | Far call whose relocation operand at `45F0` imports `WINSOCK!GETHOSTBYNAME`; reachable from the nonnumeric branch |

Original 2.0 alpha2 was downloaded from the historical
[FUNET archive](https://mirrors.nic.funet.fi/pub/files/index/msdos/windows/comm/wmos20a2.zip)
into the external Win16 application collection. Archive: 243749 bytes,
SHA-256 `9dbb85988ac3409d536573efb92a9006777a80fcb2a8984a6eefe79b87e79706`.
Executable: 624960 bytes, SHA-256
`ceab0a9272df7cc57ce994a3ee772d7dfbb414412a8216bebabdf73ec57d1eb3`.

Alpha2 has an NE Windows executable with ordinary Win16 imports (`WINSOCK`,
`WIN87EM`, `KERNEL`, `GDI`, `USER`, `KEYBOARD`, `COMMDLG`, `MMSYSTEM`,
`SHELL`), without a Win32s dependency. However, its parser retains the same
defect: initial-character check at `0002:45FB`–`4612`, numeric scan at
`0002:4644`, count check at `464C`, and unconditional component copies at
`4660`–`4688`. Upgrading to this version alone does not solve this URL.

The mirrored [NCSA release history](https://sunsite3.icm.edu.pl/packages/Mosaic/Windows/Archive/)
dates alpha2 to 1994-02-28 and identifies alpha3 (1994-04-06) as the switch to
32-bit. Later 2.x releases therefore do not meet the pure Win16/Windows 3.1
STANDARD requirement without separate verification.

## Practical test

Use the unchanged Mosaic 1.0 with `http://www.68k.news/`. Its first character
selects the DNS branch. On the host on 2026-10-24, the public DNS alias was
`www.68k.news CNAME 68k.news`, with A record `134.209.213.152`; a direct HTTP
HEAD request returned `200 OK` without a redirect. This is host evidence,
not a claim that Mosaic's page-rendering gate passed in QEMU.

The numeric URL `http://134.209.213.152/` also returned HTTP 200 on the host,
but bypasses DNS and is a weaker network test. Do not alter Winsock's normal
numeric parsing or destination routing to mask the application's malformed
address. A future browser patch would have to validate the entire host and
fall back to DNS; it is outside this review.

Review artifacts remain under `zig-out/win16/tcp-stage2/`:
`mosaic-ne.json`, `mosaic10-host-parser.disasm.txt`,
`mosaic-alpha2-ne.json`, `mosaic-alpha2-host-parser.disasm.txt`,
`mosaic-www-dns.json`, and `mosaic-www-head.txt`.
