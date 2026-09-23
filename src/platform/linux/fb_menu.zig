const std = @import("std");
const linux = std.os.linux;
const usos = @import("usos");
const model = @import("fb_menu_model.zig");
const renderer = @import("fb_menu_render.zig");
const input_module = @import("fb_menu_input.zig");
const fb = @import("fb_device.zig");
const trace = @import("fb_menu_trace.zig");
const fb_i18n = @import("fb_i18n.zig");

pub fn run(allocator: std.mem.Allocator, path: []const u8) !u8 {
    trace.write("menu-entry state={s}", .{path});
    var path_buffer: [512]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{path});
    const opened = linux.open(name, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return 2;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var bytes: [32768]u8 = undefined;
    var used: usize = 0;
    while (used < bytes.len) {
        const n = linux.read(fd, bytes[used..].ptr, bytes.len - used);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return 2;
        if (n == 0) break;
        used += n;
    }
    if (used == bytes.len) return 2;
    var state = try model.parse(bytes[0..used]);
    trace.write("state-parsed title={s} items={d}", .{state.title, state.count});
    const tty_result = linux.open("/dev/tty1", .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
    if (linux.errno(tty_result) != .SUCCESS) return 3;
    const tty: i32 = @intCast(tty_result);
    defer _ = linux.close(tty);
    var old_term: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(tty, &old_term)) != .SUCCESS) return 3;
    var quiet_term = old_term;
    quiet_term.lflag.ECHO = false;
    quiet_term.lflag.ICANON = false;
    _ = linux.tcsetattr(tty, .FLUSH, &quiet_term);
    defer _ = linux.tcsetattr(tty, .FLUSH, &old_term);
    // A serial-only boot may defer fbcon takeover. Activate the visible VT
    // before entering graphics mode so its framebuffer is actually scanned out.
    trace.write("before-vt-activate", .{});
    const vt_result = linux.ioctl(tty, 0x5606, 1); // VT_ACTIVATE
    trace.write("vt-activate errno={s}", .{@tagName(linux.errno(vt_result))});
    // VT_WAITACTIVE can block indefinitely during deferred framebuffer takeover.
    // Query instead, and stop before accepting invisible destructive choices.
    const VtState = extern struct { active: u16 = 0, signal: u16 = 0, state: u16 = 0 };
    var vt = VtState{};
    const vt_query = linux.ioctl(tty, 0x5603, @intFromPtr(&vt)); // VT_GETSTATE
    trace.write("vt-query errno={s} active={d}", .{@tagName(linux.errno(vt_query)), vt.active});
    if (linux.errno(vt_result) != .SUCCESS or linux.errno(vt_query) != .SUCCESS or vt.active != 1) return 3;
    _ = linux.write(tty, "\x1b[2J\x1b[H".ptr, 7);

    trace.write("before-framebuffer-open", .{});
    var device: ?fb.Device = fb.Device.open() catch |err| blk: {
        trace.write("framebuffer-error={s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (device) |*d| d.close();
    const width = if (device) |d| d.width else 640;
    const height = if (device) |d| d.height else 480;
    // Keep VT text out of the framebuffer throughout the preparation session.
    const kd = linux.ioctl(tty, 0x4b3a, @as(usize, if (device != null) 1 else 0)); // KD_GRAPHICS or KD_TEXT for fallback
    trace.write("display-mode errno={s} framebuffer={s} width={d} height={d}", .{@tagName(linux.errno(kd)), if (device != null) "yes" else "no", width, height});
    if (linux.errno(kd) != .SUCCESS) return 3;
    const pixels = try allocator.alloc(u32, @as(usize, width) * height);
    defer allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, width, height, if (device) |d| d.surface.framebuffer.pixel_format else .bgrx8) orelse return 3;
    var input = input_module.Input{ .x = @intCast(width / 2), .y = @intCast(height / 2), .width = @intCast(width), .height = @intCast(height) };
    defer input.close();
    input.scan();
    var inputs: usize = 0;
    for (input.fds) |slot| { if (slot.fd >= 0) inputs += 1; }
    trace.write("input-open count={d}", .{inputs});
    const context = try allocator.create(fb_i18n.Context);
    defer allocator.destroy(context);
    context.* = .{};
    context.load();
    const ui = context.ui(buffer.surface);
    var redraw = true;
    var ready = false;
    while (true) {
        const layout = renderer.Layout.init(&ui, state);
        if (redraw) {
            if (device) |d| {
                renderer.render(&ui, state, input.x, input.y, input.pointer_visible);
                buffer.copyTo(d.surface);
            } else {
                console(tty, state);
            }
            if (!ready) {
                std.debug.print("[XP_MENU] READY: {s} items={d} selected={d} framebuffer={s}\n", .{state.title, state.count, state.selected, if (device != null) "yes" else "no"});
                ready = true;
                trace.write("menu-rendered framebuffer={s}", .{if (device != null) "yes" else "no"});
            }
            redraw = false;
        }
        const action = input.next();
        if (action != .none and action != .pointer) trace.write("action={s}", .{@tagName(action)});
        switch (action) {
            .none => {},
            .previous, .next => { state.move(action == .next); redraw = true; },
            .back => return 1,
            .accept => return selected(state.selected),
            .scroll_up, .scroll_down => {
                if (state.detailCount() > layout.info_lines) state.scrollInfo(action == .scroll_down, layout.info_lines) else state.move(action == .scroll_down);
                redraw = true;
            },
            .pointer => { redraw = true; },
            .click => {
                if (input.pointer_visible) {
                    if (layout.hit(input.x, input.y, state.count)) |index| return selected(index);
                }
            },
        }
    }
}

fn selected(index: usize) u8 {
    trace.write("selected={d}", .{index + 1});
    var buffer: [16]u8 = undefined;
    const result = std.fmt.bufPrint(&buffer, "{d}\n", .{index + 1}) catch return 2;
    if (linux.write(1, result.ptr, result.len) != result.len) return 2;
    std.debug.print("[XP_MENU] SELECTED: {d}\n", .{index + 1});
    return 0;
}

fn console(tty: i32, state: model.State) void {
    _ = linux.write(tty, "\x1b[2J\x1b[H".ptr, 7);
    var buffer: [1024]u8 = undefined;
    const title = std.fmt.bufPrint(&buffer, "USOS - {s}\n{s}\n\n", .{state.title, state.subtitle}) catch return;
    _ = linux.write(tty, title.ptr, title.len);
    for (state.items[0..state.count], 0..) |item, i| {
        const line = std.fmt.bufPrint(&buffer, "{s} {s}\n    {s}\n", .{if (i == state.selected) ">" else " ", item.title, item.detail}) catch continue;
        _ = linux.write(tty, line.ptr, line.len);
    }
    const info_first = if (state.table.columns > 0) 0 else state.scroll;
    for (state.info[info_first..@min(state.info_count, info_first + 10)]) |line| {
        _ = linux.write(tty, line.ptr, line.len);
        _ = linux.write(tty, "\n".ptr, 1);
    }
    if (state.table.columns > 0) {
        consoleCells(tty, state.table.headers[0..state.table.columns]);
        for (state.table.rows[state.scroll..@min(state.table.count, state.scroll + 10)]) |row| consoleCells(tty, row.cells[0..state.table.columns]);
    }
    const help = "\nArrows / ENTER: select. ESC: back. PgUp/PgDn: details.\n";
    _ = linux.write(tty, help.ptr, help.len);
}

fn consoleCells(tty: i32, cells: []const []const u8) void {
    for (cells, 0..) |cell, index| {
        if (index != 0) _ = linux.write(tty, " | ".ptr, 3);
        _ = linux.write(tty, cell.ptr, cell.len);
    }
    _ = linux.write(tty, "\n".ptr, 1);
}
