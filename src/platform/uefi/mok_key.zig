//! The USOS key in shim's MOK list on this computer: status, saving it
//! directly while Secure Boot is off (no MokManager, no password), the
//! "remind me" setting and the per-machine report the Windows installer
//! reads (EFI\USOS\Logs\secure-boot-<SMBIOS UUID>.ini).
//!
//! Why a direct write is sound (shim 16.1 mok.c, mok_state_variables):
//! MokList must be NON_VOLATILE | BOOTSERVICE_ACCESS without RUNTIME_ACCESS
//! or shim deletes it. Only code running before ExitBootServices can create
//! such a variable, the same trust boundary MokManager relies on. USOS only
//! writes it when Secure Boot is off (anyone at the keyboard can then run
//! any code anyway) and never while Secure Boot is enforcing.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const mok_list = usos.flow.mok_list;
const policy = usos.flow.secure_boot_policy;
const handheld_rules = usos.gui.handheld;
const secure_boot = @import("secure_boot.zig");
const file_read = @import("file_read.zig");
const text_input = @import("text_input.zig");
const serial = @import("serial.zig");

const mok_list_name = std.unicode.utf8ToUtf16LeStringLiteral("MokList");
const mok_list_x_name = std.unicode.utf8ToUtf16LeStringLiteral("MokListX");
const mok_list_rt_name = std.unicode.utf8ToUtf16LeStringLiteral("MokListRT");
const mok_timeout_name = std.unicode.utf8ToUtf16LeStringLiteral("MokTimeout");

/// Certificate locations on the ESP: the short name for MokManager's file
/// browser first, then the original path.
pub const certificate_paths = [_][]const u8{ "\\USOS-KEY.cer", "\\EFI\\USOS\\ENROLL_THIS_KEY_IN_MOKMANAGER.cer" };
pub const settings_path = "\\EFI\\USOS\\usos-settings.ini";
/// usos-settings.ini key: 0 = do not offer the key on the home screen.
pub const remind_key = mok_list.remind_key;

const shim_guid align(8) = secure_boot.ShimLock.guid;

/// One variable as read at this start: GetVariable status, size, attributes
/// and (for the MOK lists) whether the USOS certificate is in it.
pub const VariableInfo = struct {
    status: uefi.Status = .not_found,
    size: usize = 0,
    attributes: u32 = 0,
    /// The USOS certificate is in the list (null: not checked / unreadable).
    has_key: ?bool = null,

    pub fn present(self: VariableInfo) bool {
        return self.status == .success or self.status == .buffer_too_small;
    }

    fn from(raw: secure_boot.RawVariable) VariableInfo {
        return .{ .status = raw.status, .size = raw.size, .attributes = raw.attributes };
    }
};

pub const Status = struct {
    state: policy.State = .unsupported,
    key: mok_list.KeyState = .unknown,
    certificate: bool = false,
    /// MokList exists but has RUNTIME_ACCESS (shim deletes such a list).
    untrusted_list: bool = false,
    /// The certificate is in MokListX (shim's deny list).
    denied: bool = false,
    /// shim's SHIM_LOCK protocol is present (USOS was started by shim).
    shim: bool = false,
    /// MokTimeout exists (MokManager will open its menu without countdown).
    timeout_pending: bool = false,

    // Raw values the gate and the guidance evaluate (logged every start).
    secure_boot_var: mok_list.Byte = .absent,
    setup_mode: mok_list.Byte = .absent,
    audit_mode: mok_list.Byte = .absent,
    deployed_mode: mok_list.Byte = .absent,
    pk: VariableInfo = .{},
    kek: VariableInfo = .{},
    db: VariableInfo = .{},
    dbx: VariableInfo = .{},
    /// Microsoft UEFI CAs in db (null: db absent, too large or malformed).
    db_cas: ?mok_list.DbCas = null,
    mok_list: VariableInfo = .{},
    mok_list_rt: VariableInfo = .{},
    mok_list_x: VariableInfo = .{},
    csm: secure_boot.Csm = .{},

    pub fn gate(self: Status) mok_list.Gate {
        return .{ .shim = self.shim, .secure_boot = self.secure_boot_var, .key = self.key, .certificate = self.certificate, .untrusted_list = self.untrusted_list };
    }

    pub fn refusal(self: Status) ?mok_list.Refusal {
        return mok_list.saveRefusal(self.gate());
    }

    pub fn canSave(self: Status) bool {
        return self.refusal() == null;
    }

    /// PK present (null: its read failed with something else than NOT_FOUND).
    pub fn pkPresent(self: Status) ?bool {
        if (self.pk.present()) return true;
        if (self.pk.status == .not_found) return false;
        return null;
    }

    pub fn guidance(self: Status) mok_list.Guidance {
        return mok_list.guidance(self.setup_mode, self.pkPresent(), self.csm.likelyOn(), self.db_cas);
    }
};

var cert_buffer: [8192]u8 = undefined;
var cert_len: usize = 0;
var list_buffer: [64 * 1024]u8 = undefined;
var merged_buffer: [72 * 1024]u8 = undefined;
var cached: ?Status = null;
/// Size-only reads: a 1-byte buffer, never NULL (some firmware rejects NULL).
var probe_byte: [1]u8 = undefined;

fn certificate(root: *uefi.protocol.File) ?[]const u8 {
    if (cert_len != 0) return cert_buffer[0..cert_len];
    for (certificate_paths) |path| {
        if (file_read.into(root, path, &cert_buffer)) |bytes| {
            // A DER certificate starts with a SEQUENCE (0x30).
            if (bytes.len > 64 and bytes[0] == 0x30) {
                cert_len = bytes.len;
                return bytes;
            }
        }
    }
    return null;
}

const Variable = struct { data: []u8, attributes: uefi.tables.RuntimeServices.VariableAttributes };

fn readShimVariable(name: [*:0]const u16, buffer: []u8) !?Variable {
    const rt = uefi.system_table.runtime_services;
    const found = (try rt.getVariable(name, &shim_guid, buffer)) orelse return null;
    return .{ .data = found[0], .attributes = found[1] };
}

pub fn status(root: *uefi.protocol.File) Status {
    if (cached) |value| return value;
    const value = compute(root);
    cached = value;
    return value;
}

pub fn refresh(root: *uefi.protocol.File) Status {
    cached = null;
    return status(root);
}

/// A MOK list: status, size, attributes and whether `der` is in it.
fn mokVariable(name: [*:0]const u16, der: ?[]const u8) VariableInfo {
    const raw = secure_boot.readRaw(name, &shim_guid, &list_buffer);
    var info = VariableInfo.from(raw);
    if (raw.status == .success) {
        if (der) |cert| info.has_key = mok_list.containsX509(raw.data, cert) catch false;
    }
    return info;
}

fn compute(root: *uefi.protocol.File) Status {
    var result = Status{ .state = secure_boot.state(), .shim = secure_boot.shimLock() != null };
    const global = &uefi.tables.global_variable;
    result.secure_boot_var = secure_boot.globalByte(std.unicode.utf8ToUtf16LeStringLiteral("SecureBoot"));
    result.setup_mode = secure_boot.globalByte(std.unicode.utf8ToUtf16LeStringLiteral("SetupMode"));
    result.audit_mode = secure_boot.globalByte(std.unicode.utf8ToUtf16LeStringLiteral("AuditMode"));
    result.deployed_mode = secure_boot.globalByte(std.unicode.utf8ToUtf16LeStringLiteral("DeployedMode"));
    result.pk = VariableInfo.from(secure_boot.readRaw(std.unicode.utf8ToUtf16LeStringLiteral("PK"), global, &probe_byte));
    result.kek = VariableInfo.from(secure_boot.readRaw(std.unicode.utf8ToUtf16LeStringLiteral("KEK"), global, &probe_byte));
    result.dbx = VariableInfo.from(secure_boot.readRaw(std.unicode.utf8ToUtf16LeStringLiteral("dbx"), &secure_boot.image_security_guid, &probe_byte));
    const db = secure_boot.readRaw(std.unicode.utf8ToUtf16LeStringLiteral("db"), &secure_boot.image_security_guid, &list_buffer);
    result.db = VariableInfo.from(db);
    if (db.status == .success) result.db_cas = mok_list.microsoftCas(db.data) catch null;
    result.csm = secure_boot.csm();

    const rt = uefi.system_table.runtime_services;
    result.timeout_pending = (rt.getVariableSize(mok_timeout_name, &shim_guid) catch null) != null;
    const der = certificate(root);
    result.certificate = der != null;
    result.mok_list_rt = mokVariable(mok_list_rt_name, der);
    result.mok_list_x = mokVariable(mok_list_x_name, der);
    result.denied = result.mok_list_x.has_key orelse false;
    result.mok_list = mokVariable(mok_list_name, der);
    if (der == null) return result;
    switch (result.mok_list.status) {
        .success => {
            const attributes: uefi.tables.RuntimeServices.VariableAttributes = @bitCast(result.mok_list.attributes);
            const trusted = mok_list.trustedAttributes(attributes.non_volatile, attributes.bootservice_access, attributes.runtime_access);
            result.untrusted_list = !trusted;
            result.key = if ((result.mok_list.has_key orelse false) and trusted) .saved else .missing;
        },
        .not_found => result.key = .missing,
        else => result.key = .unknown,
    }
    return result;
}

pub const SaveError = error{ NotAllowed, CertificateMissing, UntrustedMokList, ListTooLarge, WriteFailed, VerifyFailed };

/// Appends the USOS certificate to MokList (NV|BS, never RT), keeping every
/// key already there, then reads it back. Only while Secure Boot is off.
pub fn save(root: *uefi.protocol.File) SaveError!void {
    const current = refresh(root);
    if (current.untrusted_list) return error.UntrustedMokList;
    if (!current.canSave()) return error.NotAllowed;
    const der = certificate(root) orelse return error.CertificateMissing;
    var esl_buffer: [8192 + mok_list.list_header_size + mok_list.owner_size]u8 = undefined;
    const esl = mok_list.buildList(der, &esl_buffer) orelse return error.CertificateMissing;

    const rt = uefi.system_table.runtime_services;
    const append: uefi.tables.RuntimeServices.VariableAttributes = .{ .non_volatile = true, .bootservice_access = true, .append_write = true };
    // What MokManager does (SetVariable with EFI_VARIABLE_APPEND_WRITE).
    rt.setVariable(mok_list_name, &shim_guid, append, esl) catch |err| {
        logError("append", err);
        // Firmware without append support: write the merged list instead.
        const existing = (readShimVariable(mok_list_name, &list_buffer) catch return error.WriteFailed);
        const old: []const u8 = if (existing) |list| list.data else &.{};
        if (old.len + esl.len > merged_buffer.len) return error.ListTooLarge;
        @memcpy(merged_buffer[0..old.len], old);
        @memcpy(merged_buffer[old.len .. old.len + esl.len], esl);
        const plain: uefi.tables.RuntimeServices.VariableAttributes = .{ .non_volatile = true, .bootservice_access = true };
        rt.setVariable(mok_list_name, &shim_guid, plain, merged_buffer[0 .. old.len + esl.len]) catch |second| {
            logError("write", second);
            return error.WriteFailed;
        };
    };
    const after = refresh(root);
    if (after.key != .saved or after.untrusted_list) return error.VerifyFailed;
    serial.writeAscii("[SECURE_BOOT] USOS key saved in MokList (NV|BS)\n");
}

fn logError(what: []const u8, err: anyerror) void {
    var buffer: [96]u8 = undefined;
    serial.writeAscii(std.fmt.bufPrint(&buffer, "[SECURE_BOOT] MokList {s} failed: {s}\n", .{ what, @errorName(err) }) catch return);
}

// ------------------------------------------------------------ remind setting

pub const remindEnabled = mok_list.remindEnabled;

fn replaceFile(root: *uefi.protocol.File, file_path: []const u8, content: []const u8) !void {
    return @import("settings_store.zig").replaceFile(root, file_path, content);
}

// ------------------------------------------------------------ report

var report_buffer: [1024]u8 = undefined;
var existing_buffer: [1024]u8 = undefined;

/// Writes EFI\USOS\Logs\secure-boot-<UUID>.ini when its content changed.
/// The Windows installer matches it against this computer's SMBIOS UUID to
/// know whether the key is saved here (MokList is not visible from Windows).
pub fn writeReport(root: *uefi.protocol.File) void {
    const info = text_input.Report.smbios() orelse return;
    const uuid = info.uuid orelse return;
    var uuid_text: [36]u8 = undefined;
    const id = handheld_rules.formatUuid(uuid, &uuid_text);
    const current = status(root);
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;
    var b5: [24]u8 = undefined;
    var b6: [24]u8 = undefined;
    const content = std.fmt.bufPrint(&report_buffer,
        \\; USOS Secure Boot state of one computer (written by USOS at every UEFI start)
        \\machine_uuid={s}
        \\manufacturer={s}
        \\product={s}
        \\secure_boot={s}
        \\usos_key={s}
        \\shim={s}
        \\secure_boot_var={s}
        \\setup_mode_var={s}
        \\pk={s}
        \\mok_list={s}
        \\mok_list_rt={s}
        \\mok_list_x={s}
        \\csm_likely={s}
        \\can_save={s}
        \\build={s}
        \\
    , .{
        id,
        info.manufacturer,
        info.product,
        switch (current.state) {
            .unsupported => "unsupported",
            .disabled => "off",
            .setup_mode => "setup_mode",
            .enforcing => "on",
        },
        @tagName(current.key),
        if (current.shim) "yes" else "no",
        byteText(current.secure_boot_var, &b1),
        byteText(current.setup_mode, &b2),
        presence(current.pk, &b3),
        keyPresence(current.mok_list, &b4),
        keyPresence(current.mok_list_rt, &b5),
        keyPresence(current.mok_list_x, &b6),
        if (current.csm.likelyOn()) "yes" else "no",
        if (current.refusal()) |why| @tagName(why) else "yes",
        usos.build_info.id,
    }) catch return;
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "\\EFI\\USOS\\Logs\\secure-boot-{s}.ini", .{id}) catch return;
    if (file_read.into(root, path, &existing_buffer)) |old| {
        if (std.mem.eql(u8, old, content)) return;
    }
    // Make sure Logs exists (input_report creates it too).
    if (root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true })) |dir| {
        dir.close() catch {};
    } else |_| return;
    replaceFile(root, path, content) catch |err| logError("report", err);
}

// ------------------------------------------------------------ diagnostics

/// "0", "1", "absent" or "error:<status>".
pub fn byteText(value: mok_list.Byte, buffer: []u8) []const u8 {
    return switch (value) {
        .value => |byte| std.fmt.bufPrint(buffer, "{d}", .{byte}) catch "?",
        .absent => "absent",
        .failed => |why| std.fmt.bufPrint(buffer, "error:{s}", .{why}) catch "error",
    };
}

/// "present(<size>)", "absent" or "error:<status>".
pub fn presence(info: VariableInfo, buffer: []u8) []const u8 {
    if (info.present()) return std.fmt.bufPrint(buffer, "present({d})", .{info.size}) catch "present";
    if (info.status == .not_found) return "absent";
    return std.fmt.bufPrint(buffer, "error:{s}", .{secure_boot.statusName(info.status)}) catch "error";
}

/// "key", "no_key", "absent", "unread(<size>)" or "error:<status>".
pub fn keyPresence(info: VariableInfo, buffer: []u8) []const u8 {
    if (info.has_key) |has| return if (has) "key" else "no_key";
    if (info.status == .not_found) return "absent";
    if (info.present()) return std.fmt.bufPrint(buffer, "unread({d})", .{info.size}) catch "unread";
    return std.fmt.bufPrint(buffer, "error:{s}", .{secure_boot.statusName(info.status)}) catch "error";
}

fn variableLine(comptime print: anytype, label: []const u8, info: VariableInfo) void {
    print("  {s}: status={s}", .{ label, secure_boot.statusName(info.status) });
    if (info.present()) print(" size={d} attributes=0x{x}", .{ info.size, info.attributes });
    if (info.has_key) |has| print(" usos_key={s}", .{if (has) "yes" else "no"});
    print("\n", .{});
}

/// Lines for drivers.txt and input-devices.txt: every value the key gate
/// and the guidance evaluate, with raw GetVariable statuses, so a lost key
/// (MokList gone after a BIOS change) or a hidden variable can be told
/// apart from Setup Mode.
pub fn describe(comptime print: anytype) void {
    const remind = mok_list.remindEnabled(@import("settings_store.zig").current());
    const current = cached orelse {
        print("[SECURE BOOT]\n  (not read at this start)\n", .{});
        return;
    };
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;
    print("[SECURE BOOT] (read once at this start)\n", .{});
    print("  SecureBoot={s} SetupMode={s} AuditMode={s} DeployedMode={s} -> state={s}\n", .{
        byteText(current.secure_boot_var, &b1),
        byteText(current.setup_mode, &b2),
        byteText(current.audit_mode, &b3),
        byteText(current.deployed_mode, &b4),
        secure_boot.label(current.state),
    });
    variableLine(print, "PK", current.pk);
    variableLine(print, "KEK", current.kek);
    variableLine(print, "db", current.db);
    variableLine(print, "dbx", current.dbx);
    if (current.db_cas) |cas| {
        print("  db: microsoft_uefi_ca_2011={s} microsoft_uefi_ca_2023={s}\n", .{ yesNo(cas.ca_2011), yesNo(cas.ca_2023) });
    } else print("  db: microsoft_uefi_ca=unknown (db not read)\n", .{});
    print("  shim_lock={s} shim_loader={s} certificate={s}\n", .{ yesNo(current.shim), yesNo(secure_boot.shimOwnsLoadImage()), yesNo(current.certificate) });
    variableLine(print, "MokList", current.mok_list);
    variableLine(print, "MokListRT", current.mok_list_rt);
    variableLine(print, "MokListX", current.mok_list_x);
    print("  MokTimeout={s} untrusted_mok_list={s} denied={s}\n", .{ if (current.timeout_pending) "present" else "absent", yesNo(current.untrusted_list), yesNo(current.denied) });
    print("  csm: legacy_bios_protocol={s} BootOrder={s} boot_options={d} legacy_boot_options={d} -> likely_on={s}\n", .{
        yesNo(current.csm.legacy_bios_protocol),
        secure_boot.statusName(current.csm.boot_order_status),
        current.csm.boot_options,
        current.csm.legacy_boot_options,
        yesNo(current.csm.likelyOn()),
    });
    print("  gate: key={s} can_save={s} refusal={s} remind={s} banner={s}\n", .{
        @tagName(current.key),
        yesNo(current.canSave()),
        if (current.refusal()) |why| why.text() else "none",
        yesNo(remind),
        yesNo(mok_list.shouldOffer(current.gate(), !remind)),
    });
    const hints = current.guidance();
    print("  guidance: install_default_keys={s} disable_csm={s} microsoft_ca_missing={s}\n", .{ yesNo(hints.install_default_keys), yesNo(hints.disable_csm), yesNo(hints.microsoft_ca_missing) });
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}
