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

/// The same for 32-bit Setup media (win-x86-uefi-csmwrap).
pub fn setupInfoX86(allocator: std.mem.Allocator, iso: anytype) !wim.Setup {
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, "sources/boot.wim", &node) or node.is_directory or node.size > max_boot_file_size) return error.InvalidWindowsBootFile;
    var header: [124]u8 = undefined;
    const bytes = try metadata(allocator, iso, &node, &header);
    defer allocator.free(bytes);
    return wim.detectX86Setup(bytes, try wim.bootIndex(&header));
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

// ------------------------------------- 32-bit Windows 7 / Vista / 2008
// Without firmware CSM (win-nt6-x86-uefi-csmwrap, design doc
// csmwrap-integration.md section 12): the selected 32-bit NT 6.0 / 6.1 ISO
// keeps Setup and install.wim; an x86 PE10 donor (a Windows 10 x86 Setup
// ISO: it has xHCI, AHCI and NVMe) is staged on the target and started in
// BIOS mode through CSMWrap.

/// The selected 32-bit media: sources/setup.exe and an all-x86 install.wim
/// of NT 6.`minor` (1: Windows 7, 0: Vista / Server 2008). Returns the
/// install version (index 0) for the summary.
pub fn inspectNt6X86(allocator: std.mem.Allocator, iso: anytype, minor: u32) !wim.Setup {
    try validateSetup(iso);
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, "sources/install.wim", &node) or node.is_directory or node.size == 0)
        return error.WindowsInstallImageMissing;
    var header: [124]u8 = undefined;
    const bytes = try metadata(allocator, iso, &node, &header);
    defer allocator.free(bytes);
    const target = try wim.inspectNt6X86Install(bytes, minor);
    if (target.count != std.mem.readInt(u32, header[44..48], .little)) return error.InvalidWimXml;
    return .{ .index = 0, .major = 6, .minor = minor, .build = if (minor == 1) 7601 else 6002 };
}

/// An x86 PE10 donor: x86 Setup PE 10.0 (build 10240..21999), BCD, SDI,
/// boot.wim, sources/setup.exe and the BIOS bootmgr in the root.
pub fn inspectX86Donor(allocator: std.mem.Allocator, iso: anytype) !wim.Setup {
    const setup = try setupInfoX86(allocator, iso);
    if (!setup.isWindows10Donor()) return error.Windows10PeDonorWrongVersion;
    try validateBootFiles(iso);
    try validateSetup(iso);
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, "bootmgr", &node) or node.is_directory or node.size == 0) return error.InvalidWindowsBootFile;
    return setup;
}

/// The x86 PE10 donor. In Programs/USOS/WinPE the donor the installer
/// recorded (`preferred`: the x86_name of winpe-donor.ini, the shipped
/// PE10_x86_19041_USOS.iso) wins, else the first valid one by name; only when
/// that folder has no valid x86 donor, the first valid one in
/// Systems/Windows/Windows 10/Images (the user's own Windows 10 x86 ISO, the
/// fallback from before the donor was shipped). x64 donors and other ISOs
/// are skipped, so the x64 and the x86 donor share the managed folder.
/// `context.probeX86Donor(directory, name)` reads the ISO's metadata.
pub fn resolveX86Donor(selected: Inspection, source: directory.Source, context: anytype, preferred: ?[]const u8) !Inspection {
    for (donor_directories) |folder| {
        var first: ?Inspection = null;
        var entries: [8]directory.Entry = undefined;
        var skip: usize = 0;
        while (true) {
            const page = source.listPage(folder, skip, &entries) catch |err| switch (err) {
                error.NotFound, error.FileNotFound, error.PathNotFound => break,
                else => return err,
            };
            if (page.count > entries.len or page.count > max_donor_entries - skip or
                (page.has_more and (page.count == 0 or skip + page.count == max_donor_entries))) return error.Windows10PeDonorScanLimit;
            for (entries[0..page.count]) |entry| {
                const name = entry.name.slice();
                if (entry.directory or !std.ascii.endsWithIgnoreCase(name, ".iso")) continue;
                const is_preferred = if (preferred) |want| std.mem.eql(u8, folder, donor_directory) and std.ascii.eqlIgnoreCase(want, name) else false;
                // Once a candidate is known, only the recorded donor can still change it.
                if (first != null and !is_preferred) continue;
                const setup = context.probeX86Donor(folder, name) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                if (!setup.isWindows10Donor()) continue;
                var result = selected;
                result.mode = .original;
                result.donor_name = entry.name;
                result.donor_directory = folder;
                result.boot_setup = setup;
                if (is_preferred) return result;
                first = result;
                // Without a recorded name the first valid donor is final.
                if (preferred == null or !std.mem.eql(u8, folder, donor_directory)) return result;
            }
            skip += page.count;
            if (!page.has_more) break;
        }
        if (first) |result| return result;
    }
    return error.X86PeDonorMissing;
}

/// Written by the installer (install/update/repair) next to the other ESP
/// state: the PE10 donors it placed in Programs\USOS\WinPE. The x64 donor
/// uses `name=`, `size=`, `sha256=` (as before the x86 donor); the x86 donor
/// `x86_name=`, `x86_size=`, `x86_sha256=`, which older readers ignore.
pub const donor_record_path = "\\EFI\\USOS\\winpe-donor.ini";
pub const DonorArch = enum { x64, x86 };
pub const DonorRecord = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    size: u64 = 0,
    sha256: [32]u8 = undefined,

    pub fn nameSlice(self: *const DonorRecord) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Parses the x64 entry of winpe-donor.ini (`name=`, `size=`, `sha256=`);
/// null if incomplete.
pub fn parseDonorRecord(text: []const u8) ?DonorRecord {
    return parseDonorRecordFor(text, .x64);
}

/// The entry of one donor (x86: the `x86_` keys); null if incomplete.
pub fn parseDonorRecordFor(text: []const u8, arch: DonorArch) ?DonorRecord {
    const prefix: []const u8 = if (arch == .x86) "x86_" else "";
    var record = DonorRecord{};
    var have: u3 = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const full_key = std.mem.trim(u8, line[0..eq], " \t");
        if (full_key.len < prefix.len or !std.ascii.eqlIgnoreCase(full_key[0..prefix.len], prefix)) continue;
        const key = full_key[prefix.len..];
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

/// Whether the resolved x86 donor is the one the installer recorded (then it
/// is checked against the record: size, and SHA-256 right before use). A
/// donor from the Windows 10/Images fallback or an unrecorded one in the
/// managed folder gets the structural checks only; a damaged recorded donor
/// fails closed (Repair), it does not silently fall back to another ISO.
pub fn x86DonorRecorded(record: ?DonorRecord, inspection: *const Inspection) bool {
    const r = record orelse return false;
    return std.mem.eql(u8, inspection.donor_directory, donor_directory) and std.ascii.eqlIgnoreCase(r.nameSlice(), inspection.donor_name.slice());
}

/// A recorded donor's size and SHA-256 against what was read.
pub fn checkDonorDigest(record: *const DonorRecord, size: u64, digest: ?*const [32]u8) !void {
    if (size != record.size) return error.Windows10PeDonorCorrupt;
    if (digest) |d| if (!std.mem.eql(u8, d, &record.sha256)) return error.Windows10PeDonorCorrupt;
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
        error.X86PeDonorMissing => "Add the WinPE x86 helper (USOS installer, Components) or a Windows 10 x86 Setup ISO to Systems/Windows/Windows 10/Images on DATA.",
        error.UnsupportedNt6X86InstallTarget => "Every install image must be 32-bit Windows 7 (6.1) or Vista / Server 2008 (6.0).",
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
    const TestDonor = struct { name: []const u8, setup: ?wim.Setup, x86: bool = false };
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
    // Like inspectDonor / inspectX86Donor: an ISO of the other architecture
    // fails the probe (detectX64Setup / detectX86Setup).
    fn probe(self: *Fake, folder: []const u8, name: []const u8, x86: bool) anyerror!wim.Setup {
        self.probes += 1;
        self.probed_directory = folder;
        const list_entries = if (std.mem.eql(u8, folder, donor_directory)) self.entries else self.legacy_entries orelse &.{};
        for (list_entries) |item| {
            if (std.mem.eql(u8, item.name, name)) return if (item.x86 != x86) error.InvalidWimXml else item.setup orelse error.InvalidWindowsBootFile;
        }
        return error.FileNotFound;
    }
    pub fn probeDonor(self: *Fake, folder: []const u8, name: []const u8) anyerror!wim.Setup {
        return self.probe(folder, name, false);
    }
    pub fn probeX86Donor(self: *Fake, folder: []const u8, name: []const u8) anyerror!wim.Setup {
        return self.probe(folder, name, true);
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

test "x86 PE10 donor: first valid by name, managed folder first, then Windows 10/Images" {
    const pe10_x86 = wim.Setup{ .index = 1, .major = 10, .minor = 0, .build = 19041 };
    var fake = Fake{ .missing = true, .legacy_entries = &.{ .{ .name = "a-bad.iso", .setup = null, .x86 = true }, .{ .name = "w10x86.iso", .setup = pe10_x86, .x86 = true }, .{ .name = "z.iso", .setup = pe10_x86, .x86 = true } } };
    const resolved = try resolveX86Donor(original, fake.source(), &fake, null);
    try std.testing.expectEqualStrings("w10x86.iso", resolved.donor_name.slice());
    try std.testing.expectEqualStrings(legacy_donor_directory, resolved.donor_directory);
    fake = .{ .entries = &.{.{ .name = "pe.iso", .setup = pe10_x86, .x86 = true }}, .legacy_entries = &.{.{ .name = "w10x86.iso", .setup = pe10_x86, .x86 = true }} };
    try std.testing.expectEqualStrings(donor_directory, (try resolveX86Donor(original, fake.source(), &fake, null)).donor_directory);
    fake = .{ .missing = true, .legacy_entries = &.{.{ .name = "pe7.iso", .setup = pe7, .x86 = true }} };
    try std.testing.expectError(error.X86PeDonorMissing, resolveX86Donor(original, fake.source(), &fake, null));
}

const x64_donor = "PE10_x64_19041_USOS.iso";
const x86_donor = "PE10_x86_19041_USOS.iso";

test "both donors in Programs/USOS/WinPE: each resolver takes its own architecture" {
    var fake = Fake{ .entries = &.{ .{ .name = x64_donor, .setup = pe10 }, .{ .name = x86_donor, .setup = pe10, .x86 = true } }, .legacy_entries = &.{.{ .name = "Win10_x86.iso", .setup = pe10, .x86 = true }} };
    // x64 (Vista / Windows 7): the x86 donor is no second x64 donor.
    const x64 = try resolveDonor(original, fake.source(), &fake);
    try std.testing.expectEqualStrings(x64_donor, x64.donor_name.slice());
    // x86: the shipped donor, not the user's ISO in the legacy folder.
    const x86 = try resolveX86Donor(original, fake.source(), &fake, x86_donor);
    try std.testing.expectEqualStrings(x86_donor, x86.donor_name.slice());
    try std.testing.expectEqualStrings(donor_directory, x86.donor_directory);
    try std.testing.expectEqualStrings(x86_donor, (try resolveX86Donor(original, fake.source(), &fake, null)).donor_name.slice());
}

test "only one donor present: the other architecture is missing or falls back" {
    // Only the x64 donor: the x86 path uses the user's Windows 10 x86 ISO...
    var fake = Fake{ .entries = &.{.{ .name = x64_donor, .setup = pe10 }}, .legacy_entries = &.{.{ .name = "pl-pl_windows_10_x86.iso", .setup = pe10, .x86 = true }} };
    const fallback = try resolveX86Donor(original, fake.source(), &fake, null);
    try std.testing.expectEqualStrings("pl-pl_windows_10_x86.iso", fallback.donor_name.slice());
    try std.testing.expectEqualStrings(legacy_donor_directory, fallback.donor_directory);
    // ...and without one it is missing.
    fake = .{ .entries = &.{.{ .name = x64_donor, .setup = pe10 }} };
    try std.testing.expectError(error.X86PeDonorMissing, resolveX86Donor(original, fake.source(), &fake, null));
    // Only the x86 donor: Vista / Windows 7 x64 have no donor (an ISO was seen, none valid).
    fake = .{ .entries = &.{.{ .name = x86_donor, .setup = pe10, .x86 = true }} };
    try std.testing.expectError(error.Windows10PeDonorInvalid, resolveDonor(original, fake.source(), &fake));
    try std.testing.expectEqualStrings(x86_donor, (try resolveX86Donor(original, fake.source(), &fake, x86_donor)).donor_name.slice());
}

test "the recorded x86 donor wins over other x86 ISOs in the managed folder" {
    const entries = [_]Fake.TestDonor{ .{ .name = "A_my_x86.iso", .setup = pe10, .x86 = true }, .{ .name = x86_donor, .setup = pe10, .x86 = true }, .{ .name = "Z_x86.iso", .setup = pe10, .x86 = true } };
    var fake = Fake{ .entries = &entries };
    try std.testing.expectEqualStrings(x86_donor, (try resolveX86Donor(original, fake.source(), &fake, x86_donor)).donor_name.slice());
    // Without a record: the first valid one by name.
    try std.testing.expectEqualStrings("A_my_x86.iso", (try resolveX86Donor(original, fake.source(), &fake, null)).donor_name.slice());
    // A recorded donor that no longer probes valid: the next valid one in the folder.
    const broken = [_]Fake.TestDonor{ .{ .name = "A_my_x86.iso", .setup = pe10, .x86 = true }, .{ .name = x86_donor, .setup = null, .x86 = true } };
    fake = .{ .entries = &broken };
    try std.testing.expectEqualStrings("A_my_x86.iso", (try resolveX86Donor(original, fake.source(), &fake, x86_donor)).donor_name.slice());
}

test "x86 donor record: own keys, applies only to the recorded managed donor, damaged hash fails closed" {
    const text = "; USOS\r\nname=" ++ x64_donor ++ "\r\nsize=459735040\r\nsha256=" ++ "ab" ** 32 ++ "\r\nx86_name=" ++ x86_donor ++ "\r\nx86_size=475332608\r\nx86_sha256=" ++ "cd" ** 32 ++ "\r\n";
    const x64 = parseDonorRecord(text).?;
    try std.testing.expectEqualStrings(x64_donor, x64.nameSlice());
    try std.testing.expectEqual(@as(u64, 459735040), x64.size);
    const x86 = parseDonorRecordFor(text, .x86).?;
    try std.testing.expectEqualStrings(x86_donor, x86.nameSlice());
    try std.testing.expectEqual(@as(u64, 475332608), x86.size);
    try std.testing.expectEqual(@as(u8, 0xcd), x86.sha256[0]);
    // An x64-only record (older install) has no x86 entry, and the other way round.
    try std.testing.expect(parseDonorRecordFor("name=a.iso\nsize=1\nsha256=" ++ "00" ** 32, .x86) == null);
    try std.testing.expect(parseDonorRecord("x86_name=a.iso\nx86_size=1\nx86_sha256=" ++ "00" ** 32) == null);

    var fake = Fake{ .entries = &.{.{ .name = x86_donor, .setup = pe10, .x86 = true }}, .legacy_entries = &.{.{ .name = "Win10_x86.iso", .setup = pe10, .x86 = true }} };
    const shipped = try resolveX86Donor(original, fake.source(), &fake, x86.nameSlice());
    try std.testing.expect(x86DonorRecorded(x86, &shipped));
    try std.testing.expect(!x86DonorRecorded(null, &shipped));
    fake = .{ .missing = true, .legacy_entries = &.{.{ .name = "Win10_x86.iso", .setup = pe10, .x86 = true }} };
    const user = try resolveX86Donor(original, fake.source(), &fake, x86.nameSlice());
    try std.testing.expect(!x86DonorRecorded(x86, &user));

    var digest = x86.sha256;
    try checkDonorDigest(&x86, 475332608, &digest);
    try checkDonorDigest(&x86, 475332608, null);
    try std.testing.expectError(error.Windows10PeDonorCorrupt, checkDonorDigest(&x86, 475332607, null));
    digest[31] ^= 1;
    try std.testing.expectError(error.Windows10PeDonorCorrupt, checkDonorDigest(&x86, 475332608, &digest));
}
