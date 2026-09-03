const Windows11Status = @import("windows_11_status.zig").Windows11Status;

pub const MediaStatus = struct {
    windows_11: Windows11Status = .{},
    program_files: usize = 0,
};
