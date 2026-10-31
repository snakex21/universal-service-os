const std = @import("std");
const usos = @import("usos");
const linux = std.os.linux;
const fb_device = @import("fb_device.zig");
const renderer = @import("fb_ui_render.zig");
const fb_i18n = @import("fb_i18n.zig");
const state_model = @import("fb_ui_state.zig");

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const first_arg = args.next();
    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--menu")) {
            return @import("fb_menu.zig").run(init.gpa, args.next() orelse return 2);
        }
        // tools/extract.sh: user INF drivers -> WORK $WinPEDriver$ (no UI).
        if (std.mem.eql(u8, arg, "--stage-drivers")) {
            const source = args.next() orelse return 2;
            const destination = args.next() orelse return 2;
            const image = args.next() orelse return 2;
            const log_path = args.next() orelse return 2;
            return @import("driver_stage.zig").run(source, destination, image, log_path);
        }
        // tools/dos_csmwrap_target.sh: patch the staged Windows 3.x display
        // driver(s) and VGA logo (X470 latch fault, src/compat/win3x; no UI).
        if (std.mem.eql(u8, arg, "--win3x-display")) {
            return usos.win3x.display_run.run(init.io, init.gpa, args.next() orelse return 2);
        }
        // tools/w9x_csmwrap_target.sh: Windows 9x Setup's MINI.CAB (VGA.DRV
        // latch fix, USB keyboard/mouse bridge for its mini-Windows; no UI).
        if (std.mem.eql(u8, arg, "--w9x-setup-mini")) {
            const setup_dir = args.next() orelse return 2;
            return usos.win3x.w9x_mini.run(init.io, init.gpa, setup_dir, args.next() orelse return 2);
        }
        // tools/nt4_csmwrap_target.sh, native NT 3.5: INITIAL.IN_ with the
        // I586 processor line (src/compat/win3x/nt35_initial.zig; no UI).
        if (std.mem.eql(u8, arg, "--nt35-initial")) {
            const in_path = args.next() orelse return 2;
            return usos.win3x.nt35_initial.run(init.io, init.gpa, in_path, args.next() orelse return 2);
        }
        // tools/nt4_csmwrap_target.sh, native NT 3.51 LAN: one-file cabinet
        // (OEMNADLB.IN_) out / back in (src/compat/win3x/nt3_cab_file.zig; no UI).
        if (std.mem.eql(u8, arg, "--nt3-cab-get")) {
            const cab_path = args.next() orelse return 2;
            return usos.win3x.nt3_cab_file.runGet(init.io, init.gpa, cab_path, args.next() orelse return 2);
        }
        if (std.mem.eql(u8, arg, "--nt3-cab-put")) {
            const cab_path = args.next() orelse return 2;
            const file_path = args.next() orelse return 2;
            return usos.win3x.nt3_cab_file.runPut(init.io, init.gpa, cab_path, file_path, args.next() orelse return 2);
        }
        // tools/nt4_csmwrap_target.sh, native NT 4.0: the RTM kernel's CPUID
        // leaf limit (src/compat/win3x/nt4_kernel.zig; no UI).
        if (std.mem.eql(u8, arg, "--nt4-kernel")) {
            const in_path = args.next() orelse return 2;
            return usos.win3x.nt4_kernel.run(init.io, init.gpa, in_path, args.next() orelse return 2);
        }
        // tools/nt4_csmwrap_target.sh, native NT 3.1: the USOS boot drivers
        // in the SYSTEM._ template and the SZDD INFs of the local source
        // (src/compat/win3x/nt31_hive.zig; no UI).
        if (std.mem.eql(u8, arg, "--nt31-hive")) {
            const in_path = args.next() orelse return 2;
            const out_path = args.next() orelse return 2;
            const nvme = if (args.next()) |a| std.mem.eql(u8, a, "nvme") else false;
            return usos.win3x.nt31_hive.run(init.io, init.gpa, in_path, out_path, nvme);
        }
        if (std.mem.eql(u8, arg, "--szdd-get")) {
            const in_path = args.next() orelse return 2;
            return usos.win3x.nt31_hive.runGet(init.io, init.gpa, in_path, args.next() orelse return 2);
        }
        if (std.mem.eql(u8, arg, "--szdd-put")) {
            const orig = args.next() orelse return 2;
            const body = args.next() orelse return 2;
            return usos.win3x.nt31_hive.runPut(init.io, init.gpa, orig, body, args.next() orelse return 2);
        }
        // tools/vista_csmwrap_target.sh: truncatememory in a staging BCD (no UI).
        if (std.mem.eql(u8, arg, "--bcd-truncatememory")) {
            const bcd = @import("bcd_lowmem.zig");
            return bcd.run(args.next() orelse return 2, bcd.truncatememory);
        }
        // tools/vista_csmwrap_target.sh: testsigning in the x64 staging BCD.
        if (std.mem.eql(u8, arg, "--bcd-testsigning")) {
            const bcd = @import("bcd_lowmem.zig");
            return bcd.run(args.next() orelse return 2, bcd.testsigning);
        }
    }

    // Take ownership of the visible fbdev surface first. As soon as mmap is
    // ready, replace simpledrm's black clear with the USOS background before
    // doing any state-file I/O or parsing.
    var device = fb_device.Device.open() catch |err| {
        std.debug.print("usos-fb-ui: framebuffer open failed: {s}\n", .{@errorName(err)});
        return 3;
    };
    defer device.close();

    // Use the same common off-screen ScreenBuffer as the UEFI renderer. The
    // first visible write becomes one bulk background copy, then the completed
    // preparation frame is copied in one pass after state parsing.
    var back_pixels: ?[]u32 = null;
    defer if (back_pixels) |pixels| init.gpa.free(pixels);
    var back: ?usos.gui.ScreenBuffer = null;
    const back_bytes = usos.gui.ScreenBuffer.requiredBytes(device.width, device.height) orelse 0;
    if (back_bytes != 0) {
        const pixel_count = back_bytes / @sizeOf(u32);
        if (init.gpa.alloc(u32, pixel_count) catch null) |pixels| {
            if (usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), back_bytes, device.width, device.height, device.surface.framebuffer.pixel_format)) |buffer| {
                back_pixels = pixels;
                back = buffer;
            } else {
                init.gpa.free(pixels);
            }
        }
    }
    // The theme of the screens before micro-Linux (fb_i18n.activeTheme).
    const theme = fb_i18n.activeTheme();
    if (back) |buffer| {
        renderer.fillBackground(buffer.surface, theme);
        buffer.copyTo(device.surface);
    } else {
        renderer.fillBackground(device.surface, theme);
    }

    var state_fd: i32 = 0;
    var close_state = false;
    if (first_arg) |path| {
        state_fd = openReadOnly(path) catch |err| {
            std.debug.print("usos-fb-ui: state open failed: {s}\n", .{@errorName(err)});
            return 2;
        };
        close_state = true;
    }
    defer {
        if (close_state) _ = linux.close(state_fd);
    }

    var state_buffer: [32768]u8 = undefined;
    const length = readAll(state_fd, &state_buffer) catch |err| {
        std.debug.print("usos-fb-ui: state read failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    const state = state_model.parse(state_buffer[0..length]) catch |err| {
        std.debug.print("usos-fb-ui: invalid state: {s}\n", .{@errorName(err)});
        return 2;
    };

    const context = try init.gpa.create(fb_i18n.Context);
    defer init.gpa.destroy(context);
    context.* = .{};
    context.load();
    if (back) |buffer| {
        renderer.render(buffer.surface, context, state);
        buffer.copyTo(device.surface);
    } else {
        renderer.render(device.surface, context, state);
    }
    device.present();
    return 0;
}

fn openReadOnly(path: []const u8) !i32 {
    if (path.len >= 512) return error.PathTooLong;
    var path_buffer: [512:0]u8 = undefined;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const result = linux.open(&path_buffer, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
    return @intCast(result);
}

fn readAll(fd: i32, buffer: []u8) !usize {
    var used: usize = 0;
    while (used < buffer.len) {
        const result = linux.read(fd, buffer.ptr + used, buffer.len - used);
        const err = linux.errno(result);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.ReadFailed;
        if (result == 0) return used;
        used += result;
    }
    return error.StateTooLarge;
}
