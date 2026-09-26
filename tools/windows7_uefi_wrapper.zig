// Windows 7 compatibility dispatcher, used on WORK and the target ESP.
// Retain a firmware-provided Int10 handler instead of letting UefiSeven replace it.
const std = @import("std");
const uefi = std.os.uefi;
const video = @import("windows7_video");
const trace = @import("windows7_uefi_trace.zig");
const graphics = @import("windows7_uefi_graphics.zig");
const memory_probe = @import("windows7_uefi_memory_probe.zig");
const amd_shadow = @import("windows7_amd_shadow.zig");
const vga_routing = @import("windows7_vga_routing.zig");
const gop_retry = @import("windows7_gop_retry.zig");

const counter_name = std.unicode.utf8ToUtf16LeStringLiteral(gop_retry.counter_name);

fn readResets(device: uefi.Handle, dir: []const u16) u32 {
    var buffer: [16]u8 = undefined;
    return gop_retry.parseCounter(trace.readSmall(device, dir, counter_name, &buffer));
}

fn storeResets(device: uefi.Handle, dir: []const u16, value: u32) void {
    var text: [16]u8 = undefined;
    trace.writeSmall(device, dir, counter_name, std.fmt.bufPrint(&text, "{d}\r\n", .{value}) catch "0\r\n");
}
fn run() !uefi.Status {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.NoLoadedImage;
    const device = loaded.device_handle orelse return error.NoDevice;
    const node = loaded.file_path;
    if (node.type != .media or node.subtype != @intFromEnum(uefi.DevicePath.Media.Subtype.file_path) or node.length < 6 or node.length % 2 != 0) return error.InvalidPath;
    const self_node: *const uefi.DevicePath.Media.FilePathDevicePath = @ptrCast(node);
    var storage: [512:0]u16 = undefined;
    const units = (self_node.length - @sizeOf(uefi.DevicePath.Media.FilePathDevicePath)) / 2;
    if (units == 0 or units >= storage.len) return error.InvalidPath;
    const self = self_node.getPath();
    if (self[units - 1] != 0) return error.InvalidPath;
    var last: ?usize = null;
    for (0..units) |i| {
        storage[i] = self[i];
        if (self[i] == '\\') last = i;
    }
    const slash = last orelse return error.InvalidPath;
    if (slash + 32 >= storage.len) return error.InvalidPath;
    const valid = video.handlerValid();
    const dir = storage[0 .. slash + 1];
    // Per-path ring log: a CSM boot never overwrites the UefiSeven evidence.
    const log = &trace.session;
    log.begin(device, dir, if (valid) .csm else .uefiseven);
    memory_probe.record(device, dir);
    var graphics_result: graphics.Result = .present;
    const resets = readResets(device, dir);
    if (!valid) {
        trace.record(device, storage[0 .. slash + 1], "USOS: preparing GOP; connecting firmware controllers if GOP is absent");
        log.line("USOS: preparing GOP; connecting firmware controllers if GOP is absent");
        var used: u32 = 0;
        graphics_result = try graphics.ensureRetrying(gop_retry.passes, gop_retry.stall_us, &used);
        if (used > 1 and graphics_result != .unavailable) log.print("USOS: GOP appeared on connect pass {d}/{d}", .{ used, gop_retry.passes });
        if (graphics_result == .unavailable) {
            // UefiSeven needs a framebuffer and the original boot manager
            // hangs without Int10: re-initialise the GPU by a cold reset
            // (bounded), else hand back to the firmware as before.
            const step = gop_retry.decide(resets);
            storeResets(device, dir, step.store);
            switch (step.action) {
                .cold_reset => {
                    log.print("USOS: GOP/UGA absent after {d} recursive connect passes; cold reset {d}/{d} to re-initialise the GPU", .{ used, step.store, gop_retry.max_resets });
                    trace.record(device, dir, "USOS: GOP/UGA absent after the connect passes; cold reset (see the ring log)");
                    uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
                },
                .return_to_firmware => {
                    log.print("USOS: GOP/UGA absent after {d} passes and {d} cold resets; returning to the firmware (next boot option); reset counter cleared", .{ used, gop_retry.max_resets });
                    trace.record(device, dir, "USOS: GOP/UGA absent even after the connect passes and the cold resets; Windows boot manager was not started");
                    return error.NoGraphicsOutput;
                },
            }
        }
    }
    // A boot that got this far has a display path: the no-GOP streak is over.
    if (resets != 0) {
        storeResets(device, dir, 0);
        log.print("USOS: no-GOP reset counter cleared (was {d})", .{resets});
    }
    const decision = if (valid) "USOS: valid firmware Int10; loading original Windows 7 boot manager" else "USOS: missing/invalid Int10; loading UefiSeven for pure UEFI";
    trace.record(device, storage[0 .. slash + 1], decision);
    log.line(decision);
    const name = if (valid) std.unicode.utf8ToUtf16LeStringLiteral("win7.original.efi") else std.unicode.utf8ToUtf16LeStringLiteral("win7.efi");
    @memcpy(storage[slash + 1 ..][0..name.len], name);
    const n = slash + 1 + name.len;
    storage[n] = 0;
    if (!valid) video.prepareEmulatedVga();
    if (!valid) {
        amd_shadow.prepare(device, storage[0 .. slash + 1]) catch |err| {
            log.print("USOS: AMD C0000 routing stopped the boot: {s}; see usos-amd-shadow.log", .{@errorName(err)});
            return err;
        };
        // Legacy VGA I/O + A0000 must reach the GOP device, or vga.sys fails (Code 10).
        const routed = vga_routing.prepare(log);
        log.print("USOS: VGA routing result: {s}", .{@tagName(routed)});
        if (routed == .failed) {
            log.line("USOS: VGA read-back still fails; showing the frozen-display note for 5 s");
            vga_routing.warnFrozenDisplay();
        }
    }
    const dp = (try bs.handleProtocol(uefi.protocol.DevicePath, device)) orelse return error.NoDevicePath;
    var arena: [2048]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&arena);
    const path = try dp.createFileDevicePath(alloc.allocator(), storage[0..n :0]);
    const image = try bs.loadImage(false, uefi.handle, .{ .device_path = path });
    const start = if (valid) "USOS: starting original Windows 7 boot manager; firmware Int10 retained" else if (graphics_result == .connected) "USOS: GOP recovered by ConnectController; starting UefiSeven; details in UefiSeven.log" else if (graphics_result == .uga_present) "USOS: UGA present; starting UefiSeven; details in UefiSeven.log" else "USOS: GOP already present; starting UefiSeven; details in UefiSeven.log";
    trace.record(device, storage[0 .. slash + 1], start);
    log.line(start);
    const result = try bs.startImage(image);
    log.print("USOS: started image returned {s}", .{vga_routing.statusName(result.code)});
    return result.code;
}
pub fn main() uefi.Status {
    return run() catch {
        if (uefi.system_table.con_out) |con| {
            _ = con.outputString(std.unicode.utf8ToUtf16LeStringLiteral("USOS: Windows 7 EFI loader could not start.\r\n")) catch false;
        }
        return .load_error;
    };
}
