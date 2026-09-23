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
    if (back) |buffer| {
        renderer.fillBackground(buffer.surface);
        buffer.copyTo(device.surface);
    } else {
        renderer.fillBackground(device.surface);
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
