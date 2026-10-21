# Isolated NT3 logger

Own GPL source based on `fix/nt31-net` commit `7024a504`, files
`src/platform/bios/win9x/usoslog*`. `source.json` binds the snapshot and
provided binary to hashes. The NT3-only patch adds strict DNS validation.
This separate directory preserves the NT4/9x
source and payload versions in the base cache. No Microsoft source or files.

The supplied binary is GUI PE3.10, SHA256
`ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7`.
The originating branch reports16 host tests PASS and original-media import
preflight. These are not installed NT3 or network PASS. NT351 uses ICMP.DLL;
NT31's raw socket fallback is still subject to runtime availability.

The updated DNS test accepts only a complete response from the requested
server port53, matching ID, QR/opcode/rcode, exact question+A/IN and a matching
answer A or bounded CNAME chain. It validates every record before accepting
the address, rejects compression loops and logs dns_match=1 only on success.
It is a diagnostic query matcher, not a general resolver or DNSSEC validator.
Seven host tests execute this actual C parser, including1500 mutations.
The rebuilt binary retains all71 original preflighted imports and PE3.10;
its second pinned rebuild is byte-identical. No installed NT3 PASS is implied.

Rebuild with an existing pinned OpenWatcom, writing only to a fresh output
inside this worktree:

```
python -I -B tools/nt3/usoslog/build.py --watcom PATH --out artifacts/nt351-network/logger
```

The NT351 stage copies the logger beside its other tools and writes
`TESTNET.CMD`. Run it explicitly after the installed desktop appears:
`USOSLOG.EXE /once /nohook /nodbg /out C:\USOS\NT3\USABILITY.TXT`.
It does not write application diagnostics to the registry or user profile.
