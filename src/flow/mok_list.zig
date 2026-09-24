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

/// One firmware variable as USOS read it (SecureBoot, SetupMode, ...).
pub const Byte = union(enum) {
    value: u8,
    /// GetVariable returned EFI_NOT_FOUND.
    absent,
    /// GetVariable failed otherwise (error name), or the size was not 1.
    failed: []const u8,

    pub fn is(self: Byte, expected: u8) bool {
        return switch (self) {
            .value => |value| value == expected,
            else => false,
        };
    }
};

/// What the save gate looks at. MokList is a plain (not authenticated)
/// NV|BS variable under the shim GUID: writing it needs neither a PK nor
/// db, so Setup Mode, a missing PK, CSM and a missing SecureBoot variable
/// do not matter. The hard rules are "never while Secure Boot is enforcing"
/// (SecureBoot=1) and, since only shim reads MokList, "only under shim".
pub const Gate = struct {
    /// shim's SHIM_LOCK protocol is installed (USOS was started by shim).
    shim: bool,
    /// The SecureBoot variable (EFI global variable GUID).
    secure_boot: Byte,
    key: KeyState,
    certificate: bool,
    /// MokList exists with RUNTIME_ACCESS: shim deletes such a list.
    untrusted_list: bool = false,
};

pub const Refusal = enum {
    no_certificate,
    no_shim,
    secure_boot_on,
    /// SecureBoot could not be read (not EFI_NOT_FOUND): refuse, it may be on.
    secure_boot_unreadable,
    untrusted_list,
    key_saved,
    key_unknown,

    pub fn text(self: Refusal) []const u8 {
        return switch (self) {
            .no_certificate => "no USOS-KEY.cer on the ESP",
            .no_shim => "not started by shim (no SHIM_LOCK protocol)",
            .secure_boot_on => "Secure Boot is enforcing (SecureBoot=1)",
            .secure_boot_unreadable => "SecureBoot variable unreadable",
            .untrusted_list => "MokList has RUNTIME_ACCESS (shim would delete it)",
            .key_saved => "key already in MokList",
            .key_unknown => "MokList unreadable",
        };
    }
};

/// Why USOS may not write MokList now, or null when it may.
pub fn saveRefusal(gate: Gate) ?Refusal {
    if (!gate.certificate) return .no_certificate;
    if (!gate.shim) return .no_shim;
    switch (gate.secure_boot) {
        .value => |value| if (value == 1) return .secure_boot_on,
        .absent => {},
        .failed => return .secure_boot_unreadable,
    }
    if (gate.untrusted_list) return .untrusted_list;
    return switch (gate.key) {
        .missing => null,
        .saved => .key_saved,
        .unknown => .key_unknown,
    };
}

/// Whether USOS may write MokList now (the Secure Boot page's "Add the key").
pub fn canSave(gate: Gate) bool {
    return saveRefusal(gate) == null;
}

/// The home banner: the same gate, unless the user chose "Don't ask again".
pub fn shouldOffer(gate: Gate, never_ask: bool) bool {
    return canSave(gate) and !never_ask;
}

/// Microsoft UEFI CA certificates found in db (the CAs that sign shim).
pub const DbCas = struct {
    ca_2011: bool = false,
    ca_2023: bool = false,

    pub fn any(self: DbCas) bool {
        return self.ca_2011 or self.ca_2023;
    }
};

/// Subject common names of the third-party CAs that sign shim (shim 16.1-7
/// carries both signatures). "Microsoft Option ROM UEFI CA 2023" is a
/// different name and is not counted.
pub const ms_uefi_ca_2011 = "Microsoft Corporation UEFI CA 2011";
pub const ms_uefi_ca_2023 = "Microsoft UEFI CA 2023";

/// Walks db's signature lists and reports which Microsoft UEFI CAs it holds
/// (by the subject common name of each X.509 entry).
pub fn microsoftCas(db: []const u8) ParseError!DbCas {
    var result = DbCas{};
    var offset: usize = 0;
    while (offset < db.len) {
        if (db.len - offset < list_header_size) return error.Malformed;
        const header = db[offset..];
        const list_size = std.mem.readInt(u32, header[16..20], .little);
        const header_size = std.mem.readInt(u32, header[20..24], .little);
        const signature_size = std.mem.readInt(u32, header[24..28], .little);
        if (list_size < list_header_size or list_size > db.len - offset) return error.Malformed;
        if (signature_size < owner_size) return error.Malformed;
        if (@as(u64, list_header_size) + header_size > list_size) return error.Malformed;
        if (std.mem.eql(u8, header[0..16], &cert_x509_guid)) {
            var entry: usize = list_header_size + header_size;
            while (entry + signature_size <= list_size) : (entry += signature_size) {
                const data = header[entry + owner_size .. entry + signature_size];
                if (subjectCommonName(data)) |name| {
                    if (std.mem.eql(u8, name, ms_uefi_ca_2011)) result.ca_2011 = true;
                    if (std.mem.eql(u8, name, ms_uefi_ca_2023)) result.ca_2023 = true;
                }
            }
        }
        offset += list_size;
    }
    return result;
}

/// The last commonName (OID 2.5.4.3) in a DER certificate: the subject
/// follows the issuer in TBSCertificate, and extensions carry no CN. Good
/// enough to recognise CA certificates without an ASN.1 parser.
fn subjectCommonName(der: []const u8) ?[]const u8 {
    const oid = [_]u8{ 0x06, 0x03, 0x55, 0x04, 0x03 };
    var found: ?[]const u8 = null;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, der, start, &oid)) |at| {
        start = at + oid.len;
        // String tag (PrintableString, UTF8String, ...) and a short length.
        if (start + 2 > der.len) break;
        const len = der[start + 1];
        if (len >= 0x80 or start + 2 + len > der.len) continue;
        found = der[start + 2 .. start + 2 + len];
    }
    return found;
}

/// Hints for the Secure Boot page and the confirmation screen.
pub const Guidance = struct {
    /// Setup Mode or no PK: after turning Secure Boot on, install the
    /// default (factory) keys, including the Microsoft UEFI CA.
    install_default_keys: bool = false,
    /// CSM (legacy boot) looks enabled: many boards need it off first.
    disable_csm: bool = false,
    /// db is readable but has no Microsoft UEFI CA (and a PK is installed):
    /// shim will not start with Secure Boot on until the defaults are back.
    microsoft_ca_missing: bool = false,
};

pub fn guidance(setup_mode: Byte, pk_present: ?bool, csm_likely: bool, db: ?DbCas) Guidance {
    const default_keys = setup_mode.is(1) or (pk_present != null and !pk_present.?);
    return .{
        .install_default_keys = default_keys,
        .disable_csm = csm_likely,
        .microsoft_ca_missing = !default_keys and db != null and !db.?.any(),
    };
}

/// True for an EFI_LOAD_OPTION whose device path starts with a BBS node
/// (type 5): the firmware's legacy (CSM) boot entries.
pub fn isLegacyLoadOption(option: []const u8) bool {
    // UINT32 Attributes, UINT16 FilePathListLength, CHAR16 Description[].
    if (option.len < 6) return false;
    const path_len = std.mem.readInt(u16, option[4..6], .little);
    var offset: usize = 6;
    while (offset + 2 <= option.len) : (offset += 2) {
        if (option[offset] == 0 and option[offset + 1] == 0) break;
    } else return false;
    offset += 2;
    if (path_len < 4 or offset + 4 > option.len) return false;
    return option[offset] == 0x05;
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
    const off = Gate{ .shim = true, .secure_boot = .{ .value = 0 }, .key = .missing, .certificate = true };
    try std.testing.expect(shouldOffer(off, false));
    try std.testing.expect(!shouldOffer(off, true));
    try std.testing.expect(canSave(off));
    // Firmware without a SecureBoot variable: allowed under shim.
    var gate = off;
    gate.secure_boot = .absent;
    try std.testing.expect(canSave(gate));
    gate.secure_boot = .{ .value = 1 };
    try std.testing.expectEqual(Refusal.secure_boot_on, saveRefusal(gate).?);
    try std.testing.expect(!shouldOffer(gate, false));
    gate.secure_boot = .{ .failed = "DeviceError" };
    try std.testing.expectEqual(Refusal.secure_boot_unreadable, saveRefusal(gate).?);
    gate = off;
    gate.shim = false;
    try std.testing.expectEqual(Refusal.no_shim, saveRefusal(gate).?);
    gate = off;
    gate.key = .saved;
    try std.testing.expectEqual(Refusal.key_saved, saveRefusal(gate).?);
    gate.key = .unknown;
    try std.testing.expectEqual(Refusal.key_unknown, saveRefusal(gate).?);
    gate = off;
    gate.certificate = false;
    try std.testing.expectEqual(Refusal.no_certificate, saveRefusal(gate).?);
    gate = off;
    gate.untrusted_list = true;
    try std.testing.expectEqual(Refusal.untrusted_list, saveRefusal(gate).?);
    try std.testing.expect(trustedAttributes(true, true, false));
    try std.testing.expect(!trustedAttributes(true, true, true));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, &timeoutValue(-1));
}

test "the X470 state (SecureBoot=0, SetupMode=1, no PK) offers the key and asks for default keys" {
    // EFI\USOS\Logs\secure-boot-2E4F2079-...ini said secure_boot=setup_mode,
    // usos_key=missing, shim=yes; the old gate (state == .disabled) refused.
    const x470 = Gate{ .shim = true, .secure_boot = .{ .value = 0 }, .key = .missing, .certificate = true };
    try std.testing.expect(shouldOffer(x470, false));
    const hints = guidance(.{ .value = 1 }, false, false, .{});
    try std.testing.expect(hints.install_default_keys);
    try std.testing.expect(!hints.disable_csm);
    // In Setup Mode an empty db is expected; the default-keys hint covers it.
    try std.testing.expect(!hints.microsoft_ca_missing);
}

test "guidance: user mode, CSM, db without the Microsoft CA" {
    const user = guidance(.{ .value = 0 }, true, true, .{});
    try std.testing.expect(!user.install_default_keys);
    try std.testing.expect(user.disable_csm);
    try std.testing.expect(user.microsoft_ca_missing);
    const good = guidance(.{ .value = 0 }, true, false, .{ .ca_2011 = true });
    try std.testing.expect(!good.microsoft_ca_missing and !good.disable_csm);
    // PK unreadable, SetupMode missing: no claim either way.
    const unknown = guidance(.absent, null, false, null);
    try std.testing.expect(!unknown.install_default_keys and !unknown.microsoft_ca_missing);
    // PK missing although SetupMode says 0 (firmware quirk): still hint.
    try std.testing.expect(guidance(.{ .value = 0 }, false, false, null).install_default_keys);
}

fn fakeCert(comptime issuer: []const u8, comptime subject: []const u8) []const u8 {
    const oid = "\x06\x03\x55\x04\x03";
    return "\x30\x82\x01\x00" ++ oid ++ "\x13" ++ [_]u8{issuer.len} ++ issuer ++ "junk" ++ oid ++ "\x0c" ++ [_]u8{subject.len} ++ subject ++ "tail";
}

test "Microsoft UEFI CAs are recognised by the subject name in db" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    var c: [256]u8 = undefined;
    const ca2011 = buildList(fakeCert("Microsoft Corporation Third Party Marketplace Root", ms_uefi_ca_2011), &a).?;
    // A certificate issued BY the 2023 CA: only the subject counts.
    const issued = buildList(fakeCert(ms_uefi_ca_2023, "Microsoft Windows Production PCA 2011"), &b).?;
    const rom = buildList(fakeCert("Microsoft UEFI CA 2023 Root", "Microsoft Option ROM UEFI CA 2023"), &c).?;
    var db: [768]u8 = undefined;
    @memcpy(db[0..ca2011.len], ca2011);
    @memcpy(db[ca2011.len .. ca2011.len + issued.len], issued);
    @memcpy(db[ca2011.len + issued.len .. ca2011.len + issued.len + rom.len], rom);
    const all = try microsoftCas(db[0 .. ca2011.len + issued.len + rom.len]);
    try std.testing.expect(all.ca_2011 and !all.ca_2023);
    const none = try microsoftCas(db[ca2011.len .. ca2011.len + issued.len + rom.len]);
    try std.testing.expect(!none.any());
    try std.testing.expect(!(try microsoftCas("")).any());
    try std.testing.expectError(error.Malformed, microsoftCas(db[0 .. ca2011.len - 1]));
}

test "legacy (BBS) boot options are told apart from UEFI ones" {
    // Attributes, FilePathListLength=4, "A\0", then a device path node.
    const bbs = "\x01\x00\x00\x00\x04\x00A\x00\x00\x00\x05\x01\x04\x00";
    const hd = "\x01\x00\x00\x00\x04\x00A\x00\x00\x00\x04\x01\x2a\x00";
    try std.testing.expect(isLegacyLoadOption(bbs));
    try std.testing.expect(!isLegacyLoadOption(hd));
    try std.testing.expect(!isLegacyLoadOption("\x01\x00"));
    try std.testing.expect(!isLegacyLoadOption("\x01\x00\x00\x00\x04\x00A\x00"));
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
