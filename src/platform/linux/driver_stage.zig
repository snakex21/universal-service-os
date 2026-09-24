//! `usos-fb-ui --stage-drivers <source> <destination> <install image|-> <log>`
//! (tools/extract.sh, micro-Linux): copies the user's INF driver packages
//! from DATA\Drivers\<Windows version> (source) into the prepared WORK
//! drive's $WinPEDriver$ folder (destination). Windows Setup (7 and later)
//! loads every driver in $WinPEDriver$ during the windowsPE pass and adds
//! it to the installed system, so boot-critical storage and USB drivers
//! work in Setup and at the first start. Rules (docs/drivers.md):
//!   - the target architecture comes from the install image's XML
//!     (<ARCH>0</ARCH> = x86, 9 = amd64; unreadable = both);
//!   - each folder with an .inf is one package (INF-less sub-folders belong
//!     to it); src/flow/inf_package.zig checks architecture, catalog (x64
//!     needs a signed package), [SourceDisksFiles] and form; a package is
//!     copied when one of its INFs passes; identical INFs are copied once;
//!   - order Storage, USB, Other; a package that does not fit into the free
//!     space of the destination (keeping a 64 MiB reserve) is skipped;
//!   - destination layout <Class>-NN\<the package's own tree>; paths longer
//!     than Windows' limit are skipped.
//! Nothing here fails the preparation: every decision goes to the log and
//! the exit code is 0 (2 only for bad arguments).
const std = @import("std");
const usos = @import("usos");
const linux = std.os.linux;
const inf = usos.flow.inf_package;
const wim_setup = usos.wim_setup;

const max_dirs = 256;
const max_files = 2048;
const max_path = 1024;
const max_inf_bytes = 1024 * 1024;
const reserve_bytes: u64 = 64 * 1024 * 1024;
/// "X:\$WinPEDriver$\Storage-01\" + relative path must stay below MAX_PATH.
const max_windows_relative = 200;

const Dir = struct {
    rel: [max_path]u8 = undefined,
    rel_len: usize = 0,
    parent: ?u16 = null,
    class: inf.Class = .other,
    inf_count: usize = 0,
    accepted: usize = 0,
    package: usize = 0,
    root_rel_len: usize = 0,
    /// Drivers\<OS> itself or one of its class folders (see inf.owner).
    boundary: bool = false,
};

const File = struct {
    dir: u16,
    name: [256]u8 = undefined,
    name_len: usize = 0,
    size: u64 = 0,
    is_inf: bool = false,
};

const State = struct {
    dirs: [max_dirs]Dir = undefined,
    dir_count: usize = 0,
    files: [max_files]File = undefined,
    file_count: usize = 0,
    log_fd: i32 = -1,
    hashes: [128][32]u8 = undefined,
    hash_count: usize = 0,
    used_infs: usize = 0,
    skipped_infs: usize = 0,
    packages: usize = 0,
    copied_files: usize = 0,
    copied_bytes: u64 = 0,
    skipped_files: usize = 0,
};

var state: State = .{};
var inf_raw: [max_inf_bytes]u8 = undefined;
var inf_text: [max_inf_bytes]u8 = undefined;
var parsed: inf.Info = .{};
var copy_buffer: [256 * 1024]u8 = undefined;

fn log(comptime fmt: []const u8, args: anytype) void {
    var line: [1200]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "[DRIVERS] " ++ fmt ++ "\n", args) catch return;
    _ = linux.write(1, text.ptr, text.len);
    if (state.log_fd >= 0) _ = linux.write(state.log_fd, text.ptr, text.len);
}

fn ok(result: usize) bool {
    return linux.errno(result) == .SUCCESS;
}

fn z(buffer: []u8, parts: []const []const u8) ?[:0]const u8 {
    var used: usize = 0;
    for (parts) |part| {
        if (used + part.len + 1 > buffer.len) return null;
        @memcpy(buffer[used .. used + part.len], part);
        used += part.len;
    }
    buffer[used] = 0;
    return buffer[0..used :0];
}

pub fn run(source: []const u8, destination: []const u8, image: []const u8, log_path: []const u8) u8 {
    state = .{};
    var path_buffer: [max_path]u8 = undefined;
    if (z(&path_buffer, &.{log_path})) |path| {
        const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        if (ok(opened)) state.log_fd = @intCast(opened);
    }
    defer if (state.log_fd >= 0) {
        _ = linux.fsync(state.log_fd);
        _ = linux.close(state.log_fd);
    };
    var arch_buffer: [2]inf.Arch = undefined;
    const targets = imageArches(image, &arch_buffer);
    log("source={s} destination={s} image={s} targets={s}{s}", .{ source, destination, image, targets[0].label(), if (targets.len > 1) "+x86" else "" });
    walk(source) catch |err| {
        if (err == error.NoSource) {
            log("no user drivers: {s} does not exist", .{source});
            return 0;
        }
        log("listing stopped: {s}; the packages found so far are checked", .{@errorName(err)});
    };
    judge(source, targets);
    stage(source, destination);
    log("done: packages={d} infs used={d} skipped={d}; files copied={d} ({d} bytes) skipped={d}", .{ state.packages, state.used_infs, state.skipped_infs, state.copied_files, state.copied_bytes, state.skipped_files });
    return 0;
}

// ------------------------------------------------------------ image arch

fn imageArches(image: []const u8, out: *[2]inf.Arch) []const inf.Arch {
    out.* = .{ .amd64, .x86 };
    if (std.mem.eql(u8, image, "-")) return out[0..2];
    var path_buffer: [max_path]u8 = undefined;
    const path = z(&path_buffer, &.{image}) orelse return out[0..2];
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (!ok(opened)) {
        log("install image not readable; both architectures allowed", .{});
        return out[0..2];
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var header: [208]u8 = undefined;
    if (!readAt(fd, 0, &header)) return out[0..2];
    const size_result = linux.lseek(fd, 0, 2);
    if (!ok(size_result)) return out[0..2];
    const xml = wim_setup.xmlResource(&header, size_result) catch {
        log("install image XML not found; both architectures allowed", .{});
        return out[0..2];
    };
    if (xml.size > inf_raw.len) return out[0..2];
    if (!readAt(fd, xml.offset, inf_raw[0..xml.size])) return out[0..2];
    const text = inf.decodeText(inf_raw[0..xml.size], &inf_text);
    var x86 = false;
    var amd64 = false;
    var rest = text;
    while (std.mem.indexOf(u8, rest, "<ARCH>")) |at| {
        rest = rest[at + 6 ..];
        if (std.mem.startsWith(u8, rest, "0<")) x86 = true;
        if (std.mem.startsWith(u8, rest, "9<")) amd64 = true;
    }
    if (amd64 and x86) return out[0..2];
    if (x86) {
        out[0] = .x86;
        return out[0..1];
    }
    if (amd64) return out[0..1];
    return out[0..2];
}

fn readAt(fd: i32, offset: u64, buffer: []u8) bool {
    if (!ok(linux.lseek(fd, @intCast(offset), 0))) return false;
    var used: usize = 0;
    while (used < buffer.len) {
        const n = linux.read(fd, buffer[used..].ptr, buffer.len - used);
        if (!ok(n) or n == 0) return false;
        used += n;
    }
    return true;
}

// ------------------------------------------------------------ walking

fn walk(source: []const u8) !void {
    state.dirs[0] = .{ .boundary = true };
    state.dir_count = 1;
    var index: usize = 0;
    var first = true;
    while (index < state.dir_count) : (index += 1) {
        const dir = &state.dirs[index];
        var path_buffer: [max_path * 2]u8 = undefined;
        const path = z(&path_buffer, &.{ source, if (dir.rel_len == 0) "" else "/", dir.rel[0..dir.rel_len] }) orelse continue;
        const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (!ok(opened)) {
            if (first) return error.NoSource;
            log("cannot open folder {s}", .{path});
            continue;
        }
        first = false;
        const fd: i32 = @intCast(opened);
        defer _ = linux.close(fd);
        var buffer: [8192]u8 align(8) = undefined;
        while (true) {
            const n = linux.getdents64(fd, &buffer, buffer.len);
            if (!ok(n) or n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[at]);
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buffer[at + @offsetOf(linux.dirent64, "name")])), 0);
                at += entry.reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                var kind = entry.type;
                if (kind == linux.DT.UNKNOWN) kind = probeType(path, name);
                if (kind == linux.DT.DIR) addDir(@intCast(index), name) else if (kind == linux.DT.REG) addFile(@intCast(index), path, name) else log("skip {s}/{s}: not a regular file or folder (links are not followed)", .{ path, name });
            }
        }
    }
}

fn probeType(dir: []const u8, name: []const u8) u8 {
    var buffer: [max_path * 2]u8 = undefined;
    const path = z(&buffer, &.{ dir, "/", name }) orelse return linux.DT.UNKNOWN;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (ok(opened)) {
        _ = linux.close(@intCast(opened));
        return linux.DT.DIR;
    }
    return linux.DT.REG;
}

fn addDir(parent: u16, name: []const u8) void {
    if (state.dir_count == max_dirs) {
        log("too many folders (limit {d}); {s} skipped", .{ max_dirs, name });
        return;
    }
    const up = &state.dirs[parent];
    const sep: usize = if (up.rel_len == 0) 0 else 1;
    if (up.rel_len + sep + name.len > max_path) {
        log("folder path too long; {s} skipped", .{name});
        return;
    }
    const dir = &state.dirs[state.dir_count];
    dir.* = .{ .parent = parent };
    @memcpy(dir.rel[0..up.rel_len], up.rel[0..up.rel_len]);
    if (sep == 1) dir.rel[up.rel_len] = '/';
    @memcpy(dir.rel[up.rel_len + sep ..][0..name.len], name);
    dir.rel_len = up.rel_len + sep + name.len;
    dir.class = if (parent == 0) inf.Class.fromFolder(name) else up.class;
    dir.boundary = parent == 0 and inf.isClassFolder(name);
    state.dir_count += 1;
}

fn addFile(dir: u16, dir_path: []const u8, name: []const u8) void {
    if (state.file_count == max_files or name.len > 255) {
        state.skipped_files += 1;
        log("skip file {s} (limit {d} files or name too long)", .{ name, max_files });
        return;
    }
    var buffer: [max_path * 2]u8 = undefined;
    var size: u64 = 0;
    if (z(&buffer, &.{ dir_path, "/", name })) |path| {
        const opened = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
        if (ok(opened)) {
            const end = linux.lseek(@intCast(opened), 0, 2);
            if (ok(end)) size = end;
            _ = linux.close(@intCast(opened));
        }
    }
    const file = &state.files[state.file_count];
    file.* = .{ .dir = dir, .size = size };
    @memcpy(file.name[0..name.len], name);
    file.name_len = name.len;
    file.is_inf = std.ascii.endsWithIgnoreCase(name, ".inf");
    if (file.is_inf) state.dirs[dir].inf_count += 1;
    state.file_count += 1;
}

fn ownerOf(dir: u16) ?u16 {
    return inf.owner(Dir, state.dirs[0..state.dir_count], dir);
}

fn hasFile(context: ?*anyopaque, name: []const u8) bool {
    const root: u16 = @intCast(@intFromPtr(context) - 1);
    const base_start = if (std.mem.lastIndexOfAny(u8, name, "\\/")) |i| i + 1 else 0;
    const base = name[base_start..];
    for (state.files[0..state.file_count]) |*file| {
        if (ownerOf(file.dir) != root) continue;
        if (std.ascii.eqlIgnoreCase(file.name[0..file.name_len], base)) return true;
    }
    return false;
}

fn judge(source: []const u8, targets: []const inf.Arch) void {
    for (state.files[0..state.file_count]) |*file| {
        if (!file.is_inf) continue;
        const dir = &state.dirs[file.dir];
        const name = file.name[0..file.name_len];
        const where = dir.rel[0..dir.rel_len];
        if (file.size == 0 or file.size > max_inf_bytes) {
            state.skipped_infs += 1;
            log("{s}/{s}: skip: size {d} (1 byte to 1 MiB)", .{ where, name, file.size });
            continue;
        }
        var buffer: [max_path * 2]u8 = undefined;
        const path = z(&buffer, &.{ source, "/", where, if (where.len == 0) "" else "/", name }) orelse continue;
        const opened = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
        if (!ok(opened)) {
            state.skipped_infs += 1;
            log("{s}/{s}: skip: cannot open", .{ where, name });
            continue;
        }
        const fd: i32 = @intCast(opened);
        const n: usize = @intCast(file.size);
        const read_ok = readAt(fd, 0, inf_raw[0..n]);
        _ = linux.close(fd);
        if (!read_ok) {
            state.skipped_infs += 1;
            log("{s}/{s}: skip: read failed", .{ where, name });
            continue;
        }
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(inf_raw[0..n], &hash, .{});
        var duplicate = false;
        for (state.hashes[0..state.hash_count]) |*seen| {
            if (std.mem.eql(u8, seen, &hash)) duplicate = true;
        }
        if (duplicate) {
            state.skipped_infs += 1;
            log("{s}/{s} ({s}): skip: duplicate of an INF already used", .{ where, name, dir.class.folder() });
            continue;
        }
        parsed = inf.parse(inf.decodeText(inf_raw[0..n], &inf_text));
        const result = inf.judge(&parsed, targets, @ptrFromInt(@as(usize, file.dir) + 1), hasFile);
        log("{s}/{s} ({s}, class={s}, provider={s}, ver={s}, arch={s}, catalog={s}): {s}{s}{s}", .{
            where,               name,                                      dir.class.folder(),    parsed.class,                                parsed.provider, parsed.driver_ver,
            result.arch.label(), parsed.catalogFor(result.arch) orelse "-", result.verdict.text(), if (result.missing.len != 0) " -> " else "", result.missing,
        });
        if (!result.verdict.accepted()) {
            state.skipped_infs += 1;
            continue;
        }
        state.used_infs += 1;
        dir.accepted += 1;
        if (state.hash_count < state.hashes.len) {
            state.hashes[state.hash_count] = hash;
            state.hash_count += 1;
        }
    }
}

// ------------------------------------------------------------ staging

fn freeBytes(path: [:0]const u8) ?u64 {
    // struct statfs (x86_64): f_type, f_bsize, f_blocks, f_bfree, f_bavail, ...
    var buffer: [15]i64 = undefined;
    const result = linux.syscall2(.statfs, @intFromPtr(path.ptr), @intFromPtr(&buffer));
    if (!ok(result)) return null;
    const bsize: u64 = @intCast(@max(buffer[1], 0));
    const avail: u64 = @bitCast(buffer[4]);
    return bsize * avail;
}

fn packageBytes(root: u16) u64 {
    var total: u64 = 0;
    for (state.files[0..state.file_count]) |*file| {
        if (ownerOf(file.dir) == root) total += file.size;
    }
    return total;
}

fn mkdirs(path: []u8) bool {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const saved = if (i < path.len) path[i] else 0;
            if (i < path.len) path[i] = 0;
            var buffer: [max_path * 2]u8 = undefined;
            const c = z(&buffer, &.{path[0..i]}) orelse return false;
            const result = linux.mkdir(c, 0o755);
            if (i < path.len) path[i] = saved;
            if (!ok(result) and linux.errno(result) != .EXIST) return false;
        }
    }
    return true;
}

fn copyFile(from: [:0]const u8, to: [:0]const u8, size: u64) bool {
    const in = linux.open(from, .{ .ACCMODE = .RDONLY }, 0);
    if (!ok(in)) return false;
    defer _ = linux.close(@intCast(in));
    const out = linux.open(to, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (!ok(out)) return false;
    defer _ = linux.close(@intCast(out));
    var done: u64 = 0;
    while (true) {
        const n = linux.read(@intCast(in), &copy_buffer, copy_buffer.len);
        if (!ok(n)) return false;
        if (n == 0) break;
        var written: usize = 0;
        while (written < n) {
            const w = linux.write(@intCast(out), copy_buffer[written..n].ptr, n - written);
            if (!ok(w) or w == 0) return false;
            written += w;
        }
        done += n;
    }
    return done == size;
}

fn stage(source: []const u8, destination: []const u8) void {
    var created = false;
    var dest_buffer: [max_path * 2]u8 = undefined;
    for ([_]inf.Class{ .storage, .usb, .other }) |class| {
        for (state.dirs[0..state.dir_count], 0..) |*dir, index| {
            if (dir.class != class or dir.accepted == 0) continue;
            const bytes = packageBytes(@intCast(index));
            if (!created) {
                const dest = z(&dest_buffer, &.{destination}) orelse return;
                if (!mkdirs(dest_buffer[0..dest.len])) {
                    log("cannot create {s}; no user drivers staged", .{destination});
                    return;
                }
                created = true;
            }
            const dest_z = z(&dest_buffer, &.{destination}) orelse return;
            const free = freeBytes(dest_z) orelse std.math.maxInt(u64);
            if (bytes + reserve_bytes > free) {
                log("package {s} ({s}, {d} bytes): skip: not enough free space on WORK ({d} bytes free, 64 MiB kept)", .{ dir.rel[0..dir.rel_len], class.folder(), bytes, free });
                continue;
            }
            state.packages += 1;
            dir.package = state.packages;
            dir.root_rel_len = dir.rel_len;
            log("package {d}: {s}\\{s}-{d:0>2} <- {s} ({d} bytes)", .{ state.packages, "$WinPEDriver$", class.folder(), state.packages, dir.rel[0..dir.rel_len], bytes });
        }
    }
    for (state.files[0..state.file_count]) |*file| {
        const owner = ownerOf(file.dir) orelse continue;
        const root = &state.dirs[owner];
        if (root.package == 0) continue;
        const dir = &state.dirs[file.dir];
        const inner = if (dir.rel_len > root.rel_len) dir.rel[root.rel_len + 1 .. dir.rel_len] else "";
        const name = file.name[0..file.name_len];
        if (7 + inner.len + 1 + name.len > max_windows_relative) {
            state.skipped_files += 1;
            log("{s}/{s}: skip: path too long for Windows Setup", .{ dir.rel[0..dir.rel_len], name });
            continue;
        }
        var package_name: [16]u8 = undefined;
        const package_folder = std.fmt.bufPrint(&package_name, "{s}-{d:0>2}", .{ root.class.folder(), root.package }) catch continue;
        var target_dir: [max_path * 2]u8 = undefined;
        const td = z(&target_dir, &.{ destination, "/", package_folder, if (inner.len == 0) "" else "/", inner }) orelse continue;
        if (!mkdirs(target_dir[0..td.len])) {
            state.skipped_files += 1;
            log("cannot create {s}", .{td});
            continue;
        }
        var from_buffer: [max_path * 2]u8 = undefined;
        var to_buffer: [max_path * 2]u8 = undefined;
        const from = z(&from_buffer, &.{ source, if (dir.rel_len == 0) "" else "/", dir.rel[0..dir.rel_len], "/", name }) orelse continue;
        const to = z(&to_buffer, &.{ td, "/", name }) orelse continue;
        if (!copyFile(from, to, file.size)) {
            state.skipped_files += 1;
            log("copy failed: {s}", .{from});
            continue;
        }
        state.copied_files += 1;
        state.copied_bytes += file.size;
    }
}
