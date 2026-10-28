pub const SystemFamily = enum {
    windows,
    windows_legacy,
    windows_beta,
    linux,
    dos,
    /// Custom OS (src/catalog/other_systems.zig).
    other,
    utility,
};
