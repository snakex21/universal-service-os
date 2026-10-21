# Windows 95 phase-one waiting — runtime pending

The previous common controller samples disk writes/process state every five
seconds and periodically captures the screen. Keyed Windows 95 now dispatches
to its own blocking RFB receiver. A missing receiver/library fails closed;
the NT controller path is unchanged.

The receiver accepts only the owned QEMU reverse connection. It keeps one
incremental request outstanding, blocks on its reply, then rearms after an
actual framebuffer update. There is no timer-driven status, disk or QMP
query. Only classified page roles leave the receiver; frame pixels stay in
RAM and are erased on normal release. Existing per-page key/owner guards and
the separate unlogged key monitor are retained. Child exit and timeout are
events on a pipe, followed by `wait`.

The existing static-label classifier is shared by the PPM tool and receiver.
Nine host RFB tests cover malformed/truncated input, wire bounds, resize,
unsupported encodings, colour reconstruction, role-only output/private-field
updates and absence of repeated requests while waiting. Ten
FAT16 tests, eight page-input tests and the two affected fake-VM controller
tests pass. The earlier real-QEMU smoke result is withdrawn: its harness
could mistake an echoed PASS command for success after a failure.

The first fresh RTM fixture (768 MiB outer / 128 MiB inner) stopped before
the nested installer because micro-Linux supplies BusyBox without a
`timeout` symlink. The controller now invokes the available BusyBox applet
when needed. Preparation did not restart after this failure. The stopped
target independently proves actual FAT16 formatting: active type 06,
2047 MiB C:, 32 KiB clusters, representable CHS matching LBA.

The next test uses 2 GiB outer / 512 MiB inner RAM. The user explicitly
reserved two QEMU engines and allowed a 6 GiB host RAM reserve for this
session. The shared task file subsequently raised the physical machine's
global allowance to five engines: two here and three in the other session.

After fixing that harness on `fix/win95-fixture-serial`, RTM r14 passed the
normal menu and target preparation but nested QEMU exited after one second:
VNC required `keymaps/en-us`, absent from the minimal QEMU initrd. The
builder now pins Alpine's matching `qemu-11.0.3-r0.apk` and includes only
that map (SHA-256 `56c6e878253d8e84cf75d8642aeaa0ba156bea7504c4d4029acb17432cfa70ee`;
no include directives). Missing runtime data rejects the package and the
95 controller fails before starting QEMU. The NT controller remains
unchanged. A replacement nested smoke uses a script in initrd and an exact
completion line. It passed with both real engines in 10.303 s, no UART
command upload, clean exit and the exact marker after the receiver's
successful termination. This is RFB infrastructure evidence only.

Private inputs originate in the separately measured
`B261020-200536-968CCBE8-win95-fat16` cache. Its 283 other files and 825
unmodified initramfs entries were compared to the declared older NT4 cache;
the three FAT16 replacements match their manifest and local source/helper.
That mixed cache is not a full build of this branch. Runtime test adapters
are a separately attributed snapshot of coverage commit `e0fac76d`, with
private disk retention, selected RAM reserve, and page-role serial
notifications. No driver, firmware, Windows source or key value was changed
by the waiting-controller fixture.

Fresh Windows RTM/OSR1 desktop, second boot, USB-only functional HID and
storage, and real DHCP/gateway/DNS evidence are still pending. No physical
disk, hub/USB driver source, release build, merge, push or deployment was
performed.

The blocking incremental-update semantics are visible in the
[QEMU VNC implementation](https://github.com/qemu/qemu/blob/v9.2.0/ui/vnc.c)
(`vnc_update_client` / `framebuffer_update_request`).
