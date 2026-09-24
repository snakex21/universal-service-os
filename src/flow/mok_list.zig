//! shim's MOK list format and the rules for saving the USOS key directly
//! (docs/secure-boot-usos.md, "Saving the key without MokManager").
//!
//! shim 16.1 (mok.c, mok_state_variables): MokList must have the attributes
//! NON_VOLATILE | BOOTSERVICE_ACCESS and must NOT have RUNTIME_ACCESS, or
//! shim deletes it as untrusted. Only pre-OS code can create such a
//! variable, which is why shim trusts it. Its content is a sequence of
//! EFI_SIGNATURE_LISTs; MokManager enrolls a certificate by appending one
//! list of type EFI_CERT_X509_GUID whose owner is SHIM_LOCK_GUID.
const std = @import("std");
const secure_boot_policy = @import("secure_boot_policy.zig");

/// SHIM_LOCK_GUID 605dab50-e046-4300-abb6-3dd810dd8b23 in memory order.
pub const shim_lock_guid = [16]u8{ 0x50, 0xab, 0x5d, 0x60, 0x46, 0xe0, 0x00, 0x43, 0xab, 0xb6, 0x3d, 0xd8, 0x10, 0xdd, 0x8b, 0x23 };
/// EFI_CERT_X509_GUID a5c059a1-94e4-4aa7-87b5-ab155c2bf072 in memory order.
pub const cert_x509_guid = [16]u8{ 0xa1, 0x59, 0xc0, 0xa5, 0xe4, 0x94, 0xa7, 0x4a, 0x87, 0xb5, 0xab, 0x15, 0x5c, 0x2b, 0xf0, 0x72 };

/// EFI_SIGNATURE_LIST header: SignatureType (16), SignatureListSize (4),
/// SignatureHeaderSize (4), SignatureSize (4).
pub const list_header_size = 28;
/// EFI_SIGNATURE_DATA header: SignatureOwner (16).
pub const owner_size = 16;

/// Bytes of the single-certificate list for a DER certificate.
pub fn listSize(der_len: usize) usize {
    return list_header_size + owner_size + der_len;
}

/// Builds the EFI_SIGNATURE_LIST MokManager and mokutil use for one X.509
/// certificate. `out` must hold listSize(der.len) bytes.
pub fn buildList(der: []const u8, out: []u8) ?[]u8 {
    const total = listSize(der.len);
    if (der.len == 0 or out.len < total or total > std.math.maxInt(u32)) return null;
    @memcpy(out[0..16], &cert_x509_guid);
    std.mem.writeInt(u32, out[16..20], @intCast(total), .little);
    std.mem.writeInt(u32, out[20..24], 0, .little);
    std.mem.writeInt(u32, out[24..28], @intCast(owner_size + der.len), .little);
    @memcpy(out[28..44], &shim_lock_guid);
    @memcpy(out[44..total], der);
    return out[0..total];
}

pub const ParseError = error{Malformed};

/// True when `lists` (MokList/MokListRT/MokListX content) holds `der` as an
/// X.509 entry. Malformed data stops the walk the way shim does and counts
/// as "not found" (error.Malformed tells the caller why).
pub fn containsX509(lists: []const u8, der: []const u8) ParseError!bool {
    var offset: usize = 0;
    while (offset < lists.len) {
        if (lists.len - offset < list_header_size) return error.Malformed;
        const header = lists[offset..];
        const list_size = std.mem.readInt(u32, header[16..20], .little);
        const header_size = std.mem.readInt(u32, header[20..24], .little);
        const signature_size = std.mem.readInt(u32, header[24..28], .little);
        if (list_size < list_header_size or list_size > lists.len - offset) return error.Malformed;
        if (signature_size < owner_size) return error.Malformed;
        if (@as(u64, list_header_size) + header_size > list_size) return error.Malformed;
        if (std.mem.eql(u8, header[0..16], &cert_x509_guid)) {
            var entry: usize = list_header_size + header_size;
            while (entry + signature_size <= list_size) : (entry += signature_size) {
                const data = header[entry + owner_size .. entry + signature_size];
                if (std.mem.eql(u8, data, der)) return true;
            }
        }
        offset += list_size;
    }
    return false;
}

/// Whether a MokList with these attribute bits is one shim keeps.
pub fn trustedAttributes(non_volatile: bool, bootservice: bool, runtime: bool) bool {
    return non_volatile and bootservice and !runtime;
}

/// MokTimeout content (shim MokManager.c MokTimeoutvar: packed INT32).
/// -1 makes MokManager open its menu at once instead of the 10 s countdown;
/// MokManager deletes the variable after reading it.
pub fn timeoutValue(seconds: i32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, seconds, .little);
    return bytes;
}

/// usos-settings.ini key: 0 = do not offer the key on the home screen.
pub const remind_key = "secure_boot_key_prompt";

/// The home screen may offer the key unless usos-settings.ini says
/// secure_boot_key_prompt=0.
pub fn remindEnabled(settings: []const u8) bool {
    const value = settingValue(settings, remind_key) orelse return true;
    return !std.mem.eql(u8, value, "0");
}

pub fn settingValue(settings: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equals], " \t"), key)) continue;
        return std.mem.trim(u8, line[equals + 1 ..], " \t");
    }
    return null;
}

/// Copies `settings` with `key` set to `value` (replacing an existing line,
/// else appended) into `out`.
pub fn withSetting(settings: []const u8, key: []const u8, value: []const u8, out: []u8) ?[]const u8 {
    var used: usize = 0;
    var replaced = false;
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 and lines.peek() == null) break;
        var text = line;
        var buffer: [128]u8 = undefined;
        if (std.mem.indexOfScalar(u8, line, '=')) |equals| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equals], " \t"), key)) {
                text = std.fmt.bufPrint(&buffer, "{s}={s}", .{ key, value }) catch return null;
                replaced = true;
            }
        }
        if (used + text.len + 2 > out.len) return null;
        @memcpy(out[used .. used + text.len], text);
        used += text.len;
        @memcpy(out[used .. used + 2], "\r\n");
        used += 2;
    }
    if (!replaced) {
        const line = std.fmt.bufPrint(out[used..], "{s}={s}\r\n", .{ key, value }) catch return null;
        used += line.len;
    }
    return out[0..used];
}

pub const KeyState = enum { saved, missing, unknown };

/// When the menu offers to save the key: Secure Boot is off (not setup
/// mode: without a PK Secure Boot cannot be turned on, and USOS never
/// writes the MOK list while Secure Boot is enforcing), the key is known
/// to be missing, the certificate is on the drive and the user did not
/// choose "Don't ask again".
pub fn shouldOffer(state: secure_boot_policy.State, key: KeyState, have_certificate: bool, never_ask: bool) bool {
    return state == .disabled and key == .missing and have_certificate and !never_ask;
}

/// Whether USOS may write MokList now (the same gate without the
/// "Don't ask again" setting, e.g. from the Secure Boot page).
pub fn canSave(state: secure_boot_policy.State, key: KeyState, have_certificate: bool) bool {
    return state == .disabled and key == .missing and have_certificate;
}

test "the signature list matches the mokutil layout and is found again" {
    const der = "0\x82certificate-bytes";
    var buffer: [128]u8 = undefined;
    const list = buildList(der, &buffer).?;
    try std.testing.expectEqual(@as(usize, 28 + 16 + der.len), list.len);
    try std.testing.expectEqual(@as(u32, @intCast(list.len)), std.mem.readInt(u32, list[16..20], .little));
    try std.testing.expectEqual(@as(u32, 16 + der.len), std.mem.readInt(u32, list[24..28], .little));
    try std.testing.expect(try containsX509(list, der));
    try std.testing.expect(!try containsX509(list, "other"));
    try std.testing.expect(!try containsX509("", der));
}

test "an existing list with another key is walked and kept" {
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    const other = buildList("another-key", &first).?;
    const ours = buildList("usos-key", &second).?;
    var both: [128]u8 = undefined;
    @memcpy(both[0..other.len], other);
    @memcpy(both[other.len .. other.len + ours.len], ours);
    const merged = both[0 .. other.len + ours.len];
    try std.testing.expect(try containsX509(merged, "usos-key"));
    try std.testing.expect(try containsX509(merged, "another-key"));
    // A SHA-256 hash list (not X.509) is skipped.
    var hash_list: [28 + 16 + 32]u8 = @splat(0);
    std.mem.writeInt(u32, hash_list[16..20], hash_list.len, .little);
    std.mem.writeInt(u32, hash_list[24..28], 48, .little);
    try std.testing.expect(!try containsX509(&hash_list, "usos-key"));
    try std.testing.expectError(error.Malformed, containsX509(merged[0 .. merged.len - 1], "zzz"));
}

test "offer and save gates" {
    try std.testing.expect(shouldOffer(.disabled, .missing, true, false));
    try std.testing.expect(!shouldOffer(.disabled, .missing, true, true));
    try std.testing.expect(!shouldOffer(.enforcing, .missing, true, false));
    try std.testing.expect(!shouldOffer(.setup_mode, .missing, true, false));
    try std.testing.expect(!shouldOffer(.unsupported, .missing, true, false));
    try std.testing.expect(!shouldOffer(.disabled, .saved, true, false));
    try std.testing.expect(!shouldOffer(.disabled, .unknown, true, false));
    try std.testing.expect(!shouldOffer(.disabled, .missing, false, false));
    try std.testing.expect(canSave(.disabled, .missing, true));
    try std.testing.expect(!canSave(.enforcing, .missing, true));
    try std.testing.expect(trustedAttributes(true, true, false));
    try std.testing.expect(!trustedAttributes(true, true, true));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, &timeoutValue(-1));
}

test "settings helpers keep other keys and replace ours" {
    var out: [256]u8 = undefined;
    const updated = withSetting("language=pl\r\nwheel_invert=1\r\n", remind_key, "0", &out).?;
    try std.testing.expectEqualStrings("language=pl\r\nwheel_invert=1\r\nsecure_boot_key_prompt=0\r\n", updated);
    try std.testing.expect(!remindEnabled(updated));
    var again: [256]u8 = undefined;
    const back = withSetting(updated, remind_key, "1", &again).?;
    try std.testing.expectEqualStrings("language=pl\r\nwheel_invert=1\r\nsecure_boot_key_prompt=1\r\n", back);
    try std.testing.expect(remindEnabled(back));
    try std.testing.expect(remindEnabled(""));
}
