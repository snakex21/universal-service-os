# Win16 DPMI call lifetime (stage 3)

The two-task native test exposed a defect invisible to the host shim. Task A
created the shared `GlobalDosAlloc` register/stack block. After A cleaned up
and exited, B still owned valid socket state, but its next real network I/O
failed. The diagnostic capture reported a valid queue mapping and an invalid
real-mode call selector. Merely testing a nonblocking empty receive did not
exercise the transport and therefore did not establish survival.

`rm_int` now keeps its 50-byte register structure on the caller's protected
stack. A local FAR pointer supplies ES:DI; the build's `-zu` matters because
a DLL's DS differs from its caller's SS. Zero SS:SP requests the DPMI host's
real-mode stack. There is no persistent DOS allocation or per-packet heap
allocation. Queue descriptors remain independently owned and released.

Public contracts: [DPMI 0.9, function 0300h](https://www.delorie.com/djgpp/doc/dpmi/api/310300.html),
and the protected-stack register structure in Microsoft's public
[SDK example Q104790](https://jeffpar.github.io/kbarchive/kb/104/Q104790/).
No implementation from another Winsock provider is used.

QEMU only: `api-win31-06` and `api-wfw311-06`, in the external stage3 runtime,
have both `APIA.LOG` and `APIB.LOG` ending `FINAL PASS`, without `FAIL`.
The actual GetWinFlags value is 3113 / ENHANCED. B verifies its own DNS result,
performs fresh DNS and TCP connect/send/receive with HTTP 200 after A exits,
and completes the last WSACleanup. These checks supplement the host tests;
the host does not emulate segmented pointers or Windows task-owned memory.

The earlier callback crash in APITEST itself was fixed by exported FAR PASCAL
callback prologues for `MakeProcInstance`. The shared DLL window procedure
uses its own DS directly rather than a task-owned thunk.
