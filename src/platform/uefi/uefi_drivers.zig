//! User UEFI drivers from DATA\Drivers\UEFI\<Name>\ (one .efi plus an
//! optional driver.ini, rules in src/flow/driver_manifest.zig), started by
//! the menu after the built-in touch driver and before the pointer layer
//! enumerates, so new pointers, keyboards, disks and file systems are
//! picked up by the menu like firmware ones.
//!
//! DATA is read with USOS's own read-only NTFS reader (the same one the
//! catalog uses), so no NTFS driver is needed this early. Each driver is:
//!   1. checked: x64 PE32+, EFI boot-service or runtime driver (never an
//!      application), not a duplicate of a driver already started;
//!   2. gated: driver.ini load=, the Tools -> Drivers toggle
//!      (usos-settings.ini driver.<folder>=on|off), the hang guard
//!      (driver.<folder>=blocked) and the [match] sections (SMBIOS, PCI,
//!      ACPI);
//!   3. loaded through verified_image.zig: Secure Boot off = plain
//!      LoadImage; Secure Boot on = verified through shim (db, dbx, MOK) or
//!      the firmware; unsigned images are not even tried ("requires Secure
//!      Boot off or a signature");
//!   4. connected: when it installed Driver Binding protocols, every
//!      controller is connected recursively with just those drivers.
//! Before a driver starts, EFI\USOS\drivers-guard.txt names it and a
//! firmware watchdog is armed; if the menu never comes back (hang, crash,
//! watchdog reset) the next start finds the file and blocks that driver
//! (driver.<folder>=blocked) until it is switched on again. Nothing here
//! can stop the menu: every failure is recorded and the next driver runs.
//! Every decision is written to EFI\USOS\Logs\drivers.txt.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const manifest_rules = usos.flow.driver_manifest;
const ntfs = usos.storage.ntfs;
const data_volume = @import("data_volume.zig");
const verified_image = @import("verified_image.zig");
const secure_boot = @import("secure_boot.zig");
const settings_store = @import("settings_store.zig");
const text_input = @import("text_input.zig");
const acpi_dump = @import("acpi_dump.zig");
const file_read = @import("file_read.zig");
const serial = @import("serial.zig");
const touch_driver = @import("touch_driver.zig");

const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const max_drivers = 16;
pub const max_image_bytes = 8 * 1024 * 1024;
pub const max_manifest_bytes = 4096;
/// Seconds a driver's entry point (and its controller connection) may take
/// before the firmware watchdog resets the machine; the guard file then
/// blocks it on the next start.
pub const watchdog_seconds = 45;
const watchdog_code: u64 = 0x5553_4F53_4452_5652; // "USOSDRVR"

pub const guard_path = "\\EFI\\USOS\\drivers-guard.txt";
pub const log_path = "\\EFI\\USOS\\Logs\\drivers.txt";

pub const Outcome = enum {
    not_loaded,
    started,
    needs_signature,
    runtime_unsupported,
    duplicate,
    file_error,
    load_failed,
    start_failed,
};

pub const Entry = struct {
    folder16: [255]u16 = undefined,
    folder16_len: usize = 0,
    folder_buf: [192]u8 = undefined,
    folder_len: usize = 0,
    efi16: [255]u16 = undefined,
    efi16_len: usize = 0,
    efi_buf: [96]u8 = undefined,
    efi_len: usize = 0,
    efi_count: usize = 0,
    extra_entries: usize = 0,
    ini_buf: [max_manifest_bytes]u8 = undefined,
    ini_len: usize = 0,
    has_ini: bool = false,
    ini_error: ?anyerror = null,
    manifest: manifest_rules.Manifest = .{ .name = "" },
    image: manifest_rules.ImageInfo = .{ .check = .not_pe },
    size: usize = 0,
    sha256: [32]u8 = [_]u8{0} ** 32,
    match: manifest_rules.MatchResult = .not_matched,
    setting: manifest_rules.Setting = .none,
    decision: manifest_rules.Decision = .image_refused,
    sb_path: manifest_rules.SecureBootPath = .plain,
    outcome: Outcome = .not_loaded,
    err: ?anyerror = null,
    duplicate_of: ?[]const u8 = null,
    bindings: usize = 0,
    connected: usize = 0,
    elapsed_ms: u64 = 0,

    pub fn folder(self: *const Entry) []const u8 {
        return self.folder_buf[0..self.folder_len];
    }
    pub fn efiName(self: *const Entry) []const u8 {
        return self.efi_buf[0..self.efi_len];
    }
    pub fn name(self: *const Entry) []const u8 {
        return if (self.manifest.name.len != 0) self.manifest.name else self.folder();
    }
    /// Whether the page shows it as switched on (the toggle state).
    pub fn switchedOn(self: *const Entry) bool {
        return manifest_rules.enabled(self.manifest.load, self.setting);
    }
    pub fn toggleUsable(self: *const Entry) bool {
        return manifest_rules.settingKeyUsable(self.folder());
    }
};

pub const Scan = enum { not_run, no_data, no_folder, listed, failed };

var entries: [max_drivers]Entry = undefined;
var count: usize = 0;
var scan_result: Scan = .not_run;
var scan_error: ?anyerror = null;
var skipped_files: usize = 0;
var skipped_over_limit: usize = 0;
var guard_hit_buf: [192]u8 = undefined;
var guard_hit_len: usize = 0;
var guard_block_error: ?anyerror = null;
var sb_state: usos.flow.secure_boot_policy.State = .unsupported;
var root_dir: ?*uefi.protocol.File = null;

pub fn list() []Entry {
    return entries[0..count];
}

pub fn scanResult() Scan {
    return scan_result;
}

/// Loads the user drivers. Never fails; see drivers.txt for the result.
pub fn start(root: *uefi.protocol.File) void {
    root_dir = root;
    count = 0;
    skipped_files = 0;
    skipped_over_limit = 0;
    scan_error = null;
    sb_state = secure_boot.state();
    checkGuard(root);
    const bs = uefi.system_table.boot_services orelse return;
    const catalog = uefi.pool_allocator.create(data_volume.Catalog) catch |err| {
        scan_result = .failed;
        scan_error = err;
        return;
    };
    defer uefi.pool_allocator.destroy(catalog);
    catalog.* = data_volume.openCatalog() catch |err| {
        scan_result = .no_data;
        scan_error = err;
        return;
    };
    discover(catalog) catch |err| {
        if (err == error.NotFound or err == error.NotDirectory) {
            scan_result = .no_folder;
            return;
        }
        scan_result = .failed;
        scan_error = err;
        // Keep what was listed before the failure.
    };
    if (scan_result != .failed) scan_result = .listed;
    var environment = Environment{};
    for (entries[0..count]) |*entry| {
        prepare(catalog, entry, &environment);
        if (entry.decision != .load) continue;
        startOne(bs, root, catalog, entry);
    }
    if (count != 0) say("[USER_DRIVERS] done\n");
}

// ------------------------------------------------------------ guard

fn checkGuard(root: *uefi.protocol.File) void {
    guard_hit_len = 0;
    guard_block_error = null;
    var buffer: [256]u8 = undefined;
    const text = file_read.into(root, guard_path, &buffer) orelse return;
    const folder_name = std.mem.trim(u8, text, " \t\r\n\x00");
    const n = @min(folder_name.len, guard_hit_buf.len);
    @memcpy(guard_hit_buf[0..n], folder_name[0..n]);
    guard_hit_len = n;
    if (n != 0 and manifest_rules.settingKeyUsable(folder_name)) {
        var key: [128]u8 = undefined;
        const setting_key = std.fmt.bufPrint(&key, "{s}{s}", .{ manifest_rules.settingKeyPrefix(), folder_name }) catch "";
        settings_store.set(setting_key, "blocked") catch |err| {
            guard_block_error = err;
        };
    }
    deleteGuard(root);
    say("[USER_DRIVERS] guard: previous start did not return from a driver; blocked it\n");
}

fn writeGuard(root: *uefi.protocol.File, folder_name: []const u8) void {
    settings_store.replaceFile(root, guard_path, folder_name) catch |err| {
        say("[USER_DRIVERS] guard write failed: ");
        say(@errorName(err));
        say("\n");
    };
}

fn deleteGuard(root: *uefi.protocol.File) void {
    const file = root.open(wide(guard_path), .read_write, .{}) catch return;
    _ = file.delete() catch {};
}

pub fn guardHit() []const u8 {
    return guard_hit_buf[0..guard_hit_len];
}

// ------------------------------------------------------------ discovery

const drivers_path = [_][]const u16{ wide("Drivers"), wide("UEFI") };

fn discover(catalog: *data_volume.Catalog) !void {
    var skip: usize = 0;
    while (true) {
        var items: [8]ntfs.DirectoryItem = undefined;
        const page = try ntfs.listDirectoryPage(catalog.fs, catalog.reader(), &drivers_path, skip, &items);
        for (items[0..page.count]) |item| {
            const item_name = item.name[0..item.name_len];
            if (isDotName(item_name)) continue;
            if (!item.isDirectory()) {
                skipped_files += 1;
                continue;
            }
            if (count == max_drivers) {
                skipped_over_limit += 1;
                continue;
            }
            const entry = &entries[count];
            entry.* = .{};
            @memcpy(entry.folder16[0..item_name.len], item_name);
            entry.folder16_len = item_name.len;
            entry.folder_len = utf16ToUtf8Lossy(item_name, &entry.folder_buf);
            count += 1;
        }
        if (!page.has_more or page.count == 0) break;
        skip += page.count;
    }
    // Stable order independent of the NTFS index: by folder name.
    // (Insertion sort with swaps: Entry is large and there are few.)
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0 and std.ascii.lessThanIgnoreCase(entries[j].folder(), entries[j - 1].folder())) : (j -= 1) {
            std.mem.swap(Entry, &entries[j], &entries[j - 1]);
        }
    }
}

fn isDotName(value: []const u16) bool {
    return (value.len == 1 and value[0] == '.') or (value.len == 2 and value[0] == '.' and value[1] == '.');
}

/// Lists one driver folder: the .efi (alphabetically first when there are
/// several) and driver.ini.
fn listFolder(catalog: *data_volume.Catalog, entry: *Entry) !void {
    const path = [_][]const u16{ drivers_path[0], drivers_path[1], entry.folder16[0..entry.folder16_len] };
    var skip: usize = 0;
    while (true) {
        var items: [8]ntfs.DirectoryItem = undefined;
        const page = try ntfs.listDirectoryPage(catalog.fs, catalog.reader(), &path, skip, &items);
        for (items[0..page.count]) |item| {
            const item_name = item.name[0..item.name_len];
            if (isDotName(item_name)) continue;
            if (item.isDirectory()) {
                entry.extra_entries += 1;
                continue;
            }
            if (endsWithIgnoreCase16(item_name, ".efi")) {
                entry.efi_count += 1;
                if (entry.efi16_len == 0 or lessThan16(item_name, entry.efi16[0..entry.efi16_len])) {
                    @memcpy(entry.efi16[0..item_name.len], item_name);
                    entry.efi16_len = item_name.len;
                    entry.size = @intCast(@min(item.size, std.math.maxInt(usize)));
                }
            } else if (equalsIgnoreCase16(item_name, "driver.ini")) {
                entry.has_ini = true;
            } else entry.extra_entries += 1;
        }
        if (!page.has_more or page.count == 0) break;
        skip += page.count;
    }
    entry.efi_len = utf16ToUtf8Lossy(entry.efi16[0..entry.efi16_len], &entry.efi_buf);
}

var ini_file: ntfs.File = .{};
var image_file: ntfs.File = .{};

fn readIni(catalog: *data_volume.Catalog, entry: *Entry) !void {
    const path = [_][]const u16{ drivers_path[0], drivers_path[1], entry.folder16[0..entry.folder16_len], wide("driver.ini") };
    try ntfs.openFile(catalog.fs, catalog.reader(), &path, &ini_file);
    const size = ini_file.size();
    if (size > entry.ini_buf.len) return error.ManifestTooLarge;
    const n: usize = @intCast(size);
    try ini_file.readAt(catalog.fs, catalog.reader(), 0, entry.ini_buf[0..n]);
    entry.ini_len = n;
}

// ------------------------------------------------------------ decision

const Environment = struct {
    pci_scanned: bool = false,
    pci: [256]manifest_rules.PciId = undefined,
    pci_count: usize = 0,

    fn view(self: *Environment) manifest_rules.Environment {
        return .{ .smbios = text_input.Report.smbios(), .context = self, .hasPci = hasPci, .hasAcpiId = hasAcpi };
    }

    fn hasPci(context: ?*anyopaque, id: manifest_rules.PciId) bool {
        const self: *Environment = @ptrCast(@alignCast(context.?));
        if (!self.pci_scanned) {
            self.pci_scanned = true;
            self.pci_count = scanPci(&self.pci);
        }
        for (self.pci[0..self.pci_count]) |present| {
            if (present.vendor == id.vendor and present.device == id.device) return true;
        }
        return false;
    }

    fn hasAcpi(_: ?*anyopaque, id: []const u8) bool {
        return acpi_dump.amlContainsId(id);
    }
};

/// EFI_PCI_IO_PROTOCOL: only Pci.Read is used (config space dword 0).
const PciIo = extern struct {
    poll_mem: *const anyopaque,
    poll_io: *const anyopaque,
    mem_read: *const anyopaque,
    mem_write: *const anyopaque,
    io_read: *const anyopaque,
    io_write: *const anyopaque,
    pci_read: *const fn (*PciIo, u32, u32, usize, *anyopaque) callconv(uefi.cc) uefi.Status,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x4cf5b200,
        .time_mid = 0x68b8,
        .time_high_and_version = 0x4ca5,
        .clock_seq_high_and_reserved = 0x9e,
        .clock_seq_low = 0xec,
        .node = .{ 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a },
    };
    const width_uint32: u32 = 2;
};

fn scanPci(out: []manifest_rules.PciId) usize {
    const bs = uefi.system_table.boot_services orelse return 0;
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &PciIo.guid }) catch null) orelse return 0;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    var n: usize = 0;
    for (handles) |handle| {
        if (n == out.len) break;
        const io = (bs.handleProtocol(PciIo, handle) catch continue) orelse continue;
        var dword: u32 = 0xFFFF_FFFF;
        if (io.pci_read(io, PciIo.width_uint32, 0, 1, @ptrCast(&dword)) != .success) continue;
        const vendor: u16 = @truncate(dword);
        if (vendor == 0xFFFF or vendor == 0) continue;
        out[n] = .{ .vendor = vendor, .device = @truncate(dword >> 16) };
        n += 1;
    }
    return n;
}

var image_buffer: ?[]align(8) u8 = null;

fn prepare(catalog: *data_volume.Catalog, entry: *Entry, environment: *Environment) void {
    listFolder(catalog, entry) catch |err| {
        entry.err = err;
    };
    if (entry.has_ini) {
        readIni(catalog, entry) catch |err| {
            entry.ini_error = err;
            entry.ini_len = 0;
        };
    }
    entry.manifest = manifest_rules.parse(entry.ini_buf[0..entry.ini_len], entry.folder());
    entry.setting = if (entry.toggleUsable()) manifest_rules.parseSetting(settings_store.current(), entry.folder()) else .none;
    entry.match = manifest_rules.evaluate(&entry.manifest, environment.view());

    if (entry.efi16_len == 0 or entry.err != null) {
        entry.decision = manifest_rules.decide(&entry.manifest, entry.setting, .not_pe, entry.match);
        if (entry.decision == .image_refused) {
            entry.outcome = .file_error;
            if (entry.err == null) entry.err = error.NoEfiFile;
        }
        return;
    }
    // Header check before any gate that needs the image: read it once.
    const bytes = readImage(catalog, entry) catch |err| {
        entry.err = err;
        entry.decision = manifest_rules.decide(&entry.manifest, entry.setting, .not_pe, entry.match);
        if (entry.decision == .image_refused) entry.outcome = .file_error;
        return;
    };
    entry.image = manifest_rules.inspectImage(bytes, manifest_rules.machine_x64);
    std.crypto.hash.sha2.Sha256.hash(bytes, &entry.sha256, .{});
    entry.decision = manifest_rules.decide(&entry.manifest, entry.setting, entry.image.check, entry.match);
    entry.sb_path = manifest_rules.secureBootPath(sb_state, entry.image.signed);
    releaseImage();
}

fn readImage(catalog: *data_volume.Catalog, entry: *Entry) ![]const u8 {
    const path = [_][]const u16{ drivers_path[0], drivers_path[1], entry.folder16[0..entry.folder16_len], entry.efi16[0..entry.efi16_len] };
    try ntfs.openFile(catalog.fs, catalog.reader(), &path, &image_file);
    const size = image_file.size();
    if (size == 0) return error.EmptyFile;
    if (size > max_image_bytes) return error.ImageTooLarge;
    const n: usize = @intCast(size);
    const bs = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    if (image_buffer) |old| bs.freePool(old.ptr) catch {};
    image_buffer = null;
    const buffer = try bs.allocatePool(.loader_data, n);
    image_buffer = buffer;
    try image_file.readAt(catalog.fs, catalog.reader(), 0, buffer[0..n]);
    entry.size = n;
    return buffer[0..n];
}

fn releaseImage() void {
    const bs = uefi.system_table.boot_services orelse return;
    if (image_buffer) |buffer| bs.freePool(buffer.ptr) catch {};
    image_buffer = null;
}

// ------------------------------------------------------------ loading

/// EFI_DRIVER_BINDING_PROTOCOL GUID (only handles are compared).
const driver_binding_guid align(8) = uefi.Guid{
    .time_low = 0x18a031ab,
    .time_mid = 0xb443,
    .time_high_and_version = 0x4d1a,
    .clock_seq_high_and_reserved = 0xa5,
    .clock_seq_low = 0xc0,
    .node = .{ 0x0c, 0x09, 0x26, 0x1e, 0x9f, 0x71 },
};

fn startOne(bs: *uefi.tables.BootServices, root: *uefi.protocol.File, catalog: *data_volume.Catalog, entry: *Entry) void {
    defer releaseImage();
    say("[USER_DRIVERS] ");
    say(entry.folder());
    // Duplicates: the same bytes as a driver already started (another
    // folder or the built-in touch driver) would install everything twice.
    for (entries[0..count]) |*other| {
        if (other == entry) break;
        if (other.outcome == .started and std.mem.eql(u8, &other.sha256, &entry.sha256)) {
            entry.outcome = .duplicate;
            entry.duplicate_of = other.folder();
            say(" duplicate\n");
            return;
        }
    }
    if (touch_driver.startedImageHash()) |hash| {
        if (std.mem.eql(u8, &hash, &entry.sha256)) {
            entry.outcome = .duplicate;
            entry.duplicate_of = "TouchI2cDxe (built-in)";
            say(" duplicate of the built-in touch driver\n");
            return;
        }
    }
    if (entry.sb_path == .needs_signature) {
        entry.outcome = .needs_signature;
        say(" unsigned, Secure Boot on: skipped\n");
        return;
    }
    if (entry.image.check == .runtime_driver and secure_boot.shimOwnsLoadImage()) {
        // USOS's own PE loader (shim 16) allocates boot-services memory.
        entry.outcome = .runtime_unsupported;
        say(" runtime driver under the shim loader: skipped\n");
        return;
    }
    // prepare() released its copy after the header check; read it again.
    const bytes = readImage(catalog, entry) catch |err| {
        entry.outcome = .file_error;
        entry.err = err;
        say(" read failed\n");
        return;
    };

    var before: [128]uefi.Handle = undefined;
    const before_count = bindingHandles(bs, &before);
    writeGuard(root, entry.folder());
    bs.setWatchdogTimer(watchdog_seconds, watchdog_code, null) catch {};
    const started_at = timestampMs();
    const result = verified_image.startDriverWithOptions(bytes, null, null);
    if (result) |_| {
        entry.outcome = .started;
        var after: [128]uefi.Handle = undefined;
        const after_count = bindingHandles(bs, &after);
        var list_buf: [17]?uefi.Handle = [_]?uefi.Handle{null} ** 17;
        var new_count: usize = 0;
        for (after[0..after_count]) |handle| {
            if (std.mem.indexOfScalar(uefi.Handle, before[0..before_count], handle) != null) continue;
            if (new_count == 16) break;
            list_buf[new_count] = handle;
            new_count += 1;
        }
        entry.bindings = new_count;
        if (new_count != 0) entry.connected = connectAll(bs, @ptrCast(&list_buf));
    } else |err| {
        entry.err = err;
        entry.outcome = switch (err) {
            error.SecureBootRejected, error.SecurityViolation, error.AccessDenied => .needs_signature,
            error.DriverStartFailed => .start_failed,
            else => .load_failed,
        };
    }
    entry.elapsed_ms = timestampMs() -| started_at;
    bs.setWatchdogTimer(0, 0, null) catch {};
    deleteGuard(root);
    say(switch (entry.outcome) {
        .started => " started\n",
        .needs_signature => " rejected by Secure Boot\n",
        else => " failed\n",
    });
}

fn bindingHandles(bs: *uefi.tables.BootServices, out: []uefi.Handle) usize {
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &driver_binding_guid }) catch null) orelse return 0;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    const n = @min(handles.len, out.len);
    @memcpy(out[0..n], handles[0..n]);
    return n;
}

/// ConnectController(every handle, only the new drivers, recursive).
fn connectAll(bs: *uefi.tables.BootServices, drivers: [*:null]?uefi.Handle) usize {
    const handles = (bs.locateHandleBuffer(.all_handles) catch null) orelse return 0;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    var connected: usize = 0;
    for (handles) |handle| {
        if (bs.connectController(handle, drivers, null, true)) |_| {
            connected += 1;
        } else |_| {}
    }
    return connected;
}

fn timestampMs() u64 {
    const result = uefi.system_table.runtime_services.getTime() catch return 0;
    const time = result[0];
    return ((@as(u64, time.hour) * 60 + time.minute) * 60 + time.second) * 1000 + time.nanosecond / 1_000_000;
}

fn say(text: []const u8) void {
    serial.writeAscii(text);
}

// ------------------------------------------------------------ text helpers

fn utf16ToUtf8Lossy(input: []const u16, out: []u8) usize {
    var used: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        var code: u21 = input[index];
        index += 1;
        if (code >= 0xD800 and code <= 0xDBFF and index < input.len and input[index] >= 0xDC00 and input[index] <= 0xDFFF) {
            code = 0x10000 + ((code - 0xD800) << 10) + (input[index] - 0xDC00);
            index += 1;
        } else if (code >= 0xD800 and code <= 0xDFFF) code = '?';
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(code, &bytes) catch 1;
        if (n == 1 and code > 0x7f) bytes[0] = '?';
        if (used + n > out.len) break;
        @memcpy(out[used .. used + n], bytes[0..n]);
        used += n;
    }
    return used;
}

fn lower16(unit: u16) u16 {
    return if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
}

fn endsWithIgnoreCase16(value: []const u16, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    const tail = value[value.len - suffix.len ..];
    for (tail, suffix) |a, b| if (lower16(a) != std.ascii.toLower(b)) return false;
    return true;
}

fn equalsIgnoreCase16(value: []const u16, ascii: []const u8) bool {
    return value.len == ascii.len and endsWithIgnoreCase16(value, ascii);
}

fn lessThan16(a: []const u16, b: []const u16) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (lower16(x) != lower16(y)) return lower16(x) < lower16(y);
    }
    return a.len < b.len;
}

// ------------------------------------------------------------ reports

pub fn outcomeText(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .not_loaded => "not loaded",
        .started => "started",
        .needs_signature => "not loaded: requires Secure Boot off or a signature (db or an enrolled MOK)",
        .runtime_unsupported => "not loaded: runtime drivers cannot be started through the shim 16 loader",
        .duplicate => "not loaded: same file as a driver already started",
        .file_error => "not loaded: file missing or unreadable",
        .load_failed => "failed: LoadImage refused the image",
        .start_failed => "failed: the driver's entry point returned an error",
    };
}

fn matchText(entry: *const Entry, buffer: []u8) []const u8 {
    return switch (entry.match) {
        .everywhere => "every computer (no [match] section)",
        .matched => |index| std.fmt.bufPrint(buffer, "matched [match] #{d} of {d}", .{ index + 1, entry.manifest.match_count }) catch "matched",
        .not_matched => "no [match] section matches this computer",
    };
}

fn imageText(info: manifest_rules.ImageInfo, buffer: []u8) []const u8 {
    return switch (info.check) {
        .boot_service_driver => "x64 boot-service driver",
        .runtime_driver => "x64 runtime driver",
        .not_pe => "not a PE32+ image",
        .wrong_machine => |machine| std.fmt.bufPrint(buffer, "wrong architecture ({s}, machine 0x{x:0>4}); the menu needs x64", .{ manifest_rules.machineName(machine), machine }) catch "wrong architecture",
        .application => "EFI application (put boot tools in Utilities\\<Name>\\Images instead)",
        .other_subsystem => |subsystem| std.fmt.bufPrint(buffer, "unsupported subsystem {d}", .{subsystem}) catch "unsupported subsystem",
    };
}

fn sbText(entry: *const Entry) []const u8 {
    if (!sb_state.enforced()) return "off (loaded without a signature check)";
    return switch (entry.sb_path) {
        .needs_signature => "on: image is unsigned -> requires Secure Boot off or a signature",
        .verify => if (entry.outcome == .started) "on: signature verified (db or MOK)" else if (entry.outcome == .needs_signature) "on: signature not trusted (not in db or MOK)" else "on: signed (verified when loaded)",
        .plain => "off",
    };
}

/// Lines for drivers.txt and input-devices.txt.
pub fn describe(comptime print: anytype) void {
    print("[USER UEFI DRIVERS] DATA\\Drivers\\UEFI\n", .{});
    print("  secure_boot={s} shim_loader={s}\n", .{ secure_boot.label(sb_state), if (secure_boot.shimOwnsLoadImage()) "yes" else "no" });
    print("  scan={s}", .{@tagName(scan_result)});
    if (scan_error) |err| print(" error={s}", .{@errorName(err)});
    print(" drivers={d}\n", .{count});
    if (skipped_files != 0) print("  ignored_files={d} (each driver needs its own folder: Drivers\\UEFI\\<Name>\\<file>.efi)\n", .{skipped_files});
    if (skipped_over_limit != 0) print("  ignored_folders={d} (limit {d} drivers)\n", .{ skipped_over_limit, max_drivers });
    if (guard_hit_len != 0) {
        print("  guard: the previous start stopped inside driver \"{s}\" -> blocked", .{guardHit()});
        if (guard_block_error) |err| print(" (settings write failed: {s})", .{@errorName(err)});
        print("\n", .{});
    }
    for (entries[0..count]) |*entry| {
        var buffer: [96]u8 = undefined;
        var image_buffer_text: [96]u8 = undefined;
        print("- folder=\"{s}\" name=\"{s}\" type={s}\n", .{ entry.folder(), entry.name(), @tagName(entry.manifest.type) });
        print("  file=\"{s}\" bytes={d} efi_files={d} other_entries={d}\n", .{ entry.efiName(), entry.size, entry.efi_count, entry.extra_entries });
        if (entry.efi_count > 1) print("  note: several .efi files; using the first by name\n", .{});
        if (entry.has_ini) {
            print("  driver.ini: load={s} match_sections={d} ignored_lines={d}", .{ @tagName(entry.manifest.load), entry.manifest.match_count, entry.manifest.ignored_lines });
            if (entry.ini_error) |err| print(" read_error={s}", .{@errorName(err)});
            print("\n", .{});
        } else print("  driver.ini: none (defaults: type=other load=auto, every computer)\n", .{});
        print("  image={s} signed={s}\n", .{ imageText(entry.image, &image_buffer_text), if (entry.image.signed) "yes" else "no" });
        print("  match={s}\n", .{matchText(entry, &buffer)});
        print("  setting={s}\n", .{@tagName(entry.setting)});
        print("  decision={s}\n", .{entry.decision.text()});
        print("  secure_boot={s}\n", .{sbText(entry)});
        print("  result={s}", .{if (entry.decision == .load) outcomeText(entry.outcome) else "not loaded"});
        if (entry.err) |err| print(" error={s}", .{@errorName(err)});
        if (entry.duplicate_of) |other| print(" duplicate_of=\"{s}\"", .{other});
        print("\n", .{});
        if (entry.outcome == .started) print("  driver_bindings={d} controllers_connected={d} time_ms={d}\n", .{ entry.bindings, entry.connected, entry.elapsed_ms });
    }
}

var report_buffer: [24 * 1024]u8 = undefined;
var report_used: usize = 0;

fn reportPrint(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(report_buffer[report_used..], fmt, args) catch return;
    report_used += written.len;
}

/// EFI\USOS\Logs\drivers.txt: built-in drivers and every user driver.
pub fn writeReport(root: *uefi.protocol.File) void {
    report_used = 0;
    reportPrint("USOS UEFI drivers report\nbuild={s}\n\n", .{usos.build_info.id});
    reportPrint("[BUILT-IN] NTFS (\\EFI\\USOS\\ntfs_x64.efi)\n  loaded when Windows setup starts from WORK (not needed by the menu: DATA is read by USOS's own NTFS reader)\n\n", .{});
    touch_driver.describe(reportPrint);
    reportPrint("\n", .{});
    describe(reportPrint);
    if (root.open(wide("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true })) |logs| {
        logs.close() catch {};
    } else |_| return;
    settings_store.replaceFile(root, log_path, report_buffer[0..report_used]) catch |err| {
        say("[USER_DRIVERS] drivers.txt write failed: ");
        say(@errorName(err));
        say("\n");
        return;
    };
    serial.writeAscii("[DRIVERS_REPORT BEGIN]\n");
    serial.writeAscii(report_buffer[0..report_used]);
    serial.writeAscii("[DRIVERS_REPORT END]\n");
}

// ------------------------------------------------------------ toggles

/// Tools -> Drivers: switch a user driver on or off (next start).
pub fn setSwitched(entry: *Entry, on: bool) !void {
    if (!entry.toggleUsable()) return error.FolderNameNotUsable;
    var key: [128]u8 = undefined;
    const setting_key = try std.fmt.bufPrint(&key, "{s}{s}", .{ manifest_rules.settingKeyPrefix(), entry.folder() });
    try settings_store.set(setting_key, if (on) "on" else "off");
    entry.setting = if (on) .on else .off;
}

test "UTF-16 names convert to UTF-8 and compare case-insensitively" {
    var out: [32]u8 = undefined;
    const name = [_]u16{ 'Z', 0x0142, 'o', 0xD83D, 0xDE00, 0xD800 };
    const n = utf16ToUtf8Lossy(&name, &out);
    try std.testing.expectEqualStrings("Z\xc5\x82o\xf0\x9f\x98\x80?", out[0..n]);
    try std.testing.expect(endsWithIgnoreCase16(&[_]u16{ 'A', '.', 'E', 'f', 'I' }, ".efi"));
    try std.testing.expect(equalsIgnoreCase16(&[_]u16{ 'D', 'r', 'i', 'v', 'e', 'r', '.', 'I', 'N', 'I' }, "driver.ini"));
    try std.testing.expect(lessThan16(&[_]u16{ 'a', 'b' }, &[_]u16{ 'A', 'C' }));
}
