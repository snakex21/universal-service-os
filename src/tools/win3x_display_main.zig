//! usos-win3x-display: host front end of src/compat/win3x (the tool the
//! micro-Linux runs as `usos-fb-ui --win3x-display DIR`), for the host tests
//! (tools/tests/legacy_bios/test_win3x_display_tool.py).
//!
//!   usos-win3x-display patch-dir DIR      patch a staged WINSETUP folder
//!   usos-win3x-display expand IN OUT      SZDD / KWAJ / plain -> OUT
const std = @import("std");
const usos = @import("usos");
const win3x = usos.win3x;

fn usage() u8 {
    std.debug.print("usage: usos-win3x-display patch-dir DIR | expand IN OUT\n", .{});
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return usage();
    if (std.mem.eql(u8, command, "patch-dir")) {
        return win3x.display_run.run(io, init.gpa, args.next() orelse return usage());
    }
    if (std.mem.eql(u8, command, "expand")) {
        const in_path = args.next() orelse return usage();
        const out_path = args.next() orelse return usage();
        const cwd = std.Io.Dir.cwd();
        const raw = try cwd.readFileAlloc(io, in_path, init.gpa, .limited(4 * 1024 * 1024));
        defer init.gpa.free(raw);
        const body = try win3x.lz.expand(init.gpa, raw);
        defer init.gpa.free(body);
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = body });
        return 0;
    }
    return usage();
}
