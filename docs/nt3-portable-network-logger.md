# Portable network diagnostics for NT 3.x

Branch: `fix/nt31-net`. This is an own diagnostic helper, not an operating
system DLL replacement or an Intel NIC driver. There is no installed NT3
runtime, USB or network PASS from this change alone.

The previous logger imported `GetVersionExA` and `lstrcpynA`, absent from
the original NT 3.1 KERNEL32, and declared PE OS/subsystem 4.00. The NT3
build now declares 3.10, uses an own bounded copy and resolves the extended
version API dynamically with a `GetVersion` fallback. The existing normal
logger build keeps PE 4.00. Both use the same source.

NT 3.1 ICMP.DLL does not export the three named echo APIs used by newer
systems. Only the NT3 build enables a Winsock 1.1 raw ICMP fallback. It sends
to the gateway discovered from configuration, accepts only a matching
IPv4 echo reply (source, length, checksum, identifier, sequence and complete
payload), and bounds reception to five seconds / 32 packets. Missing raw
socket support is reported as UNAVAILABLE. A configured gateway or DHCP
registry record is explicitly not a live connectivity or lease proof.

Diagnostics default to `LOGS` beside the executable and follow the moved
application folder. For VM collection use `/nohook` and a local application
output path; do not enable a debug hook or write diagnostic state to a
user profile or the registry.

## Validation

Build with the existing pinned OpenWatcom runtime (no full USOS build):

```powershell
python -I -B tools/build_nt3_usoslog.py --out artifacts/nt3-logger/build-03 --watcom-root C:\Users\ASRock\usos-work\dokumentacja-9x\tools\cache\openwatcom\ow-bac354f3c75f
```

The output folder must not exist before the command. Candidate EXE SHA256:
`fcf99da83e40fbee37496f22ff0f0cfec3386b393db36c87e748ef87c845017e`.
It is a GUI executable without a C runtime dependency. An audit against
original media confirmed all 71 static imports and all 19 dynamically
used Winsock functions in NT 3.1, 3.5 and 3.51. PE OS and subsystem are
both 3.10. The original media modules were inspected in memory; they are
not included in this branch.

Sixteen host tests passed across `test_nt3_logger_compat.py`,
`test_nt3_raw_icmp.py`, and `test_logger_network.py`, with
`USOSLOG_TEST_EXE` set to the actual built candidate. They exercise the
compiled helper logic, malformed/unrelated packets and failure cleanup,
the existing ICMP DLL path, and actual portable EXE output after moving
the application. The real EXE host tests use
`/once /nonet /nodbg /nohook /nodisk`; they do not access the host network.
Source CRLF in `usoslog.c` is preserved.

The audit metadata is local at
`C:\Users\ASRock\usos-work\macierz-windows\artifacts\coverage\nt3-logger-candidate-original-exports.json`.
Static compatibility and host packet tests do not establish raw socket
support, a DHCP lease, ping or DNS in an installed NT guest. Those require
the normal fresh-install VM tests and their actual guest log.
