// Optional, reversible USB entry point for physical CSMWrap evaluation.
// No installation, disk selection or raw disk writes occur in this loader.
const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const trace = @import("windows7_uefi_trace.zig");

fn say(comptime message: []const u8) void {
    if (uefi.system_table.con_out) |con| _ = con.outputString(wide(message)) catch false;
}

fn log(device: uefi.Handle, message: []const u8) void {
    trace.recordNamed(device, wide("\\EFI\\CSMWrap\\"), wide("usos-launch.log"), message);
}

fn key() !u16 {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const input = uefi.system_table.con_in orelse return error.NoKeyboard;
    while (true) {
        const pressed = input.readKeyStroke() catch |err| switch (err) {
            error.NotReady => {
                _ = try bs.waitForEvent(&.{input.wait_for_key});
                continue;
            },
            else => return err,
        };
        return pressed.unicode_char;
    }
}

fn start(device: uefi.Handle, experimental: bool) !uefi.Status {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const dp = (try bs.handleProtocol(uefi.protocol.DevicePath, device)) orelse return error.NoDevicePath;
    var storage: [4096]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    const path = try dp.createFileDevicePath(arena.allocator(), if (experimental)
        wide("\\EFI\\CSMWrap\\csmwrapx64.efi")
    else
        wide("\\EFI\\BOOT\\USOS-original.efi"));
    const image = try bs.loadImage(false, uefi.handle, .{ .device_path = path });
    defer _ = bs.unloadImage(image) catch .load_error;
    if (experimental) log(device, "CSMWrap 3.1.2 loaded; handing control to CSMWrap. This record does NOT confirm SeaBIOS or Windows boot. Further diagnostics are on screen (verbose=true).");
    const result = try bs.startImage(image);
    if (experimental) log(device, "CSMWrap returned to the EFI launcher. Windows boot is not confirmed.");
    return result.code;
}

fn run() !uefi.Status {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    try bs.setWatchdogTimer(0, 0, null);
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.NoLoadedImage;
    const device = loaded.device_handle orelse return error.NoDevice;
    if (uefi.system_table.con_out) |con| {
        con.clearScreen() catch {};
        con.enableCursor(false) catch {};
    }
    say("USOS - CSMWrap hardware trial\r\n\r\n");
    say("  1 / ENTER - Normal USOS\r\n");
    say("  2         - CSMWrap 3.1.2 (experimental Legacy BIOS)\r\n\r\n");
    say("CSMWrap: disable firmware CSM and Secure Boot.\r\n");
    say("Existing Windows needs a Legacy boot path. GPT/EFI alone is not enough.\r\n");
    say("This menu does not install or format anything.\r\n\r\n");
    while (true) {
        const choice = try key();
        if (choice != '1' and choice != '2' and choice != '\r') continue;
        const experimental = choice == '2';
        if (experimental) log(device, "CSMWrap selected; attempting LoadImage from the USB ESP.");
        return start(device, experimental) catch |err| {
            if (experimental) log(device, @errorName(err));
            say("\r\nLoader failed: ");
            var message: [128:0]u16 = undefined;
            const name = @errorName(err);
            for (name, 0..) |c, i| message[i] = c;
            message[name.len] = 0;
            if (uefi.system_table.con_out) |con| _ = con.outputString(message[0..name.len :0]) catch false;
            say("\r\nPress a key to return to firmware.\r\n");
            _ = key() catch 0;
            return .load_error;
        };
    }
}

pub fn main() uefi.Status {
    return run() catch {
        say("\r\nUSOS trial menu could not start.\r\n");
        return .load_error;
    };
}
