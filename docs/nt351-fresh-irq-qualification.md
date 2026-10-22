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

Runtime result is pending. Cache creation, hashes and host checks are not a
fresh Windows installation PASS. Historical R22 approximately 2 second ping
latency and R25 no-IRQ failure remain preserved.
