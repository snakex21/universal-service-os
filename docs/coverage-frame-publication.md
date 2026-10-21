# Preserve initial and final frame evidence

The coverage runner previously saved a second screenshot over endpoint.png
after interactive actions. Thus a completed desktop run could leave only
its final safe-shutdown screen at the original endpoint path. In completed
R20, the manual desktop assessment reference was corrected to operator12;
its former JSON was preserved. Actual desktop/guest-network observations
and original runner outputs were not rewritten.

Future runs keep endpoint.png and final.png separately. Capture refuses
existing PNG, staging or PPM paths before requesting a screenshot. It
encodes/closes a temporary PNG, then atomically creates the new destination
with a same-directory hard link; a competing destination fails without
overwrite. Directory creation notifications therefore publish complete
PNG bytes. Scratch is removed after completion or error. These paths are
owned test outputs, not guest configuration or physical target media.

Four host tests exercise actual capture with synthetic QMP frames: complete
publication, distinct initial/final frames, existing-path rejection and
destination-race preservation. No Windows/USB/network runtime result is
inferred from those host tests. Already running imported modules remain
their startup version; this change is for subsequent runs.
