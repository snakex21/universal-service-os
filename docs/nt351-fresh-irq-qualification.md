# Fresh NT 3.51 canonical IRQ qualification

This case starts normal USOS from the actual menu and a new blank 4 GiB
target. It does not reuse the installed R26/R27 overlay. The source and
keyless profile are the exact R22 Workstation EN inputs (archive SHA256
24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975;
ISO b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c).
PS/2 remains permitted, exactly as in R22; this is not another USB isolation
or physical hardware qualification.

The immutable R22 net3 cache initrd f958da5146114f210d5a738a55f8711d56b204c0adcaf0957ebf03e810cb772c
is preserved as a byte-identical prefix. One fourth gzip/newc layer replaces
exactly two effective entries: `usr/lib/usos/nt3/USOSNET351.SYS` and its
SHA256 sidecar. All other 830 effective entries, all modes/link targets,
all other cache files and the separate qemu9x package remain identical.
The original net3 cache is unchanged. New initrd SHA256:
2540baab9efb257396fc21d58a3572f9a774bf2212593ea37ad25e61c4a8d820.

The already built own SYS is 17024 bytes, SHA256
f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf.
Its only source change is the canonical ICR/IMS/IMC/IAM register constants;
the canonical build graph already has nine passing host checks. No unrelated
component was rebuilt. Three new host cases reject unrelated effective-tree
data/mode changes, missing/extra paths and an ineffective replacement.

Private cache: `G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt351-irq-fresh01`.
Case tag: `nt351-irq-fresh01`; each original-media input/whole disk stays on
G. The private harness snapshot changes its own collector digest and root
path resolution; plan fields differ from R22 only in tag and expected SYS.
Its guest observation scripts come from exact R22 tester commit ec60b10c.
Creation-event subscribers retain owned disk hard links without reading the
active images. The normal fixture guard requires 8 GiB host memory reserve.

The endpoint is one frame 300 seconds after normal USOS reports the prepared
target, with a 10800 second overall limit. All waits use blocking completion
or exact future file notifications; no progress polling is authorized.
After visual desktop assessment, native DHCP renewal/ping and the strict
guest DNS/HTTP logger are required, followed by native safe shutdown and
stopped readback of the own SYS. Native `net start` and bounded stopped
Browser/LanmanServer/LanmanWorkstation/Tcpip state are a separate
Client/noSharing policy observation; policy is not modified in this IRQ case.

Completed on 22 October 2026: **fresh normal installation and fast native LAN
PASS; Client/noSharing policy FAIL**. The target was a new standalone blank
4 GiB qcow2, with no backing image. Actual menu/profile/disk confirmations
completed, then native Program Manager/Workstation Version 3.51 appeared.
The normal-flow prepared-target notice occurred at 1228.76 seconds; the
single planned initial frame was captured 300 seconds later.

Native `ipconfig /release`, `/renew` and `/all` verified DHCP 10.0.2.15/24,
gateway 10.0.2.2 and DNS 10.0.2.3. Standard native ping returned three of
three replies, each `time<10ms`. The unchanged explicit guest logger measured
matching ICMP RTT 0 ms, strict UDP DNS replies in 40/51 ms, strict TCP DNS
in 20 ms, native frogfind resolution in 90 ms and 68k.news HTTP 200 with a
130 ms connection. Its one completed snapshot and the native output remain
separate evidence. Gateway UDP53/TCP80 and frogfind HTTP timeouts remain;
they are not removed from the result.

The completed bounded capture contains 172 frames/38921 bytes. Fresh boot
and explicit renewal each have a correlated Discover/Offer and Request/ACK,
but original NT351 switches transaction ID between those pairs. Strict
same-XID DORA therefore remains **false**. Four checksum/identity-matched
ICMP pairs correlate the three native pings and the strict guest probe.

`net start` genuinely listed **Computer Browser and Server running**, along
with DHCP Client/Workstation. The clean stopped REGF1.2 SYSTEM has
Current=Default=1, Browser Start2/Type32, LanmanServer Start2/Type32,
LanmanWorkstation Start2/Type32 and Tcpip Start3/Type1. Thus the requested
Client/noSharing policy fails independently of the successful IRQ/LAN test.
This case never stops or reconfigures those services. Its four-service
reader exports only these allowlisted DWORDs; the Microsoft hive stays in
RAM/whole disk on G. A separately built policy helper and separate overlay
apply/cold-boot qualification must follow; this fresh cache stays immutable.

Native shutdown reached the safe-power-off page (`operator-16.png`), then
QMP quit and parent TTY2659 both exited 0. The stopped guest collector and
independent whole-disk FAT readback both verify the installed 17024-byte
f579 SYS. The outer QEMU argv is identical to R22 after normalization of
the case path and localhost ephemeral QMP/mirror ports only. Every old
cache file and every unrelated private-cache file was rehashed unchanged
after runtime. No full rebuild, cache mutation, physical write, original
Windows binary/hive export or progress polling occurred.

Retained target:
`G:\USOS-Kolekcja\_vm\nt351-irq-fresh01\target-retained.qcow2`, SHA256
cb9d664615260a2e6b3c8e618be19b9cf785696019f41753b1461d3754b1196c.
Target 204865536 B, stick 512557056 B and vars 540672 B remain on G
(717963264 B total). The new scratch whole-disk readback image was removed
only after checking its exact absolute owned path; the retained source is
unchanged. The separately blocked old macOS cleanup was never retried.

Reviewable evidence is under `artifacts/coverage/nt351-irq-fresh01/` and
`artifacts/coverage/vm/nt351-irq-fresh01/`. Six new host cases pass (three
cache-delta and three bounded-policy cases), and completed assessment checks
pass for argv, cache immutability, standalone disk, native tests, capture and
both actual driver readbacks. This case retains R22 PS/2 input allowance;
USB out/in remains independently qualified by R27, not repeated here.
Historical R22 approximately 2 second ping latency and R25 no-IRQ failure
remain preserved. No NT351 Server, physical I211/X470, general SMP or whole
USOS release qualification is added.
