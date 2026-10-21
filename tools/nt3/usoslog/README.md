# Isolated NT3 logger

Exact own GPL source snapshot from `fix/nt31-net` commit `7024a504`, files
`src/platform/bios/win9x/usoslog*`. `source.json` binds the snapshot and
provided binary to hashes. This separate directory preserves the NT4/9x
source and payload versions in the base cache. No Microsoft source or files.

The supplied binary is GUI PE3.10, SHA256
`fcf99da83e40fbee37496f22ff0f0cfec3386b393db36c87e748ef87c845017e`.
The originating branch reports16 host tests PASS and original-media import
preflight. These are not installed NT3 or network PASS. NT351 uses ICMP.DLL;
NT31's raw socket fallback is still subject to runtime availability.

Rebuild with an existing pinned OpenWatcom, writing only to a fresh output
inside this worktree:

```
python -I -B tools/nt3/usoslog/build.py --watcom PATH --out artifacts/nt351-network/logger
```

The NT351 stage copies the logger beside its other tools and writes
`TESTNET.CMD`. Run it explicitly after the installed desktop appears:
`USOSLOG.EXE /once /nohook /nodbg /out C:\USOS\NT3\USABILITY.TXT`.
It does not write application diagnostics to the registry or user profile.
