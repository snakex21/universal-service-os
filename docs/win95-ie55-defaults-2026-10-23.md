# Requested blank home page after an original IE upgrade

On Windows95 the existing LAN helper replaced the requested `about:blank`
with its adjacent `START.HTM` for every browser version. That fallback was
needed by the original IE3, including its SHDOCVW file version4.70, but it
also overrode the requested blank page after installing IE5.5.

The helper now retains `about:blank` when the installed product's
`HKLM\Software\Microsoft\Internet Explorer\Version` is a numeric dotted
IE5/6 version. Missing, malformed and older versions retain the existing
local fallback. Explicit HTTP/HTTPS home pages and other OS paths keep
their existing behavior. The pre-Setup REG95 conversion is unchanged;
post-package policy still uses the existing explicit `/refresh` action.

Five selected host tests pass. The real C policy test checks an adjacent
legacy page against missing version, SHDOCVW-style4.70, IE5.50, IE6.00,
malformed values, a user-selected HTTP page and a non95 configuration.
The registry reads are stubbed; no target entry or OS policy runs on the
host. The last test assertion cleanup was followed by the focused C test,
which also passes.

Dependency: `fix/win95-lan-handoff`, commit4a2c2c6e, so completed source950
native QEMU can reach the same desktop policy. Browser runtime PASS and
the actual Favorites folder are pending. No Microsoft binaries are
included in this branch. The original IE5.5 SP2 offline test media and
their independently verified Microsoft Authenticode signatures reside
only in the user-approved private K VM directory.
