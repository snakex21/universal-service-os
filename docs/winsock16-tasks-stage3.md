# Winsock Win16 task isolation and blocking calls

The DLL is shared, but its application state is keyed by `GetCurrentTask()`.
At most eight initialized tasks are supported. Each task has a separately
allocated, shared FAR heap block with its startup count, last error, blocking
hook/cancel state, hidden timer window, four async DNS jobs, and database/address
result buffers. Inactive contexts can be reused after `WSACleanup()`.

The transport and its sixteen socket slots remain global. Public sockets carry
a task owner; a different task receives `WSAENOTSOCK` before accessing or closing
one. The last cleanup for a task closes only its sockets/jobs/window. The queue
and engine shut down only after the last startup reference of all tasks is gone.
Async DNS's private sockets also consume the same bounded sixteen-slot pool.
There is one DLL window class, with a separate window/timer and message queue for
each application. Cleanup of one application keeps the class and other timers.

The blocking state begins at the first actual cooperative wait, rather than
marking every call as blocking. Immediate/nonblocking requests never call the
hook. Once waiting, another API call by the same task fails `WSAEINPROGRESS`,
including nonblocking operations. `WSAIsBlocking`, `WSACancelBlockingCall`, and
the error accessors are exceptions. A different task may run its own request.
The installed hook's previous value is returned, including the real default
pump; unhook restores it. A custom hook returning FALSE does not cause arbitrary
application messages to be dispatched behind its back. Provider-window messages
may be dispatched before the application hook.

Cancellation is per task, mapped from the engine's `USOS_SOCK_ECANCELLED` to
`WSAEINTR`. Blocking flags are cleared before returning. Forward/reverse DNS and
wrapper select also observe cancellation. The engine defines the socket result:
recv/accept retain it; connect stops its pending attempt but retains the slot;
send returns bytes already accepted; close releases its slot even when cancelled.

The public contracts are Microsoft's [Winsock1.1 blocking and reentry rules](https://learn.microsoft.com/en-us/windows/win32/winsock/windows-sockets-1-1-blocking-routines-and-einprogress-2)
and [blocking hook description](https://learn.microsoft.com/en-us/windows/win32/winsock/blocking-hook-2),
with the original Open Watcom Winsock declarations. No Microsoft or other
provider implementation source was used.

Host validation executes the actual wrapper and engine with a task-aware fake
Windows message queue. Nine wrapper cases cover isolated errors/results,
socket ownership, separate jobs/windows, cleanup survival, startup references,
eight-task capacity/reuse, hook replacement/default restoration, nonblocking
reentry, nested tasks, and select/forward/reverse DNS cancellation. The complete
Win16 host suite ran **112/112 PASS**. This does not emulate segmented pointers,
Win16 loader, DPMI, or Windows scheduling.

Open Watcom compiled the provider and `apitest.c`, which starts a real second
Win16 task. Run `C:\NET\WIN16\APITEST.EXE` with no argument; both `APIA.LOG`
and `APIB.LOG` must end in `FINAL PASS`. TaskA's blocking hook dispatches TaskB,
rejects reentry and cancels; after TaskA cleans up and exits, TaskB must retain
its socket, database result, and working transport. This client is linked with
the toolchain's `winsock.lib`, `windows.lib` and `clibl.lib`. It is separate from
the normal payload, so profile OFF and default USOSPKT are unchanged.

The first VM-ready diagnostic provider is pinned by the runtime receipt
`wrapper-build/provider02/build.json`: 194558 bytes, SHA256
`2d315e6ede384dc2a98fcdc723baf69a4497ea2edbb7afda6ca83294010e2a3c`.
Independent NE inspection found code 41494 bytes, FAR data segments
65520/65520/18720 bytes, and DGROUP including heap/stack reserve 7236 bytes.
Each segment remains within the 64KiB limit. Actual Windows VM results are
recorded separately in the stage3 report; compilation/host tests alone are
not a Windows PASS.
