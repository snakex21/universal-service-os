//! User INF driver packages from DATA\Drivers\<Windows version>\ for the
//! UEFI Windows 7 path (windows_driver_files.zig puts them into the same
//! RAM archive as the bundled library, after it, under user\<Class>\NN\).
//!
//! Layout on DATA (docs/drivers.md): Drivers\Windows 7\Storage\, USB\ and
//! Other\ (anything else, including files directly in Drivers\Windows 7,
//! counts as Other). Every folder that holds an .inf is one package; its
//! sub-folders without an .inf belong to it. Each INF is checked with
//! src/flow/inf_package.zig (architecture, catalog, [SourceDisksFiles],
//! form); a package is used when at least one of its INFs is. Duplicate
//! INFs (same bytes) are used once. Folder names become NN / dNN in the
//! archive, so long and non-ASCII names are fine; a file whose own name
//! the WinPE helper cannot write (non-ASCII, reserved) is left out. Nothing
//! here fails the Windows start: problems are logged (serial and
//! user\usos-user-drivers.log in the archive) and the package is skipped.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const ntfs = usos.storage.ntfs;
const inf = usos.flow.inf_package;
const Catalog = @import("data_volume.zig").Catalog;
const serial = @import("serial.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const max_dirs = 128;
pub const max_files = 512;
const max_path16 = 400;
const max_components = 24;
pub const max_archive_path = 180;
const max_inf_bytes = 1024 * 1024;

const Dir = struct {
    path16: [max_path16]u16 = undefined,
    path16_len: usize = 0,
    components: usize = 0,
    parent: ?u16 = null,
    class: inf.Class = .other,
    inf_count: usize = 0,
    accepted_infs: usize = 0,
    /// Package root (index into dirs) that owns this folder, if any.
    owner: ?u16 = null,
    package: u16 = 0,
    /// Archive path of this folder ("user\Storage\03\d1").
    archive: [max_archive_path]u8 = undefined,
    archive_len: usize = 0,
    sub_index: u16 = 0,
    /// Drivers\<OS> itself or one of its class folders (see inf.owner).
    boundary: bool = false,
};

const File = struct {
    dir: u16,
    name16: [128]u16 = undefined,
    name16_len: usize = 0,
    ascii: [128]u8 = undefined,
    ascii_len: usize = 0,
    ascii_ok: bool = false,
    size: u64 = 0,
    is_inf: bool = false,
    use: bool = false,
};

pub const Set = struct {
    dirs: [max_dirs]Dir = undefined,
    dir_count: usize = 0,
    files: [max_files]File = undefined,
    file_count: usize = 0,
    packages: usize = 0,
    infs_used: usize = 0,
    infs_skipped: usize = 0,
    files_skipped: usize = 0,
    bytes: usize = 0,
    over_limit: bool = false,
    log: [16 * 1024]u8 = undefined,
    log_len: usize = 0,
    hashes: [64][32]u8 = undefined,
    hash_count: usize = 0,

    pub fn logText(self: *const Set) []const u8 {
        return self.log[0..self.log_len];
    }

    fn note(self: *Set, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.log[self.log_len..], fmt ++ "\r\n", args) catch return;
        self.log_len += written.len;
        serial.writeAscii("[USER_DRIVERS_WIN] ");
        serial.writeAscii(written);
    }

    /// Files to put into the archive (archive path, source components).
    pub fn used(self: *const Set) UsedIterator {
        return .{ .set = self };
    }
};

pub const UsedIterator = struct {
    set: *const Set,
    index: usize = 0,

    pub fn next(self: *UsedIterator) ?*const File {
        while (self.index < self.set.file_count) {
            const file = &self.set.files[self.index];
            self.index += 1;
            if (file.use) return file;
        }
        return null;
    }
};

/// Archive path of a used file.
pub fn archivePath(set: *const Set, file: *const File, out: []u8) ?[]const u8 {
    const dir = &set.dirs[file.dir];
    return std.fmt.bufPrint(out, "{s}\\{s}", .{ dir.archive[0..dir.archive_len], file.ascii[0..file.ascii_len] }) catch null;
}

/// Opens a used file on DATA.
pub fn open(catalog: *Catalog, set: *const Set, root: []const []const u16, file: *const File, out: *ntfs.File) !void {
    var parts: [max_components + 4][]const u16 = undefined;
    const n = componentsOf(set, root, file.dir, &parts);
    if (n + 1 > parts.len) return error.DriverPathTooDeep;
    parts[n] = file.name16[0..file.name16_len];
    try ntfs.openFile(catalog.fs, catalog.reader(), parts[0 .. n + 1], out);
}

fn componentsOf(set: *const Set, root: []const []const u16, dir_index: u16, parts: [][]const u16) usize {
    @memcpy(parts[0..root.len], root);
    var n = root.len;
    const dir = &set.dirs[dir_index];
    var start: usize = 0;
    for (dir.path16[0..dir.path16_len], 0..) |unit, i| {
        if (unit == '\\') {
            parts[n] = dir.path16[start..i];
            n += 1;
            start = i + 1;
        }
    }
    if (dir.path16_len > start) {
        parts[n] = dir.path16[start..dir.path16_len];
        n += 1;
    }
    return n;
}

/// Scans Drivers\<os_folder> on DATA. `budget` is how many archive bytes
/// may still be used (the bundled library comes first). Returns null when
/// the folder is missing or empty.
pub fn scan(catalog: *Catalog, os_folder: []const u8, targets: []const inf.Arch, budget: usize) ?*Set {
    const bs = uefi.system_table.boot_services orelse return null;
    const memory = bs.allocatePool(.loader_data, @sizeOf(Set)) catch return null;
    const set: *Set = @ptrCast(@alignCast(memory.ptr));
    // Field by field: a whole-struct `.{}` could stage ~400 KiB on the stack.
    inline for (.{ "dir_count", "file_count", "packages", "infs_used", "infs_skipped", "files_skipped", "bytes", "log_len", "hash_count" }) |field| @field(set, field) = 0;
    set.over_limit = false;
    var folder16: [64]u16 = undefined;
    const folder_len = std.unicode.utf8ToUtf16Le(&folder16, os_folder) catch 0;
    const root = [_][]const u16{ wide("Drivers"), folder16[0..folder_len] };
    set.note("Drivers\\{s}: targets={s}{s}", .{ os_folder, targets[0].label(), if (targets.len > 1) "+more" else "" });
    walk(catalog, set, &root) catch |err| {
        if (err == error.NotFound or err == error.NotDirectory) {
            set.note("no Drivers\\{s} folder on DATA", .{os_folder});
        } else set.note("listing stopped: {s} (packages found so far are still checked)", .{@errorName(err)});
    };
    if (set.file_count == 0) {
        release(set);
        return null;
    }
    judgePackages(catalog, set, &root, targets);
    choose(set, budget);
    set.note("used packages={d} infs={d}, skipped infs={d} files={d}, bytes={d}", .{ set.packages, set.infs_used, set.infs_skipped, set.files_skipped, set.bytes });
    return set;
}

pub fn release(set: *Set) void {
    const bs = uefi.system_table.boot_services orelse return;
    bs.freePool(@ptrCast(@alignCast(set))) catch {};
}

fn walk(catalog: *Catalog, set: *Set, root: []const []const u16) !void {
    set.dirs[0] = .{ .boundary = true };
    set.dir_count = 1;
    var index: usize = 0;
    while (index < set.dir_count) : (index += 1) {
        var parts: [max_components + 4][]const u16 = undefined;
        const n = componentsOf(set, root, @intCast(index), &parts);
        var skip: usize = 0;
        while (true) {
            var items: [8]ntfs.DirectoryItem = undefined;
            const page = try ntfs.listDirectoryPage(catalog.fs, catalog.reader(), parts[0..n], skip, &items);
            for (items[0..page.count]) |item| {
                const name = item.name[0..item.name_len];
                if ((name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.')) continue;
                if (item.attributes & 0x400 != 0) {
                    set.note("skip reparse point (link) in folder #{d}", .{index});
                    continue;
                }
                if (item.isDirectory()) addDir(set, @intCast(index), name) else addFile(set, @intCast(index), name, item.size);
            }
            if (!page.has_more or page.count == 0) break;
            skip += page.count;
        }
    }
}

fn addDir(set: *Set, parent: u16, name: []const u16) void {
    const up = &set.dirs[parent];
    if (set.dir_count == max_dirs) {
        set.note("too many folders (limit {d}); the rest is skipped", .{max_dirs});
        return;
    }
    const sep: usize = if (up.path16_len == 0) 0 else 1;
    if (up.path16_len + sep + name.len > max_path16 or up.components + 1 > max_components) {
        set.note("folder path too long or deep; skipped", .{});
        return;
    }
    const dir = &set.dirs[set.dir_count];
    dir.* = .{ .parent = parent, .components = up.components + 1 };
    @memcpy(dir.path16[0..up.path16_len], up.path16[0..up.path16_len]);
    if (sep == 1) dir.path16[up.path16_len] = '\\';
    @memcpy(dir.path16[up.path16_len + sep ..][0..name.len], name);
    dir.path16_len = up.path16_len + sep + name.len;
    // Top-level folder decides the class; deeper folders inherit it.
    if (parent == 0) {
        var ascii: [16]u8 = undefined;
        const ascii_ok = name.len <= ascii.len and asciiName(name, &ascii);
        dir.class = if (ascii_ok) inf.Class.fromFolder(ascii[0..name.len]) else .other;
        dir.boundary = ascii_ok and inf.isClassFolder(ascii[0..name.len]);
    } else dir.class = up.class;
    set.dir_count += 1;
}

fn asciiName(name: []const u16, out: []u8) bool {
    if (name.len > out.len) return false;
    for (name, 0..) |unit, i| {
        if (unit < 0x20 or unit > 0x7e) return false;
        out[i] = @intCast(unit);
    }
    return true;
}

/// Names the WinPE helper (tools/windows_driver_archive.c valid_name)
/// accepts: printable ASCII without \/:"<>|*?%, no trailing dot or space,
/// no device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, with any extension).
pub fn archiveNameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 120) return false;
    for (name) |c| if (c < 32 or c > 126 or std.mem.indexOfScalar(u8, "\\/:\"<>|*?%", c) != null) return false;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    const stem_end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const stem = name[0..stem_end];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| if (std.ascii.eqlIgnoreCase(stem, device)) return false;
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9' and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) return false;
    return true;
}

fn addFile(set: *Set, dir: u16, name: []const u16, size: u64) void {
    if (set.file_count == max_files) {
        set.files_skipped += 1;
        return;
    }
    if (name.len > 128) {
        set.files_skipped += 1;
        set.note("file name longer than 128 characters skipped", .{});
        return;
    }
    const file = &set.files[set.file_count];
    file.* = .{ .dir = dir, .size = size };
    @memcpy(file.name16[0..name.len], name);
    file.name16_len = name.len;
    file.ascii_ok = asciiName(name, &file.ascii) and archiveNameOk(file.ascii[0..name.len]);
    file.ascii_len = if (file.ascii_ok) name.len else 0;
    file.is_inf = file.ascii_ok and std.ascii.endsWithIgnoreCase(file.ascii[0..file.ascii_len], ".inf");
    if (file.is_inf) set.dirs[dir].inf_count += 1;
    set.file_count += 1;
}

/// The package root that owns `dir`: the nearest folder (itself included)
/// that holds an .inf.
fn ownerOf(set: *const Set, dir: u16) ?u16 {
    return inf.owner(Dir, set.dirs[0..set.dir_count], dir);
}

const TreeContext = struct { set: *const Set, root: u16 };

fn hasFileInPackage(context: ?*anyopaque, name: []const u8) bool {
    const ctx: *const TreeContext = @ptrCast(@alignCast(context.?));
    // The file name may carry a relative path (rare); compare the last part.
    const base_start = if (std.mem.lastIndexOfAny(u8, name, "\\/")) |i| i + 1 else 0;
    const base = name[base_start..];
    for (ctx.set.files[0..ctx.set.file_count]) |*file| {
        if (!file.ascii_ok) continue;
        if (ownerOf(ctx.set, file.dir) != ctx.root) continue;
        if (std.ascii.eqlIgnoreCase(file.ascii[0..file.ascii_len], base)) return true;
    }
    return false;
}

fn judgePackages(catalog: *Catalog, set: *Set, root: []const []const u16, targets: []const inf.Arch) void {
    const bs = uefi.system_table.boot_services orelse return;
    const raw = bs.allocatePool(.loader_data, max_inf_bytes) catch return;
    defer bs.freePool(raw.ptr) catch {};
    const text = bs.allocatePool(.loader_data, max_inf_bytes) catch return;
    defer bs.freePool(text.ptr) catch {};
    const info = bs.allocatePool(.loader_data, @sizeOf(inf.Info)) catch return;
    defer bs.freePool(info.ptr) catch {};
    const parsed: *inf.Info = @ptrCast(@alignCast(info.ptr));
    var handle: ntfs.File = .{};
    for (set.files[0..set.file_count]) |*file| {
        if (!file.is_inf) continue;
        const name = file.ascii[0..file.ascii_len];
        if (file.size == 0 or file.size > max_inf_bytes) {
            set.infs_skipped += 1;
            set.note("{s}: skip: size {d} (1 byte to 1 MiB)", .{ name, file.size });
            continue;
        }
        open(catalog, set, root, file, &handle) catch |err| {
            set.infs_skipped += 1;
            set.note("{s}: skip: cannot read ({s})", .{ name, @errorName(err) });
            continue;
        };
        const n: usize = @intCast(file.size);
        handle.readAt(catalog.fs, catalog.reader(), 0, raw[0..n]) catch |err| {
            set.infs_skipped += 1;
            set.note("{s}: skip: read failed ({s})", .{ name, @errorName(err) });
            continue;
        };
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw[0..n], &hash, .{});
        var duplicate = false;
        for (set.hashes[0..set.hash_count]) |*seen| {
            if (std.mem.eql(u8, seen, &hash)) duplicate = true;
        }
        if (duplicate) {
            set.infs_skipped += 1;
            set.note("{s} ({s}): skip: duplicate of an INF already used", .{ name, set.dirs[file.dir].class.folder() });
            continue;
        }
        parsed.* = inf.parse(inf.decodeText(raw[0..n], text));
        var ctx = TreeContext{ .set = set, .root = file.dir };
        const result = inf.judge(parsed, targets, &ctx, hasFileInPackage);
        const catalog_name = parsed.catalogFor(result.arch) orelse "-";
        set.note("{s} ({s}, class={s}, provider={s}, ver={s}, arch={s}, catalog={s}): {s}{s}{s}", .{
            name,                set.dirs[file.dir].class.folder(), parsed.class,          parsed.provider,                             parsed.driver_ver,
            result.arch.label(), catalog_name,                      result.verdict.text(), if (result.missing.len != 0) " -> " else "", result.missing,
        });
        if (!result.verdict.accepted()) {
            set.infs_skipped += 1;
            continue;
        }
        set.infs_used += 1;
        set.dirs[file.dir].accepted_infs += 1;
        if (set.hash_count < set.hashes.len) {
            set.hashes[set.hash_count] = hash;
            set.hash_count += 1;
        }
    }
}

/// Marks the files of accepted packages as used, in class order (Storage,
/// USB, Other) while the archive budget lasts, and names their folders.
fn choose(set: *Set, budget: usize) void {
    var used_bytes: usize = 0;
    for ([_]inf.Class{ .storage, .usb, .other }) |class| {
        for (set.dirs[0..set.dir_count], 0..) |*dir, index| {
            if (dir.class != class or dir.accepted_infs == 0) continue;
            // Package size (its files and INF-less sub-folders).
            var size: usize = 0;
            var entries: usize = 0;
            for (set.files[0..set.file_count]) |*file| {
                if (!file.ascii_ok or ownerOf(set, file.dir) != @as(u16, @intCast(index))) continue;
                size += @intCast(@min(file.size, std.math.maxInt(u32)));
                entries += 6 + max_archive_path;
            }
            if (used_bytes + size + entries > budget) {
                set.over_limit = true;
                set.note("package #{d} ({s}, {d} bytes): skip: the WinPE RAM archive is full (64 MiB with the bundled drivers)", .{ set.packages + 1, class.folder(), size });
                continue;
            }
            set.packages += 1;
            dir.package = @intCast(set.packages);
            dir.archive_len = (std.fmt.bufPrint(&dir.archive, "user\\{s}\\{d:0>2}", .{ class.folder(), set.packages }) catch continue).len;
            used_bytes += size + entries;
            dir.owner = @intCast(index);
        }
    }
    // Sub-folders of used packages: user\<Class>\NN\d<k>\...
    for (set.dirs[0..set.dir_count], 0..) |*dir, index| {
        if (dir.inf_count != 0) continue;
        const owner = ownerOf(set, @intCast(index)) orelse continue;
        if (set.dirs[owner].archive_len == 0) continue;
        const parent = &set.dirs[dir.parent.?];
        if (parent.archive_len == 0) continue;
        parent.sub_index += 1;
        const written = std.fmt.bufPrint(&dir.archive, "{s}\\d{d}", .{ parent.archive[0..parent.archive_len], parent.sub_index }) catch continue;
        dir.archive_len = written.len;
    }
    for (set.files[0..set.file_count]) |*file| {
        const owner = ownerOf(set, file.dir) orelse {
            set.files_skipped += 1;
            continue;
        };
        if (set.dirs[owner].archive_len == 0 or set.dirs[file.dir].archive_len == 0) {
            if (set.dirs[owner].accepted_infs == 0) set.files_skipped += 1;
            continue;
        }
        if (!file.ascii_ok) {
            set.files_skipped += 1;
            set.note("a file with a non-ASCII or reserved name in package {s} is left out", .{set.dirs[owner].archive[0..set.dirs[owner].archive_len]});
            continue;
        }
        if (set.dirs[file.dir].archive_len + 1 + file.ascii_len > max_archive_path) {
            set.files_skipped += 1;
            set.note("{s}: path too long for the archive; left out", .{file.ascii[0..file.ascii_len]});
            continue;
        }
        file.use = true;
        set.bytes += @intCast(@min(file.size, std.math.maxInt(u32)));
    }
}

test "archive names the WinPE helper accepts" {
    try std.testing.expect(archiveNameOk("iaStorAC.inf"));
    try std.testing.expect(archiveNameOk("d1"));
    try std.testing.expect(!archiveNameOk("CON.inf"));
    try std.testing.expect(!archiveNameOk("lpt1"));
    try std.testing.expect(archiveNameOk("LPT0.sys"));
    try std.testing.expect(!archiveNameOk("bad."));
    try std.testing.expect(!archiveNameOk("a%b"));
    try std.testing.expect(!archiveNameOk(""));
}
