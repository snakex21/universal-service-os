pub const Function = *const fn () bool;

pub const Case = struct {
    name: []const u8,
    run: Function,
};
