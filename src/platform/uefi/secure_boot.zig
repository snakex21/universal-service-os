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

// ------------------------------------------------------------ raw reads
//
// Diagnostics (Tools -> Secure Boot, drivers.txt, input-devices.txt) log
// every variable the key gate evaluates with the exact GetVariable status,
// so a board that hides or loses a variable can be told apart from one in
// Setup Mode.

const Byte = @import("usos").flow.mok_list.Byte;

/// EFI_IMAGE_SECURITY_DATABASE_GUID d719b2cb-3d3a-4596-a3bc-dad00e67656f (db, dbx).
pub const image_security_guid align(8) = uefi.Guid{
    .time_low = 0xd719b2cb,
    .time_mid = 0x3d3a,
    .time_high_and_version = 0x4596,
    .clock_seq_high_and_reserved = 0xa3,
    .clock_seq_low = 0xbc,
    .node = .{ 0xda, 0xd0, 0x0e, 0x67, 0x65, 0x6f },
};

/// One GetVariable call as the firmware answered it.
pub const RawVariable = struct {
    status: uefi.Status,
    /// DataSize after the call (the needed size on BUFFER_TOO_SMALL).
    size: usize,
    attributes: u32,
    /// The content when status == success.
    data: []u8,

    pub fn present(self: RawVariable) bool {
        return self.status == .success or self.status == .buffer_too_small;
    }

    pub fn statusText(self: RawVariable) []const u8 {
        return statusName(self.status);
    }
};

pub fn statusName(status: uefi.Status) []const u8 {
    return std.enums.tagName(uefi.Status, status) orelse "unknown_status";
}

/// GetVariable into `buffer` (may be empty: then only the size is asked).
pub fn readRaw(name: [*:0]const u16, guid: *align(8) const uefi.Guid, buffer: []u8) RawVariable {
    var attributes: uefi.tables.RuntimeServices.VariableAttributes = .{};
    var size: usize = buffer.len;
    const rt = uefi.system_table.runtime_services;
    const status = rt._getVariable(name, guid, &attributes, &size, if (buffer.len == 0) null else buffer.ptr);
    return .{
        .status = status,
        .size = size,
        .attributes = @bitCast(attributes),
        .data = if (status == .success) buffer[0..@min(size, buffer.len)] else buffer[0..0],
    };
}

/// A one-byte EFI global variable (SecureBoot, SetupMode, AuditMode, ...).
pub fn globalByte(name: [*:0]const u16) Byte {
    var value: [8]u8 = undefined;
    const raw = readRaw(name, &uefi.tables.global_variable, &value);
    return switch (raw.status) {
        .success => if (raw.size == 1) .{ .value = value[0] } else .{ .failed = "size_not_1" },
        .not_found => .absent,
        else => .{ .failed = raw.statusText() },
    };
}

/// EFI_LEGACY_BIOS_PROTOCOL_GUID db9a1e3d-45cb-4abb-853b-e5387fdb2e2d: the
/// CSM's protocol; present only when the firmware loaded the CSM.
const legacy_bios_guid align(8) = uefi.Guid{
    .time_low = 0xdb9a1e3d,
    .time_mid = 0x45cb,
    .time_high_and_version = 0x4abb,
    .clock_seq_high_and_reserved = 0x85,
    .clock_seq_low = 0x3b,
    .node = .{ 0xe5, 0x38, 0x7f, 0xdb, 0x2e, 0x2d },
};

pub const Csm = struct {
    legacy_bios_protocol: bool = false,
    boot_options: u16 = 0,
    /// BootOrder entries whose device path is a BBS (legacy) node.
    legacy_boot_options: u16 = 0,
    boot_order_status: uefi.Status = .not_found,

    pub fn likelyOn(self: Csm) bool {
        return self.legacy_bios_protocol or self.legacy_boot_options != 0;
    }
};

var csm_cached: ?Csm = null;

/// Whether the CSM (legacy BIOS support) looks enabled: its protocol is
/// installed, or BootOrder lists legacy (BBS) boot options.
pub fn csm() Csm {
    if (csm_cached) |known| return known;
    var result = Csm{};
    if (uefi.system_table.boot_services) |bs| {
        var interface: ?*const anyopaque = null;
        result.legacy_bios_protocol = bs._locateProtocol(&legacy_bios_guid, null, &interface) == .success and interface != null;
    }
    var order_buffer: [256]u8 = undefined;
    const order = readRaw(std.unicode.utf8ToUtf16LeStringLiteral("BootOrder"), &uefi.tables.global_variable, &order_buffer);
    result.boot_order_status = order.status;
    if (order.status == .success) {
        var index: usize = 0;
        while (index + 2 <= order.data.len) : (index += 2) {
            const number = std.mem.readInt(u16, order.data[index..][0..2], .little);
            var name: [9]u16 = undefined;
            const digits = "0123456789ABCDEF";
            const prefix = std.unicode.utf8ToUtf16LeStringLiteral("Boot");
            @memcpy(name[0..4], prefix[0..4]);
            for (0..4) |d| name[4 + d] = digits[(number >> @intCast(12 - 4 * d)) & 0xf];
            name[8] = 0;
            var option_buffer: [2048]u8 = undefined;
            const option = readRaw(name[0..8 :0], &uefi.tables.global_variable, &option_buffer);
            if (option.status != .success) continue;
            result.boot_options += 1;
            if (@import("usos").flow.mok_list.isLegacyLoadOption(option.data)) result.legacy_boot_options += 1;
        }
    }
    csm_cached = result;
    return result;
}
