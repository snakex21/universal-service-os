//! Test-only regular-file backend. Never accepts a Windows device path.
const std = @import("std");
const platform = @import("platform.zig");
const app = @import("app.zig");
const ntfs = @import("ntfs.zig");
const partitions = @import("partitions.zig");
const identity = @import("identity.zig");
const builtin = @import("builtin");
pub const File = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    pub fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *File = @ptrCast(@alignCast(ctx));
        if (offset > self.size or out.len > self.size - offset) return error.Bounds;
        const count = self.file.readPositionalAll(self.io, out, offset) catch return error.Io;
        if (count != out.len) return error.Io;
    }
    pub fn write(ctx: *anyopaque, offset: u64, input: []const u8) platform.Error!void {
        const self: *File = @ptrCast(@alignCast(ctx));
        self.file.writePositionalAll(self.io, input, offset) catch return error.Io;
    }
    pub fn flush(ctx: *anyopaque) platform.Error!void {
        const self: *File = @ptrCast(@alignCast(ctx));
        self.file.sync(self.io) catch return error.Io;
    }
    fn source(self: *File) ntfs.Source { return .{ .context = self, .size = self.size, .read_fn = read }; }
};
pub const Output = struct {
    io: std.Io,
    pub fn write(_: *anyopaque, text: []const u8) void { std.debug.print("{s}", .{text}); }
    pub fn clock(ctx: *anyopaque) u64 {
        const self: *Output = @ptrCast(@alignCast(ctx));
        return @intCast(@max(0, std.Io.Clock.awake.now(self.io).toSeconds()));
    }
};
pub fn open(io: std.Io, path: []const u8, writable: bool) !File {
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = if (writable) .read_write else .read_only });
    errdefer f.close(io);
    const info = try f.stat(io);
    if (info.kind != .file) return error.InvalidArgument;
    return .{ .io = io, .file = f, .size = info.size };
}
pub fn validateAbsolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or path.len < 4 or std.mem.indexOfAny(u8, path, "\r\n\x00") != null or std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//")) return error.InvalidArgument;
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, path[2..], ':') != null) return error.InvalidArgument;
    var components = std.mem.tokenizeAny(u8, path, "\\/");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return error.InvalidArgument;
}
pub fn inside(workspace: []const u8, path: []const u8) bool {
    if (path.len <= workspace.len) return false;
    const equal = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(workspace, path[0..workspace.len]) else std.mem.eql(u8, workspace, path[0..workspace.len]);
    return equal and (path[workspace.len] == '/' or path[workspace.len] == '\\');
}
pub fn ownedPath(io: std.Io, allocator: std.mem.Allocator, workspace: []const u8, path: []const u8) ![:0]u8 {
    try validateAbsolute(path);
    const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
    errdefer allocator.free(canonical);
    if (!inside(workspace, canonical)) return error.InvalidArgument;
    return canonical;
}
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit(); _ = args.next();
    const path = args.next() orelse return error.MissingImage;
    const mode = args.next() orelse return error.MissingMode;
    const small_path = args.next() orelse return error.MissingSmallFixture;
    const large_path = args.next() orelse return error.MissingLargeFixture;
    const ack = args.next() orelse return error.MissingImageOnlyAcknowledgment;
    const workspace_arg = args.next() orelse return error.MissingWorkspace;
    const workspace = args.next() orelse return error.MissingWorkspace;
    if (args.next() != null or !std.mem.eql(u8, ack, "--image-only") or !std.mem.eql(u8, workspace_arg, "--workspace")) return error.InvalidArgument;
    try validateAbsolute(workspace);
    const workspace_real = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, workspace, init.gpa);
    defer init.gpa.free(workspace_real);
    var root_len = workspace_real.len;
    while (root_len > 0 and (workspace_real[root_len - 1] == '/' or workspace_real[root_len - 1] == '\\')) root_len -= 1;
    if (root_len < 3) return error.InvalidArgument;
    const image_real = try ownedPath(init.io, init.gpa, workspace_real[0..root_len], path);
    defer init.gpa.free(image_real);
    const small_real = try ownedPath(init.io, init.gpa, workspace_real[0..root_len], small_path);
    defer init.gpa.free(small_real);
    const large_real = try ownedPath(init.io, init.gpa, workspace_real[0..root_len], large_path);
    defer init.gpa.free(large_real);
    if (!std.mem.endsWith(u8, image_real, ".raw") or std.ascii.eqlIgnoreCase(image_real, small_real) or std.ascii.eqlIgnoreCase(image_real, large_real)) return error.InvalidArgument;
    const kind = std.meta.stringToEnum(partitions.Kind, mode) orelse return error.InvalidArgument;
    // Fail before any writable handle, target write or persistent log.
    var entropy: [64]u8 = undefined;
    try init.io.randomSecure(&entropy);
    const ids = try identity.Identifiers.fromEntropy(entropy);
    var image = try open(init.io, image_real, true); defer image.file.close(init.io);
    if (image.size < 128 * 1024 * 1024 or image.size > 256 * 1024 * 1024 * 1024 or image.size % 512 != 0) return error.InvalidArgument;
    var small = try open(init.io, small_real, false); defer small.file.close(init.io);
    var large = try open(init.io, large_real, false); defer large.file.close(init.io);
    var output = Output{ .io = init.io };
    var tracked = platform.TrackedAllocator{ .backing = init.gpa, .limit = 4 * 1024 * 1024 };
    const disk: platform.Disk = .{ .context = &image, .sectors = image.size / 512, .read_fn = File.read, .write_fn = File.write, .flush_fn = File.flush };
    std.debug.print("ENTROPY source=host-os-csprng bytes=64 no-fallback\n", .{});
    app.run(disk, kind, ids, &tracked, .{ .small = small.source(), .large = large.source() }, .{ .context = &output, .write_fn = Output.write, .clock_fn = Output.clock }) catch |err| {
        std.debug.print("USOSPREP ERROR {s} alloc_current={d} alloc_peak={d}\n", .{ @errorName(err), tracked.current, tracked.peak });
        return 1;
    };
    std.debug.print("HOST regular-file backend complete; current={d} peak={d}\n", .{ tracked.current, tracked.peak });
    return 0;
}

test "portable workspace requires an absolute child regular-file path" {
    try validateAbsolute(if (builtin.os.tag == .windows) "R:\\portable\\images" else "/portable/images");
    try std.testing.expectError(error.InvalidArgument, validateAbsolute("relative/image.raw"));
    try std.testing.expectError(error.InvalidArgument, validateAbsolute("\\\\.\\PhysicalDrive0"));
    try std.testing.expectError(error.InvalidArgument, validateAbsolute(if (builtin.os.tag == .windows) "R:\\portable\\..\\outside" else "/portable/../outside"));
    try std.testing.expect(inside("/portable/images", "/portable/images/target.raw"));
    try std.testing.expect(!inside("/portable/images", "/portable/images-other/target.raw"));
    try std.testing.expect(!inside("/portable/images", "/portable/images"));
}
