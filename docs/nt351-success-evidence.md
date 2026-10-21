# Read-only NT351 success evidence and bounded DHCP capture

Integration from `fix/nt351-net` commit `a53c8adc` into the coverage runner
based on `e0fac76d`. No VM was started for this integration. Existing R16
and R17 plans have neither new flag, so do not inherit a network PASS or
new payloads from it.

The explicit `collect_nt351_success` case flag permits a stopped-target,
read-only collector before cleanup, even without an installer failure.
It accepts only explicitly keyless `Windows NT 3.51` / `Windows NT 3.51
Server` fixtures under the owned collection VM directory. Exactly five
own files from `USOS/NT3` may leave the guest: `NET351.STATUS`, `NET351.ON`,
`USABILITY.TXT`, `POST.LOG`, `USOSNET351.SHA256`. The collector also returns
the read-back SHA256 of the own installed driver; it exports no OS files,
registry hives, answers or native screens. Unexpected paths, duplicates,
links, binary/invalid UTF-8 data and oversized archives fail closed before
writing evidence. File/status presence never becomes a runtime PASS.

The additional `capture_nt351_network` flag requires this collector and
the sole pinned igb netdev/MAC. It mirrors only that VM netdev to a local
passive TCP receiver. Stored PCAP is capped at 8 MiB including headers;
after reaching the cap the receiver continues draining without storing.
Metadata is capped at 64 KiB. No host interface is captured or polled.

The analyzer correlates ordered DHCP Discover/Offer/Request/ACK by MAC,
transaction ID, offered/requested address, server identifier and lease,
after the request to start the prepared disk. That boundary does not by
itself prove attribution to Windows: an earlier Linux guest also has the
same NIC. Require the actual Windows log, matching address and own driver
hash. DHCP exchange alone never yields ICMP or DNS PASS.

Python 3.13 also waits for active transports in `Server.wait_closed()`.
Cleanup therefore first bounds the receiver task wait and closes/cancels
an orphan connection before awaiting listener closure. A real localhost
test holds a client open and verifies finish cannot block indefinitely.
Capture starts only after USB fixture and command preflight; failed
process creation also closes it.

Validation: 15 NT351 evidence tests and 72 existing coverage tests PASS.
The evidence test's optional `USOSNET351_TEST_DRIVER` points to the locally
built own driver when the runner checkout has no build artifact. Actual
guest tar/base64 logic is exercised with mock mtools and the real own
driver hash; no VM or physical disk is involved.

This prepares collection for the fresh coherent NT351 test. It does not
establish an installed desktop, active DHCP lease, matching ping/DNS,
USB keyboard/mouse reconnect, USB mass storage or X470 compatibility.
