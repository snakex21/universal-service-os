// Host entry point keeps the module root at src/ for answer policy imports.
comptime {
    _ = @import("flow/answer/network_defaults.zig");
}
