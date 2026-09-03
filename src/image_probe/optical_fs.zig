const udf = @import("udf.zig");
const iso9660 = @import("iso9660.zig");

pub const Kind = enum {
    udf,
    iso9660,
};

pub const FileInfo = struct {
    size: u64,
    is_directory: bool,
    filesystem: Kind,
};

pub fn findPath(reader: anytype, path: []const u8) !?FileInfo {
    const udf_result = udf.findPath(reader, path);
    if (udf_result) |maybe_info| {
        if (maybe_info) |info| {
            return .{ .size = info.size, .is_directory = info.is_directory, .filesystem = .udf };
        }
        return null;
    } else |err| switch (err) {
        error.NotUdf => {},
        else => return err,
    }

    const iso_info = try iso9660.findPath(reader, path);
    if (iso_info) |info| {
        return .{ .size = info.size, .is_directory = info.is_directory, .filesystem = .iso9660 };
    }
    return null;
}

test "optical parser falls back to ISO9660 only when image is not UDF" {
    _ = @import("iso9660.zig");
    _ = @import("udf.zig");
}
