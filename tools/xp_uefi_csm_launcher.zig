// Separate experiment: EFI starts Linux preparation; XP itself uses firmware CSM.
const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const config = @import("xp_trial_config.zig");
fn say(comptime message: []const u8) void {
    if (uefi.system_table.con_out) |con| _ = con.outputString(wide(message)) catch false;
}
fn waitKey() !u16 {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const input = uefi.system_table.con_in orelse return error.NoKeyboard;
    while (true) {
        const k = input.readKeyStroke() catch |err| switch (err) {
            error.NotReady => { _ = try bs.waitForEvent(&.{input.wait_for_key}); continue; },
            else => return err,
        };
        if (k.scan_code == 23) return 27;
        return k.unicode_char;
    }
}
fn run() !uefi.Status {
    @setEvalBranchQuota(10000);
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    try bs.setWatchdogTimer(0, 0, null);
    // Preserve the parent's graphical loading screen. Disk selection and the
    // destructive-action confirmation belong to the preparation GUI.
    const self = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.NoLoadedImage;
    const device = self.device_handle orelse return error.NoDevice;
    const dp = (try bs.handleProtocol(uefi.protocol.DevicePath, device)) orelse return error.NoDevicePath;
    var buffer: [4096]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&buffer);
    const path = try dp.createFileDevicePath(arena.allocator(), wide("\\EFI\\USOS-XP\\vmlinuz.efi"));
    const child = try bs.loadImage(false, uefi.handle, .{ .device_path = path });
    defer _ = bs.unloadImage(child) catch .load_error;
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, child)) orelse return error.NoLoadedImage;
    var options = wide(config.options).*;
    loaded.load_options = &options;
    loaded.load_options_size = @sizeOf(@TypeOf(options));
    return (try bs.startImage(child)).code;
}
pub fn main() uefi.Status {
    return run() catch |err| {
        if (uefi.system_table.con_out) |con| con.clearScreen() catch {};
        say("\r\nXP preparation could not start: ");
        var message: [128:0]u16 = undefined;
        const name = @errorName(err);
        for (name, 0..) |c, i| message[i] = c;
        message[name.len] = 0;
        if (uefi.system_table.con_out) |con| _ = con.outputString(message[0..name.len :0]) catch false;
        say("\r\nPress a key to return.\r\n");
        _ = waitKey() catch 0;
        return .load_error;
    };
}
