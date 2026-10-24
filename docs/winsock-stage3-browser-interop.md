# Win16 browser interoperability, stage 3

Original Netscape Navigator 3.04 and Opera 3.62 request enabled zero-time
`SO_LINGER`. The provider now implements this as an abortive close: the
engine attempts RST, frees the socket and never waits for graceful FIN.
The wrapper invalidates that application's socket even if the best-effort
RST cannot be queued. A full transmit queue reports `WSAENOBUFS`; missing
cached link-layer reachability reports the mapped engine error. This does
not promise RST delivery or retract packets already queued/on the wire.
Unrelated applications' queues and accepted sockets are preserved.
Positive enabled linger is still explicitly `WSAEOPNOTSUPP`.

Netscape registers all six Winsock event bits. Registration accepts `FD_OOB`
alongside the implemented ordinary read/write/connect/close/accept events.
TCP urgent data and actual `FD_OOB` notifications are not implemented; this
is not an OOB interoperability claim. The browser's ordinary HTTP does not
use urgent data. Diagnostics remain compile-time optional and write beside
the provider fixture, under `C:\NET\WIN16`, never the host profile.

Both original browsers render `http://www.68k.news/` in Windows 3.1 PL
enhanced mode with provider09. Netscape uses `Use Async DNS=no`, a normal
setting explicitly suggested in the vendor's original INI for Winsock
problems. Its asynchronous DNS application interoperability remains open;
native asynchronous API tests are recorded separately. Opera uses its
ordinary Evaluate button, with the unmodified trial executable and visible
unregistered state. No registration data or application patch is used.

The application fixture's one-shot dialog actions use an exact caption or
an explicit original dialog control ID. At most three bounded keyboard
actions are also supported. These are functional actions, not progress
queries. Each QEMU case uses a disposable overlay of the installed base,
then one final capture and a closed-PCAP review. A window title alone is
never a rendering verdict.
