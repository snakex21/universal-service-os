# Fresh NT3.5 Workstation canonical IRQ qualification

Prepared from fix/nt35-net-irq cf8f7ca0, following the own NT351 fresh method 664d721e. No full build is needed: actual existing 16384-byte d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85 SYS is pinned.

The immutable R20 cache B261020-200536-968CCBE8-nt35-net1 (initrd 8bfc9d006670aeb05970383cde2e14da709dd28646f3ed66537fd0f81c6b1790) is copied to private B261020-200536-968CCBE8-nt35-irq-fresh01. Only effective USOSNET35.SYS and USOSNET35.SHA256 differ; all other 835 effective entries and all other files remain identical, original compressed prefix retained. New initrd f51137a7d9cecfa7e554c58485446533ee34bcab285ee54827b2aeabdc68c3fa. Frozen post helper 8ab10c79 and strict DNS logger ff258504 remain unchanged. No policy helper is added.

Original R20 archive e63ce7b63906cfad0b705200ca8f1318d8620d88370ab26ce5ba6fbe8bdd5236 supplies exact ISO 109d2c28e3d774e01987434b11c622fbf336e01f28eec2eafe40544f166852d1. Normal USOS installation starts a new blank standalone 4GiB target. Plan changes tag, permits explicit PS/2, and adds the actual candidate digest metadata. q35/i8042 hardware remains enabled; this is not a new USB isolation test. d94 USB isolation is qualified separately by nt35-irq-usb01.

Private coverage harness is snapshotted from macierz-windows at preparation, with root paths relocated and only NT35 collector expected digest updated. Outer observation scripts are exact R20 c0c5ab26 versions. ConsoleMode plus isatty is required before resource/VM work; PIPE and Windows NUL refuse. Normal 2048MiB+8GiB reserve guards apply. Passive exact future endpoint and image-creation notifications precede start. All VM images stay under G:\USOS-Kolekcja. No shared cache/USB/hub/physical device is changed.

At preparation, runtime remained pending until actual Program Manager, native DHCP release/renew, native ping, strict guest DNS/HTTP, native running-service observation, native safe shutdown, process completion, and stopped installed SYS readback. Server/Browser policy is assessed separately and not modified in this experiment.

## Completed nt35-irq-fresh01

Fresh normal USOS **PASS**: exact R20 media and blank standalone 4GiB target reached Program Manager / Windows NT Workstation Version3.5. Prepared-target notice2633.10s; elapsed3543.99s. Native safe Shutdown operator17, QMPquit, process0/QEMU0 and cleanup completed. No VM/listener remains.

Actual installed **d94 SYS/16384B** matched both the own stopped collector and independent bounded FAT readback. Target SHA256 `3b76f15ac5eeb410ee3ca21711ef4a8f34729e3a9082427b3e849fb9586e4c6b`; clean SYSTEM REGF1.2/current=default1 SHA256 `881147a22ccac179837d89524d48cd9b28cdc57a3f1244b568c495e0319ae2fc`. Original/private cache hashes were verified unchanged after runtime, except the declared two-entry overlay. Original MS bytes remained RAM/owned whole G images; temporary whole raw disk was removed.

LAN **PASS**: native release/renew and ipconfig show MAC52:54:00:55:53:01, DHCP10.0.2.15/255.255.255.0, gateway10.0.2.2, configured DNS10.0.2.3; native ping3/3 all<10ms; guest strict ICMP echo_match1/rtt0ms. Frozen ff258504 logger matched **fixed DNS** UDP1.1.1.1=30ms, UDP8.8.8.8=40ms, TCP1.1.1.1 connect21ms. Native gethostbyname succeeded40/20/60ms; 68k.news HTTP200/connect130ms/4095B. This logger does not prove a strict configured10.0.2.3 response. GatewayUDP53(no reply3000ms), gatewayTCP80(timeout4005ms), FrogfindHTTP(timeout4006ms) remain negative. HTTP is an own logger result, not an IE page.

48,257B/184-frame bounded VM-only capture has two correlated lease exchanges and four matched ICMP request/reply pairs. Strict same-XID DORA remains false: original NT35 changes XID between OFFER and REQUEST; complete original decoded metadata is preserved, not relabelled. PCAP alone is not the guest PASS.

Fresh **Client/noSharing FAIL**, unchanged by this experiment: native Computer Browser/Server RUNNING; stopped Browser/ServerStart2Type32, Workstation2/32, Tcpip3/1. RasMan/RasAcd/RemoteAccess selected names absent, not complete Dial-Up absence proof. Parent separately owns a completed diagnostic policy overlay; this fresh driver-only qualification is not freshAUTO policy PASS. PS/2 baseline is explicit; separate d94 USB01 proof is not retested here. Old R20 first2/3 and ~2s warm results remain unchanged.

Evidence: `artifacts/coverage/nt35-irq-fresh01/guest-evaluation.json`, its append-only `guest-evaluation-addendum.json`, `stopped-readback.json`, `pcap-completed-analysis.json`; runtime/frames/own logs `artifacts/coverage/vm/nt35-irq-fresh01`. The addendum clarifies seven selected service names and deduplicates two retained stick hardlinks. Actual unique retained data741097472B (target/vars/stick); name-size sum1239171072B counts the duplicate link twice. No active image contents were read for retention. Machine-readable committed proof: `docs/nt35-fresh-irq-runtime-evidence.json`.
