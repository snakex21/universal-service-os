// Shared by the native UEFI menu/start and read-only host tests.
const std = @import("std");
const udf = @import("image_probe/udf.zig");
const wim = @import("image_probe/wim_setup.zig");
const directory = @import("catalog/directory_source.zig");
const FixedText = @import("core/fixed_text.zig").FixedText;

pub const donor_directory = "Systems/Windows/Windows 10/Images";
pub const max_donor_entries = 256;
pub const boot_paths = [_][]const u8{ "boot/bcd", "boot/boot.sdi", "sources/boot.wim" };
pub const max_boot_file_size = 1024 * 1024 * 1024;

pub const Inspection = struct {
    mode: wim.Win7Mode,
    selected_setup: wim.Setup,
    boot_setup: wim.Setup,
    donor_name: FixedText = .{},
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

// context.probeDonor(name) performs bounded optical metadata reads. Directory
// names only filter the extension, never establish Windows identity. No fallback
// to PE7, no arbitrary first-match selection, and no donor access for hybrids.
pub fn resolveDonor(selected: Inspection, source: directory.Source, context: anytype) !Inspection {
    if (selected.mode == .hybrid) return selected;
    if (selected.mode != .original) return error.UnsupportedWindows7InstallTarget;
    var result = selected;
    var entries: [8]directory.Entry = undefined;
    var skip: usize = 0;
    var iso_count: usize = 0;
    var found = false;
    while (true) {
        const page = source.listPage(donor_directory, skip, &entries) catch |err| switch (err) {
            error.NotFound, error.FileNotFound, error.PathNotFound => return error.Windows10PeDonorMissing,
            else => return err,
        };
        if (page.count > entries.len or page.count > max_donor_entries - skip or
            (page.has_more and (page.count == 0 or skip + page.count == max_donor_entries))) return error.Windows10PeDonorScanLimit;
        for (entries[0..page.count]) |entry| {
            const name = entry.name.slice();
            if (entry.directory or !std.ascii.endsWithIgnoreCase(name, ".iso")) continue;
            iso_count += 1;
            const setup = context.probeDonor(name) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            // Enforce the gate here as well, so adapters cannot bypass it.
            if (!setup.isWindows10Donor()) continue;
            if (found) return error.Windows10PeDonorAmbiguous;
            found = true;
            result.donor_name = entry.name;
            result.boot_setup = setup;
        }
        skip += page.count;
        if (!page.has_more) break;
    }
    if (!found) return if (iso_count == 0) error.Windows10PeDonorMissing else error.Windows10PeDonorInvalid;
    return result;
}

pub fn errorDetail(err: anyerror) []const u8 {
    return switch (err) {
        error.VistaRequiresSp2X64 => "Vista USB v1 requires only Vista SP2 build 6002 x64 editions in install.wim.",
        error.Windows10PeDonorMissing => "Add one Windows 10 x64 Setup ISO to Systems/Windows/Windows 10/Images.",
        error.Windows10PeDonorInvalid, error.Windows10PeDonorWrongVersion => "No valid donor: need PE 10.0 x64 build 10240..21999, boot index, Setup, BCD and SDI.",
        error.Windows10PeDonorAmbiguous => "Multiple PE10 donors: leave exactly one valid ISO in Windows 10/Images.",
        error.Windows10PeDonorScanLimit => "Donor scan exceeds 256 directory entries; reduce Windows 10/Images contents.",
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
        try std.testing.expectEqualStrings(donor_directory, path);
        if (self.missing) return error.NotFound;
        if (self.endless) return .{ .count = 0, .has_more = true };
        const count = @min(out.len, self.entries.len - skip);
        for (self.entries[skip..][0..count], out[0..count]) |item, *entry| {
            entry.* = .{};
            @memcpy(entry.name.bytes[0..item.name.len], item.name);
            entry.name.len = item.name.len;
        }
        return .{ .count = count, .has_more = skip + count < self.entries.len };
    }
    pub fn probeDonor(self: *Fake, name: []const u8) anyerror!wim.Setup {
        self.probes += 1;
        for (self.entries) |item| {
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
