//! Common ISO -> WIM -> freshly formatted NTFS path, with no intermediate copy.
//! SPDX-License-Identifier: GPL-3.0-or-later
const o = @import("optical.zig");
const p = @import("platform.zig");
const partitions = @import("partitions.zig");
const identity = @import("identity.zig");
const app = @import("app.zig");
const wim_app = @import("wim_app.zig");

/// The caller must provide distinct source/target media regions and guard the
/// writable destination identity. The source contract exposes reads only.
pub fn run(disk: p.Disk, kind: partitions.Kind, ids: identity.Identifiers, tracker: *p.TrackedAllocator, source: o.Input, selected: u32, options: wim_app.Options, log: app.Logger) !void {
    const volume = try o.Volume.open(source);
    return runVolume(disk, kind, ids, tracker, &volume, selected, options, log);
}
pub fn runVolume(disk: p.Disk, kind: partitions.Kind, ids: identity.Identifiers, tracker: *p.TrackedAllocator, volume: *const o.Volume, selected: u32, options: wim_app.Options, log: app.Logger) !void {
    var stream: o.Stream = .{ .input = volume.input, .node = volume.findInstallWim() catch |err| {
        switch (err) {
            error.InstallEsdUnsupported => log.say("ISO_SOURCE_UNSUPPORTED install.esd requires solid-ESD source support; use an unsplit install.wim\n", .{}),
            error.InstallSwmUnsupported => log.say("ISO_SOURCE_UNSUPPORTED split install*.swm requires a multi-part source set; use an unsplit install.wim\n", .{}),
            error.NotFound => log.say("ISO_SOURCE_MISSING sources\\install.wim (no install.esd or install*.swm found)\n", .{}),
            else => {},
        }
        return err;
    } };
    if (stream.node.directory) return error.NotFile;
    log.say("ISO_WIM_SOURCE kind={s} revision={x} wim_size={d} intermediate_copy=false\n", .{ @tagName(volume.kind), volume.udf_state.revision, stream.node.size });
    wim_app.runWithOptions(disk, kind, ids, tracker, .{ .context = &stream, .size = stream.node.size, .read_fn = o.Stream.read }, selected, options, log) catch |err| {
        if (stream.last_error) |original| log.say("ISO_STREAM_ERROR original={s} mapped={s}\n", .{ @errorName(original), @errorName(err) });
        return err;
    };
    log.say("ISO_WIM_COMPLETE intermediate_copy=false wim_size={d}\n", .{stream.node.size});
}
