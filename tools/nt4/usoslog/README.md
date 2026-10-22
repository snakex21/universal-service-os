Own isolated NT4 logger qualification fork

The source snapshot derives from the independently reproducible ff258504
NT3 logger, with its strict DNS peer/ID/question/answer parser unchanged.
Only the NT4 global Tcpip Parameters NameServer/DhcpNameServer fallback is
added when API/adapter DNS configuration supplied no usable server.
The source and binary hashes are in source.json. Existing NT3 and 9x source
trees and payloads are unchanged. A native VM test is required separately.

Build with the pinned portable OpenWatcom ow-bac354f3c75f and build.py.
Build/cache/tmp files stay in the requested artifacts folder. Runtime data
stay beside the executable or in the explicit /out path; no profile fallback.
The executable remains PE3.10 GUI and keeps the existing 71 NT4 imports.

GPL-3.0-or-later; original own USOS copyright notices remain in the sources.
