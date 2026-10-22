# Fresh NT3.5 Workstation canonical IRQ qualification

Prepared from fix/nt35-net-irq cf8f7ca0, following the own NT351 fresh method 664d721e. No full build is needed: actual existing 16384-byte d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85 SYS is pinned.

The immutable R20 cache B261020-200536-968CCBE8-nt35-net1 (initrd 8bfc9d006670aeb05970383cde2e14da709dd28646f3ed66537fd0f81c6b1790) is copied to private B261020-200536-968CCBE8-nt35-irq-fresh01. Only effective USOSNET35.SYS and USOSNET35.SHA256 differ; all other 835 effective entries and all other files remain identical, original compressed prefix retained. New initrd f51137a7d9cecfa7e554c58485446533ee34bcab285ee54827b2aeabdc68c3fa. Frozen post helper 8ab10c79 and strict DNS logger ff258504 remain unchanged. No policy helper is added.

Original R20 archive e63ce7b63906cfad0b705200ca8f1318d8620d88370ab26ce5ba6fbe8bdd5236 supplies exact ISO 109d2c28e3d774e01987434b11c622fbf336e01f28eec2eafe40544f166852d1. Normal USOS installation starts a new blank standalone 4GiB target. Plan changes tag, permits explicit PS/2, and adds the actual candidate digest metadata. q35/i8042 hardware remains enabled; this is not a new USB isolation test. d94 USB isolation is qualified separately by nt35-irq-usb01.

Private coverage harness is snapshotted from macierz-windows at preparation, with root paths relocated and only NT35 collector expected digest updated. Outer observation scripts are exact R20 c0c5ab26 versions. ConsoleMode plus isatty is required before resource/VM work; PIPE and Windows NUL refuse. Normal 2048MiB+8GiB reserve guards apply. Passive exact future endpoint and image-creation notifications precede start. All VM images stay under G:\USOS-Kolekcja. No shared cache/USB/hub/physical device is changed.

Runtime remains pending until actual Program Manager, native DHCP release/renew, native ping, strict guest DNS/HTTP, native running-service observation, native safe shutdown, process completion, and stopped installed SYS readback. Server/Browser policy is assessed separately and not modified in this experiment.
