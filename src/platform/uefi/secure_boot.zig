//! Secure Boot state of the running firmware and the shim protocols USOS
//! uses to verify the MOK-signed images it starts.
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const policy = @import("usos").flow.secure_boot_policy;

const secure_boot_name = std.unicode.utf8ToUtf16LeStringLiteral("SecureBoot");
const setup_mode_name = std.unicode.utf8ToUtf16LeStringLiteral("SetupMode");

/// shim's verification functions are plain C functions, not EFIAPI: on
/// x86_64 they use the System V ABI (see shim.h EFI_SHIM_LOCK_VERIFY and the
/// comment in GRUB's grub_efi_shim_lock_protocol).
const shim_cc: std.builtin.CallingConvention = switch (builtin.cpu.arch) {
    .x86_64 => .{ .x86_64_sysv = .{} },
    else => .c,
};

/// SHIM_LOCK_GUID 605dab50-e046-4300-abb6-3dd810dd8b23 (shim 15 and 16).
pub const ShimLock = extern struct {
    verify: *const fn (buffer: [*]const u8, size: u32) callconv(shim_cc) uefi.Status,
    hash: *const anyopaque,
    context: *const anyopaque,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x605dab50,
        .time_mid = 0xe046,
        .time_high_and_version = 0x4300,
        .clock_seq_high_and_reserved = 0xab,
        .clock_seq_low = 0xb6,
        .node = .{ 0x3d, 0xd8, 0x10, 0xdd, 0x8b, 0x23 },
    };
};

/// SHIM_IMAGE_LOADER_GUID 1f492041-fadb-4e59-9e57-7cafe73a55ab. Present from
/// shim 16: shim then replaces gBS->LoadImage/StartImage with its own
/// loader, which verifies against db and MOK but only runs applications.
pub const ShimImageLoader = extern struct {
    load_image: *const anyopaque,
    start_image: *const anyopaque,
    exit: *const anyopaque,
    unload_image: *const anyopaque,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x1f492041,
        .time_mid = 0xfadb,
        .time_high_and_version = 0x4e59,
        .clock_seq_high_and_reserved = 0x9e,
        .clock_seq_low = 0x57,
        .node = .{ 0x7c, 0xaf, 0xe7, 0x3a, 0x55, 0xab },
    };
};

var cached_state: ?policy.State = null;

fn readByte(name: [*:0]const u16) ?u8 {
    var value: [1]u8 = undefined;
    const result = uefi.system_table.runtime_services.getVariable(name, &uefi.tables.global_variable, &value) catch return null;
    const found = result orelse return null;
    if (found[0].len != 1) return null;
    return found[0][0];
}

/// Secure Boot state, read once from the SecureBoot/SetupMode variables.
pub fn state() policy.State {
    if (cached_state) |known| return known;
    const current = policy.State.fromVariables(readByte(secure_boot_name), readByte(setup_mode_name));
    cached_state = current;
    return current;
}

pub fn enforced() bool {
    return state().enforced();
}

pub fn shimLock() ?*ShimLock {
    const bs = uefi.system_table.boot_services orelse return null;
    return bs.locateProtocol(ShimLock, null) catch null;
}

/// True when shim 16+ has taken over gBS->LoadImage. shim hooks it only in
/// Secure Boot mode and only when it carries a vendor certificate, so the
/// boot services pointer is compared with the loader protocol's LoadImage.
pub fn shimOwnsLoadImage() bool {
    if (!enforced()) return false;
    const bs = uefi.system_table.boot_services orelse return false;
    const loader = (bs.locateProtocol(ShimImageLoader, null) catch return false) orelse return false;
    return @intFromPtr(loader.load_image) == @intFromPtr(bs._loadImage);
}

pub const VerifyError = error{ SecureBootRejected, ImageTooLarge };

/// Verifies a PE buffer through shim (db, dbx, MOK, MokListX and SBAT when
/// the image has a .sbat section).
pub fn shimVerify(lock: *ShimLock, image: []const u8) VerifyError!void {
    if (image.len > std.math.maxInt(u32)) return error.ImageTooLarge;
    if (lock.verify(image.ptr, @intCast(image.len)) != .success) return error.SecureBootRejected;
}

pub fn label(current: policy.State) []const u8 {
    return switch (current) {
        .unsupported => "unsupported",
        .disabled => "off",
        .setup_mode => "setup mode",
        .enforcing => "on",
    };
}
