//! usos-win3x-display: host front end of src/compat/win3x (the tool the
//! micro-Linux runs as `usos-fb-ui --win3x-display DIR`), for the host tests
//! (tools/tests/legacy_bios/test_win3x_display_tool.py).
//!
//!   usos-win3x-display patch-dir DIR      patch a staged WINSETUP folder
//!   usos-win3x-display expand IN OUT      SZDD / KWAJ / plain -> OUT
//!   usos-win3x-display nt35-initial IN OUT
//!                                         NT 3.5 INITIAL.IN_ processor line
//!                                         (micro-Linux: usos-fb-ui --nt35-initial)
//!   usos-win3x-display nt4-kernel IN OUT
//!                                         NT 4.0 RTM kernel CPUID leaf limit
//!                                         (micro-Linux: usos-fb-ui --nt4-kernel)
//!   usos-win3x-display nt3-cab-get CAB OUT | nt3-cab-put CAB FILE OUT
//!                                         one-file NT 3.5x cabinet (micro-Linux:
//!                                         usos-fb-ui --nt3-cab-get / --nt3-cab-put)
//!   usos-win3x-display w9x-mini SETUPDIR HELPERDIR|-
//!                                         Windows 9x Setup MINI.CAB (the
//!                                         micro-Linux runs it as
//!                                         `usos-fb-ui --w9x-setup-mini`)
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
    if (std.mem.eql(u8, command, "w9x-mini")) {
        const setup_dir = args.next() orelse return usage();
        return win3x.w9x_mini.run(io, init.gpa, setup_dir, args.next() orelse return usage());
    }
    if (std.mem.eql(u8, command, "nt35-initial")) {
        const in_path = args.next() orelse return usage();
        return win3x.nt35_initial.run(io, init.gpa, in_path, args.next() orelse return usage());
    }
    if (std.mem.eql(u8, command, "nt4-kernel")) {
        const in_path = args.next() orelse return usage();
        return win3x.nt4_kernel.run(io, init.gpa, in_path, args.next() orelse return usage());
    }
    if (std.mem.eql(u8, command, "nt3-cab-get")) {
        const cab_path = args.next() orelse return usage();
        return win3x.nt3_cab_file.runGet(io, init.gpa, cab_path, args.next() orelse return usage());
    }
    if (std.mem.eql(u8, command, "nt3-cab-put")) {
        const cab_path = args.next() orelse return usage();
        const file_path = args.next() orelse return usage();
        return win3x.nt3_cab_file.runPut(io, init.gpa, cab_path, file_path, args.next() orelse return usage());
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
