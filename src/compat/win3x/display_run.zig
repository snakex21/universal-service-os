//! `usos-fb-ui --win3x-display DIR` (micro-Linux, tools/dos_csmwrap_target.sh)
//! and the host tool `usos-win3x-display`: patch the display driver(s) and
//! the VGA startup logo in a staged Windows 3.x Setup folder (WINSETUP)
//! before Setup runs, in the container the media uses (plain, SZDD or
//! KWAJ), so Setup copies and expands the patched files itself and builds
//! WIN.COM from the patched VGALOGO.LGO.
//!
//! Unknown drivers and files that are already patched are left as they are;
//! every decision is logged (stderr and DIR/USOSDISP.TXT). A file is
//! replaced only after the result expanded again equals the patched file.
//! Exit: 0 done (also when nothing was patched), 2 usage, 3 I/O error.
const std = @import("std");
const lz = @import("lz.zig");
const patch = @import("display_patch.zig");
const table = @import("display_table.zig");

pub const log_name = "USOSDISP.TXT";
const max_file = 1024 * 1024;

const Target = struct { name: []const u8, logo: bool };
const targets = [_]Target{
    .{ .name = "VGA.DRV", .logo = false },
    .{ .name = "VGA.DR_", .logo = false },
    .{ .name = "EGA.DRV", .logo = false },
    .{ .name = "EGA.DR_", .logo = false },
    .{ .name = "VGALOGO.LGO", .logo = true },
    .{ .name = "VGALOGO.LG_", .logo = true },
};

pub const Outcome = enum { patched, already, unknown, failed };

const Log = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,

    fn line(self: *Log, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[WIN3X_DISPLAY] " ++ fmt ++ "\n", args);
        const s = std.fmt.allocPrint(self.gpa, fmt ++ "\r\n", args) catch return;
        defer self.gpa.free(s);
        self.text.appendSlice(self.gpa, s) catch {};
    }
};

fn hexOf(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

/// The new file contents for one staged file, or null (logged why).
pub fn patchedFile(gpa: std.mem.Allocator, name: []const u8, logo: bool, raw: []const u8, log: anytype) ?[]u8 {
    const container = lz.kind(raw);
    const body = lz.expand(gpa, raw) catch |err| {
        log.line("{s}: cannot expand ({s}, {s}); left as is", .{ name, @tagName(container), @errorName(err) });
        return null;
    };
    defer gpa.free(body);
    const digest = patch.sha256(body);
    var label: []const u8 = "VGA startup logo";
    var sites: u16 = 3;
    const new_body = if (logo) patch.patchLogo(gpa, body) catch |err| {
        switch (err) {
            error.AlreadyPatched => log.line("{s}: logo already patched (sha256 {s})", .{ name, &hexOf(digest) }),
            else => log.line("{s}: logo helpers not found ({s}, sha256 {s}); left as is", .{ name, @errorName(err), &hexOf(digest) }),
        }
        return null;
    } else switch (patch.find(&table.plans, digest)) {
        .patched => |p| {
            log.line("{s}: {s} already patched", .{ name, p.label });
            return null;
        },
        .unknown => {
            log.line("{s}: unknown driver (sha256 {s}); left as is", .{ name, &hexOf(digest) });
            return null;
        },
        .plan => |p| blk: {
            label = p.label;
            sites = p.sites;
            break :blk patch.applyPlan(gpa, p, body) catch |err| {
                log.line("{s}: {s}: {s}; left as is", .{ name, p.label, @errorName(err) });
                return null;
            };
        },
    };
    defer gpa.free(new_body);
    const packed_file = lz.compressLike(gpa, raw, new_body) catch |err| {
        log.line("{s}: cannot store ({s}); left as is", .{ name, @errorName(err) });
        return null;
    };
    const check = lz.expand(gpa, packed_file) catch null;
    defer if (check) |c| gpa.free(c);
    if (check == null or !std.mem.eql(u8, check.?, new_body)) {
        gpa.free(packed_file);
        log.line("{s}: self-check of the stored file failed; left as is", .{name});
        return null;
    }
    log.line("{s}: {s} patched ({d} sites), {s}, sha256 {s} -> {s}", .{
        name, label, sites, @tagName(container), &hexOf(digest), &hexOf(patch.sha256(new_body)),
    });
    return packed_file;
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, path: []const u8) u8 {
    var log = Log{ .gpa = gpa };
    defer log.text.deinit(gpa);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
        log.line("cannot open {s}: {s}", .{ path, @errorName(err) });
        return 3;
    };
    defer dir.close(io);
    var status: u8 = 0;
    var seen: usize = 0;
    for (targets) |t| {
        const raw = dir.readFileAlloc(io, t.name, gpa, .limited(max_file)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                log.line("{s}: read error {s}; left as is", .{ t.name, @errorName(err) });
                continue;
            },
        };
        defer gpa.free(raw);
        seen += 1;
        const data = patchedFile(gpa, t.name, t.logo, raw, &log) orelse continue;
        defer gpa.free(data);
        const tmp = "USOSDISP.TMP";
        dir.writeFile(io, .{ .sub_path = tmp, .data = data }) catch |err| {
            log.line("{s}: write error {s}; left as is", .{ t.name, @errorName(err) });
            status = 3;
            continue;
        };
        std.Io.Dir.rename(dir, tmp, dir, t.name, io) catch |err| {
            log.line("{s}: rename error {s}; left as is", .{ t.name, @errorName(err) });
            dir.deleteFile(io, tmp) catch {};
            status = 3;
            continue;
        };
    }
    if (seen == 0) log.line("no display driver or logo file in {s}", .{path});
    dir.writeFile(io, .{ .sub_path = log_name, .data = log.text.items }) catch {};
    return status;
}
