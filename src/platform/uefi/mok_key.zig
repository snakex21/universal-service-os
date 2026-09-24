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
const mok_timeout_name = std.unicode.utf8ToUtf16LeStringLiteral("MokTimeout");

/// Certificate locations on the ESP: the short name for MokManager's file
/// browser first, then the original path.
pub const certificate_paths = [_][]const u8{ "\\USOS-KEY.cer", "\\EFI\\USOS\\ENROLL_THIS_KEY_IN_MOKMANAGER.cer" };
pub const settings_path = "\\EFI\\USOS\\usos-settings.ini";
/// usos-settings.ini key: 0 = do not offer the key on the home screen.
pub const remind_key = mok_list.remind_key;

const shim_guid align(8) = secure_boot.ShimLock.guid;

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

    /// A platform key is enrolled, so Secure Boot can be turned on.
    pub fn canEnable(self: Status) bool {
        return self.state == .disabled or self.state == .enforcing;
    }

    pub fn canSave(self: Status) bool {
        return mok_list.canSave(self.state, self.key, self.certificate) and !self.untrusted_list;
    }
};

var cert_buffer: [8192]u8 = undefined;
var cert_len: usize = 0;
var list_buffer: [64 * 1024]u8 = undefined;
var merged_buffer: [72 * 1024]u8 = undefined;
var cached: ?Status = null;

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

fn compute(root: *uefi.protocol.File) Status {
    var result = Status{ .state = secure_boot.state(), .shim = secure_boot.shimLock() != null };
    const der = certificate(root);
    result.certificate = der != null;
    if (result.state == .unsupported) return result;
    const rt = uefi.system_table.runtime_services;
    result.timeout_pending = (rt.getVariableSize(mok_timeout_name, &shim_guid) catch null) != null;
    const cert = der orelse return result;
    if (readShimVariable(mok_list_name, &list_buffer)) |maybe| {
        if (maybe) |list| {
            const trusted = mok_list.trustedAttributes(list.attributes.non_volatile, list.attributes.bootservice_access, list.attributes.runtime_access);
            result.untrusted_list = !trusted;
            const present = mok_list.containsX509(list.data, cert) catch false;
            result.key = if (present and trusted) .saved else .missing;
        } else result.key = .missing;
    } else |_| result.key = .unknown;
    if (readShimVariable(mok_list_x_name, &list_buffer)) |maybe| {
        if (maybe) |list| result.denied = mok_list.containsX509(list.data, cert) catch false;
    } else |_| {}
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

var settings_out: [4096]u8 = undefined;

/// Rewrites usos-settings.ini with the reminder on or off. Returns the new
/// file content (the caller keeps it as the current settings).
pub fn setRemind(root: *uefi.protocol.File, settings: []const u8, enabled: bool) ![]const u8 {
    const content = mok_list.withSetting(settings, remind_key, if (enabled) "1" else "0", &settings_out) orelse return error.SettingsTooLarge;
    try replaceFile(root, settings_path, content);
    return content;
}

fn replaceFile(root: *uefi.protocol.File, path: []const u8, content: []const u8) !void {
    var name: [128]u16 = undefined;
    const units = try std.unicode.utf8ToUtf16Le(&name, path);
    name[units] = 0;
    const z: [*:0]const u16 = @ptrCast(&name);
    // UEFI files have no truncate: delete and create again.
    if (root.open(z, .read_write, .{})) |old| {
        _ = old.delete() catch {};
    } else |_| {}
    const file = try root.open(z, .read_write_create, .{});
    defer file.close() catch {};
    var written: usize = 0;
    while (written < content.len) {
        const n = try file.write(content[written..]);
        if (n == 0) return error.ShortWrite;
        written += n;
    }
    try file.flush();
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
    const content = std.fmt.bufPrint(&report_buffer,
        \\; USOS Secure Boot state of one computer (written by USOS at every UEFI start)
        \\machine_uuid={s}
        \\manufacturer={s}
        \\product={s}
        \\secure_boot={s}
        \\usos_key={s}
        \\shim={s}
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
