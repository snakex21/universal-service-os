// Shared by the native UEFI menu/start and read-only host tests.
const std = @import("std");
const udf = @import("image_probe/udf.zig");
const wim = @import("image_probe/wim_setup.zig");
const directory = @import("catalog/directory_source.zig");
const FixedText = @import("core/fixed_text.zig").FixedText;

/// USOS-managed home of the PE10 donor (created by install/update, never
/// listed as a system). The installer moves a donor found in the legacy
/// location here.
pub const donor_directory = "Programs/USOS/WinPE";
/// Where donors lived before build B260925; read for one release only.
pub const legacy_donor_directory = "Systems/Windows/Windows 10/Images";
/// Lookup order: the managed folder first, then the legacy location.
pub const donor_directories = [_][]const u8{ donor_directory, legacy_donor_directory };
pub const max_donor_entries = 256;
pub const boot_paths = [_][]const u8{ "boot/bcd", "boot/boot.sdi", "sources/boot.wim" };
pub const max_boot_file_size = 1024 * 1024 * 1024;

pub const Inspection = struct {
    mode: wim.Win7Mode,
    selected_setup: wim.Setup,
    boot_setup: wim.Setup,
    donor_name: FixedText = .{},
    /// One of `donor_directories` (valid when `donor_name` is set).
    donor_directory: []const u8 = donor_directory,
    nvme_packages: bool,

    pub fn bootName(self: *const Inspection, selected_name: []const u8) []const u8 {
        return if (self.mode == .original) self.donor_name.slice() else selected_name;
    }
};

fn metadata(allocator: std.mem.Allocator, iso: anytype, node: *const udf.Node, header: *[124]u8) ![]u8 {
    try udf.readNodeAt(iso, node, 0, header);
    const resource = try wim.xmlResource(header, node.size);
    const bytes = try allocator.alloc(u8, resource.size);
    errdefer allocator.free(bytes);
    try udf.readNodeAt(iso, node, resource.offset, bytes);
    return bytes;
}

pub fn setupInfo(allocator: std.mem.Allocator, iso: anytype) !wim.Setup {
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, "sources/boot.wim", &node) or node.is_directory or node.size > max_boot_file_size) return error.InvalidWindowsBootFile;
    var header: [124]u8 = undefined;
    const bytes = try metadata(allocator, iso, &node, &header);
    defer allocator.free(bytes);
    return wim.detectX64Setup(bytes, try wim.bootIndex(&header));
}

pub fn validateBootFiles(iso: anytype) !void {
    for (boot_paths) |path| {
        var node: udf.Node = undefined;
        if (!try udf.openPath(iso, path, &node) or node.is_directory or node.size == 0 or node.size > max_boot_file_size) return error.InvalidWindowsBootFile;
    }
}

fn validateSetup(iso: anytype) !void {
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, "sources/setup.exe", &node) or node.is_directory or node.size == 0) return error.WindowsSetupMissing;
}

pub fn inspectSelected(allocator: std.mem.Allocator, iso: anytype) !Inspection {
    const setup = try setupInfo(allocator, iso);
    try validateSetup(iso);
    var node: udf.Node = undefined;
    const has_wim = try udf.openPath(iso, "sources/install.wim", &node);
    if (!has_wim and !try udf.openPath(iso, "sources/install.esd", &node)) return error.WindowsInstallImageMissing;
    if (node.is_directory or node.size == 0) return error.WindowsInstallImageMissing;
    var header: [124]u8 = undefined;
    const bytes = try metadata(allocator, iso, &node, &header);
    defer allocator.free(bytes);
    const target = try wim.inspectWin7Install(bytes);
    if (target.count != std.mem.readInt(u32, header[44..48], .little)) return error.InvalidWimXml;
    const mode = wim.classifyWin7Boot(setup);
    if (mode == .unsupported) return error.UnsupportedWindowsSetupVersion;
    if (mode == .original and !has_wim) return error.Windows7OriginalRequiresInstallWim;
    if (mode == .hybrid) try validateBootFiles(iso);
    return .{ .mode = mode, .selected_setup = setup, .boot_setup = setup, .nvme_packages = target.sp1 };
}

// Vista's original PE has no native xHCI support. Use the same strictly
// validated PE10 donor, while keeping Vista Setup and install.wim together.
pub fn inspectVista(allocator: std.mem.Allocator, iso: anytype) !Inspection {
    try validateSetup(iso);
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, "sources/install.wim", &node) or node.is_directory or node.size == 0)
        return error.WindowsInstallImageMissing;
    var header: [124]u8 = undefined;
    const bytes = try metadata(allocator, iso, &node, &header);
    defer allocator.free(bytes);
    const target = try wim.inspectVistaSp2Install(bytes);
    if (target.count != std.mem.readInt(u32, header[44..48], .little)) return error.InvalidWimXml;
    const vista = wim.Setup{ .index = 0, .major = 6, .minor = 0, .build = 6002 };
    return .{ .mode = .original, .selected_setup = vista, .boot_setup = vista, .nvme_packages = false };
}

pub fn inspectDonor(allocator: std.mem.Allocator, iso: anytype) !wim.Setup {
    const setup = try setupInfo(allocator, iso);
    if (!setup.isWindows10Donor()) return error.Windows10PeDonorWrongVersion;
    try validateBootFiles(iso);
    // A standalone PE/recovery ISO is not an installation donor. This checks
    // optical Setup resources; startup also requires X:\sources\setup.exe in
    // the booted WIM before any servicing/finalizer helper can run.
    try validateSetup(iso);
    return setup;
}

// context.probeDonor(directory, name) performs bounded optical metadata reads.
// Directory names only filter the extension, never establish Windows identity.
// No fallback to PE7, no arbitrary first-match selection, and no donor access
// for hybrids. The managed folder (Programs/USOS/WinPE) wins; the legacy
// Windows 10/Images folder is only scanned when the managed one has no
// valid donor (a missing folder counts as empty).
pub fn resolveDonor(selected: Inspection, source: directory.Source, context: anytype) !Inspection {
    if (selected.mode == .hybrid) return selected;
    if (selected.mode != .original) return error.UnsupportedWindows7InstallTarget;
    var iso_count: usize = 0;
    for (donor_directories) |folder| {
        if (try resolveDonorIn(selected, source, context, folder, &iso_count)) |result| return result;
    }
    return if (iso_count == 0) error.Windows10PeDonorMissing else error.Windows10PeDonorInvalid;
}

fn resolveDonorIn(selected: Inspection, source: directory.Source, context: anytype, folder: []const u8, iso_count: *usize) !?Inspection {
    var result = selected;
    var entries: [8]directory.Entry = undefined;
    var skip: usize = 0;
    var found = false;
    while (true) {
        const page = source.listPage(folder, skip, &entries) catch |err| switch (err) {
            error.NotFound, error.FileNotFound, error.PathNotFound => return null,
            else => return err,
        };
        if (page.count > entries.len or page.count > max_donor_entries - skip or
            (page.has_more and (page.count == 0 or skip + page.count == max_donor_entries))) return error.Windows10PeDonorScanLimit;
        for (entries[0..page.count]) |entry| {
            const name = entry.name.slice();
            if (entry.directory or !std.ascii.endsWithIgnoreCase(name, ".iso")) continue;
            iso_count.* += 1;
            const setup = context.probeDonor(folder, name) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            // Enforce the gate here as well, so adapters cannot bypass it.
            if (!setup.isWindows10Donor()) continue;
            if (found) return error.Windows10PeDonorAmbiguous;
            found = true;
            result.donor_name = entry.name;
            result.donor_directory = folder;
            result.boot_setup = setup;
        }
        skip += page.count;
        if (!page.has_more) break;
    }
    return if (found) result else null;
}

/// Written by the installer (install/update/repair) next to the other ESP
/// state: the PE10 donor it placed in Programs\USOS\WinPE.
pub const donor_record_path = "\\EFI\\USOS\\winpe-donor.ini";
pub const DonorRecord = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    size: u64 = 0,
    sha256: [32]u8 = undefined,

    pub fn nameSlice(self: *const DonorRecord) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Parses winpe-donor.ini (`name=`, `size=`, `sha256=`); null if incomplete.
pub fn parseDonorRecord(text: []const u8) ?DonorRecord {
    var record = DonorRecord{};
    var have: u3 = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "name")) {
            if (value.len == 0 or value.len > record.name.len) return null;
            @memcpy(record.name[0..value.len], value);
            record.name_len = value.len;
            have |= 1;
        } else if (std.ascii.eqlIgnoreCase(key, "size")) {
            record.size = std.fmt.parseInt(u64, value, 10) catch return null;
            have |= 2;
        } else if (std.ascii.eqlIgnoreCase(key, "sha256")) {
            if (value.len != 64) return null;
            _ = std.fmt.hexToBytes(&record.sha256, value) catch return null;
            have |= 4;
        }
    }
    return if (have == 7) record else null;
}

/// Folder name of a catalog Windows system ("\Systems\Windows\<folder>\Images").
pub fn systemFolder(image_directory: []const u8) ![]const u8 {
    const prefix = "\\Systems\\Windows\\";
    const suffix = "\\Images";
    if (!std.mem.startsWith(u8, image_directory, prefix) or !std.mem.endsWith(u8, image_directory, suffix) or image_directory.len <= prefix.len + suffix.len)
        return error.UnsupportedWindowsFolder;
    return image_directory[prefix.len .. image_directory.len - suffix.len];
}

pub fn errorDetail(err: anyerror) []const u8 {
    return switch (err) {
        error.VistaRequiresSp2X64 => "Vista USB v1 requires only Vista SP2 build 6002 x64 editions in install.wim.",
        error.Windows10PeDonorMissing => "Add one Windows 10 x64 PE/Setup ISO to Programs/USOS/WinPE on DATA.",
        error.Windows10PeDonorInvalid, error.Windows10PeDonorWrongVersion => "No valid donor: need PE 10.0 x64 build 10240..21999, boot index, Setup, BCD and SDI.",
        error.Windows10PeDonorAmbiguous => "Multiple PE10 donors: leave exactly one valid ISO in Programs/USOS/WinPE.",
        error.Windows10PeDonorScanLimit => "Donor scan exceeds 256 directory entries; reduce the donor folder contents.",
        error.UnsupportedWindows7InstallTarget => "Every install image must be Windows 7 (6.1) x64; mixed targets are rejected.",
        error.Windows7OriginalRequiresInstallWim => "Native-PE7 media requires sources/install.wim for external PE10 Setup.",
        else => "ISO validation failed; no PE7 fallback and no installer was launched.",
    };
}

const Fake = struct {
    entries: []const TestDonor = &.{},
    probes: usize = 0,
    lists: usize = 0,
    missing: bool = false,
    endless: bool = false,
    /// Entries of the legacy Windows 10/Images folder (null: folder missing).
    legacy_entries: ?[]const TestDonor = null,
    probed_directory: []const u8 = "",
    const TestDonor = struct { name: []const u8, setup: ?wim.Setup };
    fn source(self: *Fake) directory.Source {
        return .{ .context = self, .list_fn = list, .page_fn = page };
    }
    fn list(ctx: *anyopaque, path: []const u8, out: []directory.Entry) !usize {
        return (try page(ctx, path, 0, out)).count;
    }
    fn page(ctx: *anyopaque, path: []const u8, skip: usize, out: []directory.Entry) !directory.Page {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.lists += 1;
        const managed = std.mem.eql(u8, path, donor_directory);
        if (!managed) try std.testing.expectEqualStrings(legacy_donor_directory, path);
        const list_entries = if (managed) self.entries else self.legacy_entries orelse return error.NotFound;
        if (managed and self.missing) return error.NotFound;
        if (self.endless) return .{ .count = 0, .has_more = true };
        const count = @min(out.len, list_entries.len - skip);
        for (list_entries[skip..][0..count], out[0..count]) |item, *entry| {
            entry.* = .{};
            @memcpy(entry.name.bytes[0..item.name.len], item.name);
            entry.name.len = item.name.len;
        }
        return .{ .count = count, .has_more = skip + count < list_entries.len };
    }
    pub fn probeDonor(self: *Fake, folder: []const u8, name: []const u8) anyerror!wim.Setup {
        self.probes += 1;
        self.probed_directory = folder;
        const list_entries = if (std.mem.eql(u8, folder, donor_directory)) self.entries else self.legacy_entries orelse &.{};
        for (list_entries) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.setup orelse error.InvalidWindowsBootFile;
        }
        return error.FileNotFound;
    }
};
const pe7 = wim.Setup{ .index = 2, .major = 6, .minor = 1, .build = 7601 };
const pe10 = wim.Setup{ .index = 1, .major = 10, .minor = 0, .build = 19041 };
const original = Inspection{ .mode = .original, .selected_setup = pe7, .boot_setup = pe7, .nvme_packages = true };

test "missing invalid ambiguous donors fail closed; arbitrary renamed ISO uses metadata" {
    var fake = Fake{ .missing = true };
    try std.testing.expectError(error.Windows10PeDonorMissing, resolveDonor(original, fake.source(), &fake));
    fake = .{};
    try std.testing.expectError(error.Windows10PeDonorMissing, resolveDonor(original, fake.source(), &fake));
    fake = .{ .entries = &.{ .{ .name = "Windows10.iso", .setup = pe7 }, .{ .name = "bad.iso", .setup = null } } };
    try std.testing.expectError(error.Windows10PeDonorInvalid, resolveDonor(original, fake.source(), &fake));
    fake = .{ .entries = &.{ .{ .name = "renamed.ISO", .setup = pe10 }, .{ .name = "ignore.txt", .setup = pe10 } } };
    var resolved = try resolveDonor(original, fake.source(), &fake);
    try std.testing.expectEqualStrings("renamed.ISO", resolved.bootName("stock.iso"));
    try std.testing.expectEqual(@as(u32, 1), resolved.boot_setup.index);
    try std.testing.expectEqual(pe7, resolved.selected_setup);
    try std.testing.expectEqual(@as(usize, 1), fake.probes);
    fake = .{ .entries = &.{ .{ .name = "a.iso", .setup = pe10 }, .{ .name = "b.iso", .setup = pe10 } } };
    try std.testing.expectError(error.Windows10PeDonorAmbiguous, resolveDonor(original, fake.source(), &fake));
}

test "donor is found in Programs/USOS/WinPE first, the legacy Windows 10/Images folder only as fallback" {
    // Managed folder missing, donor still in the old place: resolved there.
    var fake = Fake{ .missing = true, .legacy_entries = &.{ .{ .name = "x86-install.iso", .setup = null }, .{ .name = "PE10_x64_19041_USOS.iso", .setup = pe10 } } };
    var resolved = try resolveDonor(original, fake.source(), &fake);
    try std.testing.expectEqualStrings("PE10_x64_19041_USOS.iso", resolved.bootName("stock.iso"));
    try std.testing.expectEqualStrings(legacy_donor_directory, resolved.donor_directory);
    // Moved donor: the managed folder wins and the legacy folder is not read.
    fake = .{ .entries = &.{.{ .name = "PE10_x64_19041_USOS.iso", .setup = pe10 }}, .legacy_entries = &.{ .{ .name = "a.iso", .setup = pe10 }, .{ .name = "b.iso", .setup = pe10 } } };
    resolved = try resolveDonor(original, fake.source(), &fake);
    try std.testing.expectEqualStrings(donor_directory, resolved.donor_directory);
    try std.testing.expectEqualStrings(donor_directory, fake.probed_directory);
    try std.testing.expectEqual(@as(usize, 1), fake.lists);
    // An empty managed folder falls back; nothing valid anywhere is "invalid".
    fake = .{ .legacy_entries = &.{.{ .name = "pl-pl_windows_10_x86.iso", .setup = null }} };
    try std.testing.expectError(error.Windows10PeDonorInvalid, resolveDonor(original, fake.source(), &fake));
    // Two donors in the legacy folder stay ambiguous.
    fake = .{ .missing = true, .legacy_entries = &.{ .{ .name = "a.iso", .setup = pe10 }, .{ .name = "b.iso", .setup = pe10 } } };
    try std.testing.expectError(error.Windows10PeDonorAmbiguous, resolveDonor(original, fake.source(), &fake));
}

test "hybrid never enumerates or opens donors even if missing or ambiguous" {
    var hybrid = original;
    hybrid.mode = .hybrid;
    hybrid.selected_setup = pe10;
    hybrid.boot_setup = pe10;
    var fake = Fake{ .missing = true };
    var resolved = try resolveDonor(hybrid, fake.source(), &fake);
    try std.testing.expectEqualStrings("hybrid.iso", resolved.bootName("hybrid.iso"));
    try std.testing.expectEqual(@as(usize, 0), fake.lists);
    try std.testing.expectEqual(@as(usize, 0), fake.probes);
    fake = .{ .entries = &.{ .{ .name = "a.iso", .setup = pe10 }, .{ .name = "b.iso", .setup = pe10 } } };
    _ = try resolveDonor(hybrid, fake.source(), &fake);
    try std.testing.expectEqual(@as(usize, 0), fake.lists);
}

test "donor build gate rejects missing build Windows11 and PE8; scan is bounded" {
    for ([_]u32{ 0, 9600, 10239, 10240, 19045, 21999, 22000, 26100 }) |build| {
        var setup = pe10;
        setup.build = build;
        try std.testing.expectEqual(build >= 10240 and build < 22000, setup.isWindows10Donor());
    }
    var fake = Fake{ .endless = true };
    try std.testing.expectError(error.Windows10PeDonorScanLimit, resolveDonor(original, fake.source(), &fake));
    const items = [_]Fake.TestDonor{.{ .name = "ignored.txt", .setup = null }} ** (max_donor_entries + 1);
    fake = .{ .entries = &items };
    try std.testing.expectError(error.Windows10PeDonorScanLimit, resolveDonor(original, fake.source(), &fake));
    try std.testing.expectEqual(@as(usize, 32), fake.lists);
}

test "system folder comes from the catalog image directory" {
    try std.testing.expectEqualStrings("Windows 10", try systemFolder("\\Systems\\Windows\\Windows 10\\Images"));
    try std.testing.expectEqualStrings("Windows 11", try systemFolder("\\Systems\\Windows\\Windows 11\\Images"));
    try std.testing.expectError(error.UnsupportedWindowsFolder, systemFolder("\\Systems\\Linux\\Debian\\Images"));
}

test "donor record needs name, size and a 64-digit SHA-256" {
    const record = parseDonorRecord("name=PE10_x64_19041_USOS.iso\r\nsize=459735040\r\nsha256=" ++ "ab" ** 32 ++ "\r\n").?;
    try std.testing.expectEqualStrings("PE10_x64_19041_USOS.iso", record.nameSlice());
    try std.testing.expectEqual(@as(u64, 459735040), record.size);
    try std.testing.expectEqual(@as(u8, 0xab), record.sha256[31]);
    try std.testing.expect(parseDonorRecord("name=a.iso\nsize=1\n") == null);
    try std.testing.expect(parseDonorRecord("name=a.iso\nsize=x\nsha256=" ++ "00" ** 32) == null);
}
