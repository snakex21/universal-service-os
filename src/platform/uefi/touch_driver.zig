//! Starts the vendored TouchI2cDxe driver (\EFI\USOS\touchi2c_x64.efi,
//! tools/vendor/touchi2cdxe) on supported handhelds, before the pointer
//! layer enumerates, so the menu gets an EFI_ABSOLUTE_POINTER_PROTOCOL for
//! the I2C-HID touchscreen (ROG Ally RC71L and the driver's other
//! profiles). Gated on SMBIOS (src/flow/touch_driver_policy.zig) and
//! usos-settings.ini `touch_driver=auto|off`; loaded through the same
//! shim-verified path as the NTFS driver (verified_image.zig), so it works
//! with Secure Boot on and off. Every failure is recorded for
//! input-devices.txt and the menu carries on.
//!
//! On a diagnostic boot (EFI\USOS\diagnostic-boot.flag) the driver gets the
//! load option `log=\EFI\USOS\Logs\touchi2c.log` and appends its probe log
//! there; otherwise it writes nothing (the USOS build compiles its own ESP
//! log out).
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const policy = usos.flow.touch_driver_policy;
const file_read = @import("file_read.zig");
const verified_image = @import("verified_image.zig");
const text_input = @import("text_input.zig");
const diagnostic_boot = @import("diagnostic_boot.zig");
const pointer = @import("pointer.zig");
const serial = @import("serial.zig");

pub const driver_path = "\\EFI\\USOS\\touchi2c_x64.efi";
pub const log_path = "\\EFI\\USOS\\Logs\\touchi2c.log";

/// NUL-terminated UTF-16 load option (the size passed includes the NUL).
const log_option = std.unicode.utf8ToUtf16LeStringLiteral("log=" ++ log_path ++ "\x00");

var driver_buffer: [128 * 1024]u8 = undefined;

pub const Outcome = enum {
    not_attempted,
    skipped,
    file_missing,
    started,
    failed,

    pub fn text(self: Outcome) []const u8 {
        return switch (self) {
            .not_attempted => "not attempted",
            .skipped => "not loaded",
            .file_missing => "failed: " ++ driver_path ++ " missing",
            .started => "started",
            .failed => "failed",
        };
    }
};

pub const Status = struct {
    mode: policy.Mode = .auto,
    decision: policy.Decision = .hardware_not_matched,
    target: ?policy.Target = null,
    outcome: Outcome = .not_attempted,
    err: ?anyerror = null,
    diagnostic_log: bool = false,
    size: usize = 0,
    absolute_before: usize = 0,
    absolute_after: usize = 0,
    /// Handles that appeared while the driver started (its AbsolutePointer).
    new_handles: [4]?uefi.Handle = .{ null, null, null, null },
};

var status: Status = .{};
var image_hash: ?[32]u8 = null;

/// SHA-256 of the started driver image (user drivers with the same bytes
/// are skipped as duplicates).
pub fn startedImageHash() ?[32]u8 {
    return if (status.outcome == .started) image_hash else null;
}

pub fn report() Status {
    return status;
}

/// Tools -> Drivers changed touch_driver= for the next start: the page and
/// the reports show the new setting (the running driver stays as it is).
pub fn setModeForReport(mode: policy.Mode) void {
    status.mode = mode;
}

/// Loads the driver when the hardware and settings allow it. Never fails:
/// the outcome is kept for the input-devices report.
pub fn start(root: *uefi.protocol.File, settings: []const u8) void {
    status = .{};
    status.mode = policy.parseMode(settings);
    const info = text_input.Report.smbios();
    status.target = if (info) |system| policy.target(system) else null;
    status.decision = policy.decide(status.mode, info);
    if (status.decision != .load) {
        status.outcome = .skipped;
        return;
    }
    startMatched(root);
}

/// Loads the driver without the SMBIOS gate (the Secure Boot QEMU probe).
pub fn startUngated(root: *uefi.protocol.File) void {
    status = .{ .decision = .load };
    startMatched(root);
}

fn startMatched(root: *uefi.protocol.File) void {
    const bytes = file_read.into(root, driver_path, &driver_buffer) orelse {
        status.outcome = .file_missing;
        say("[TOUCH_DRIVER] missing " ++ driver_path ++ "\n");
        return;
    };
    status.size = bytes.len;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    image_hash = hash;
    const services = uefi.system_table.boot_services orelse {
        status.outcome = .failed;
        status.err = error.BootServicesUnavailable;
        return;
    };
    var before: [16]uefi.Handle = undefined;
    const before_count = absoluteHandles(services, &before);
    status.absolute_before = before_count;

    // The driver logs only when handed a path and a device (diagnostic boot).
    var device: ?uefi.Handle = null;
    var options: ?[]const u16 = null;
    if (diagnostic_boot.requested(root)) {
        if (root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true })) |logs| {
            logs.close() catch {};
            device = bootDevice(services);
            if (device != null) {
                options = log_option[0..];
                status.diagnostic_log = true;
            }
        } else |_| {}
    }

    verified_image.startDriverWithOptions(bytes, device, options) catch |err| {
        status.outcome = .failed;
        status.err = err;
        say("[TOUCH_DRIVER] start failed: ");
        say(@errorName(err));
        say("\n");
        return;
    };
    status.outcome = .started;
    var after: [16]uefi.Handle = undefined;
    const after_count = absoluteHandles(services, &after);
    status.absolute_after = after_count;
    var slot: usize = 0;
    for (after[0..after_count]) |handle| {
        if (std.mem.indexOfScalar(uefi.Handle, before[0..before_count], handle) != null) continue;
        if (slot == status.new_handles.len) break;
        status.new_handles[slot] = handle;
        slot += 1;
    }
    say("[TOUCH_DRIVER] started\n");
}

/// The driver's AbsolutePointer handle, when it installed one.
pub fn ownsHandle(handle: uefi.Handle) bool {
    for (status.new_handles) |candidate| {
        if (candidate != null and candidate.? == handle) return true;
    }
    return false;
}

fn absoluteHandles(services: *uefi.tables.BootServices, out: []uefi.Handle) usize {
    const handles = (services.locateHandleBuffer(.{ .by_protocol = &pointer.AbsolutePointer.guid }) catch null) orelse return 0;
    defer services.freePool(@ptrCast(handles.ptr)) catch {};
    const n = @min(handles.len, out.len);
    @memcpy(out[0..n], handles[0..n]);
    return n;
}

fn bootDevice(services: *uefi.tables.BootServices) ?uefi.Handle {
    const loaded = (services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return null) orelse return null;
    return loaded.device_handle;
}

fn say(text: []const u8) void {
    serial.writeAscii(text);
}

/// Lines for input-devices.txt.
pub fn describe(comptime print: anytype) void {
    const s = status;
    print("[TOUCH DRIVER] TouchI2cDxe ({s})\n", .{driver_path});
    print("  setting touch_driver={s}\n", .{@tagName(s.mode)});
    print("  smbios_match={s}\n", .{if (s.target) |t| t.label() else "none"});
    print("  decision={s}\n", .{s.decision.text()});
    if (s.err) |err| {
        print("  loaded=no result={s} error={s}\n", .{ s.outcome.text(), @errorName(err) });
    } else {
        print("  loaded={s} result={s}\n", .{ if (s.outcome == .started) "yes" else "no", s.outcome.text() });
    }
    if (s.outcome == .started or s.outcome == .failed) {
        print("  image_bytes={d} secure_boot_path={s} diagnostic_log={s}\n", .{ s.size, secureBootPath(), if (s.diagnostic_log) log_path else "off" });
        print("  absolute_pointer_handles before={d} after={d}\n", .{ s.absolute_before, s.absolute_after });
        var any = false;
        for (s.new_handles) |handle| if (handle) |h| {
            any = true;
            print("  driver_handle=0x{x}\n", .{@intFromPtr(h)});
        };
        if (s.outcome == .started and !any) print("  driver_handle=(none: the driver installed no AbsolutePointer)\n", .{});
    }
}

fn secureBootPath() []const u8 {
    const secure_boot = @import("secure_boot.zig");
    if (!secure_boot.enforced()) return "off (LoadImage from buffer)";
    if (secure_boot.shimLock() == null) return "on, no shim (LoadImage)";
    return if (secure_boot.shimOwnsLoadImage()) "on (SHIM_LOCK verify + USOS PE loader)" else "on (SHIM_LOCK verify + LoadImage override)";
}
