//! Reads what each Windows ISO in an image list contains (architecture,
//! Setup media or WinPE) straight from DATA, for the image list badges and
//! the start gates (image_probe/windows_media.zig). A few UDF/ISO9660
//! directory lookups per ISO; the boot.wim metadata is read only for media
//! without an EFI loader. Results are cached per name and size for the menu
//! session, so returning to a list does not read the ISOs again.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const ntfs = usos.storage.ntfs;
const media = usos.image_probe.windows_media;
const optical_fs = usos.image_probe.optical_fs;
const udf = usos.image_probe.udf;
const wim = usos.wim_setup;
const data_volume = @import("data_volume.zig");
const native = @import("windows_native_iso.zig");
const serial = @import("serial.zig");

const CacheEntry = struct {
    used: bool = false,
    directory_hash: u64 = 0,
    name: usos.catalog.FixedText = .{},
    size: u64 = 0,
    info: media.Info = .{},
};
var cache: [48]CacheEntry = [_]CacheEntry{.{}} ** 48;
var cache_next: usize = 0;

/// Firmware this build runs on, for `media.block`.
pub fn firmware() media.Firmware {
    return switch (@import("builtin").cpu.arch) {
        .x86 => .uefi_ia32,
        .x86_64 => .uefi_x64,
        // ARM builds do not gate Windows media here.
        else => .bios,
    };
}

/// Windows systems whose ISOs are probed (modern Windows boot media: the
/// client versions Vista to 11 and Windows Server 2008 to 2025).
pub fn applies(system: *const usos.catalog.SystemEntry) bool {
    return system.family == .windows;
}

const State = struct {
    catalog: data_volume.Catalog,
    file: ntfs.File,
};

const Iso = struct {
    state: *State,
    pub fn size(self: *const Iso) u64 {
        return self.state.file.size();
    }
    pub fn readAt(self: *const Iso, offset: u64, output: []u8) !usize {
        const total = self.state.file.size();
        if (offset >= total) return 0;
        const amount: usize = @intCast(@min(output.len, total - offset));
        try self.state.file.readAt(self.state.catalog.fs, self.state.catalog.reader(), offset, output[0..amount]);
        return amount;
    }
};

/// Fills `images.items[i].media` for every ISO of a probed system.
pub fn probeList(system: *const usos.catalog.SystemEntry, images: *usos.catalog.ImageList) void {
    if (!applies(system)) return;
    var any = false;
    for (images.items[0..images.len]) |image| {
        if (image.kind == .iso) any = true;
    }
    if (!any) return;
    const state = uefi.pool_allocator.create(State) catch return;
    defer uefi.pool_allocator.destroy(state);
    state.catalog = data_volume.openCatalog() catch return;
    const directory_hash = std.hash.Wyhash.hash(0, system.image_directory);
    for (images.items[0..images.len]) |*image| {
        if (image.kind != .iso) continue;
        image.media = probeOne(state, system.image_directory, directory_hash, image.name);
    }
}

fn probeOne(state: *State, directory: []const u8, directory_hash: u64, name: usos.catalog.FixedText) media.Info {
    var path: native.PathBuffer = .{};
    const components = path.build(directory, name.slice()) catch return .{ .unreadable = true };
    ntfs.openFile(state.catalog.fs, state.catalog.reader(), components, &state.file) catch return .{ .unreadable = true };
    const size = state.file.size();
    for (&cache) |*entry| {
        if (entry.used and entry.directory_hash == directory_hash and entry.size == size and std.mem.eql(u8, entry.name.slice(), name.slice())) return entry.info;
    }
    const info = inspect(state) catch |err| blk: {
        var message: [160]u8 = undefined;
        serial.writeAscii(std.fmt.bufPrint(&message, "[MEDIA] {s}: unreadable ({s})\r\n", .{ name.slice(), @errorName(err) }) catch "[MEDIA] unreadable\r\n");
        break :blk media.Info{ .unreadable = true };
    };
    var message: [400]u8 = undefined;
    serial.writeAscii(std.fmt.bufPrint(&message, "[MEDIA] {s}: arch={s} content={s} uefi_x64={} bios={} install_images={d} server={} client={} ia64={} version={d}.{d}.{d}\r\n", .{
        name.slice(),         if (info.arch == .unknown) "unknown" else info.arch.label(), @tagName(info.content), info.uefi_x64, info.bios,
        info.install.images,  info.install.server,                                     info.install.client,     info.install.ia64,
        info.install.major,   info.install.minor,                                      info.install.build,
    }) catch "[MEDIA]\r\n");
    cache[cache_next] = .{ .used = true, .directory_hash = directory_hash, .name = name, .size = size, .info = info };
    cache_next = (cache_next + 1) % cache.len;
    return info;
}

fn exists(iso: *const Iso, path: []const u8) !bool {
    const found = optical_fs.findPath(iso, path) catch |err| switch (err) {
        error.NotIso9660 => return error.NotOpticalMedia,
        else => return err,
    };
    return if (found) |info| !info.is_directory and info.size > 0 else false;
}

fn inspect(state: *State) !media.Info {
    const iso = Iso{ .state = state };
    var presence = media.Presence{
        .efi_x64 = try exists(&iso, media.efi_x64),
        .efi_ia32 = try exists(&iso, media.efi_ia32),
        .efi_aa64 = try exists(&iso, media.efi_aa64),
        .efi_ia64 = try exists(&iso, media.efi_ia64),
        .bootmgr = try exists(&iso, media.bios_bootmgr),
        .boot_wim = try exists(&iso, media.boot_wim),
        .setup_exe = try exists(&iso, media.setup_exe),
    };
    var install_path: ?[]const u8 = null;
    for (usos.image_probe.windows_detect.modern_install_images) |path| {
        if (try exists(&iso, path)) {
            presence.install_image = true;
            install_path = path;
            break;
        }
    }
    // Only media without any EFI loader need the boot.wim metadata.
    if (presence.boot_wim and !presence.efi_x64 and !presence.efi_ia32 and !presence.efi_aa64)
        presence.wim_arch = bootWimArch(&iso) catch null;
    var info = media.classify(presence);
    // What the install image installs (client/Server, editions, IA64).
    if (install_path) |path| info.install = installInfo(&iso, path) catch .{};
    return info;
}

/// install.wim/esd/swm XML metadata (uncompressed in every WIM version).
fn installInfo(iso: *const Iso, path: []const u8) !media.Install {
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, path, &node) or node.is_directory) return error.WindowsInstallImageMissing;
    var header: [124]u8 = undefined;
    try udf.readNodeAt(iso, &node, 0, &header);
    const resource = try wim.xmlResource(&header, node.size);
    const bytes = try uefi.pool_allocator.alloc(u8, resource.size);
    defer uefi.pool_allocator.free(bytes);
    try udf.readNodeAt(iso, &node, resource.offset, bytes);
    return media.parseInstall(bytes);
}

fn bootWimArch(iso: *const Iso) !u32 {
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, media.boot_wim, &node) or node.is_directory) return error.InvalidWindowsBootFile;
    var header: [124]u8 = undefined;
    try udf.readNodeAt(iso, &node, 0, &header);
    const resource = try wim.xmlResource(&header, node.size);
    const bytes = try uefi.pool_allocator.alloc(u8, resource.size);
    defer uefi.pool_allocator.free(bytes);
    try udf.readNodeAt(iso, &node, resource.offset, bytes);
    return media.wimArch(bytes, try wim.bootIndex(&header));
}

/// The install images (index, names, edition) of a Windows ISO of
/// `system`, for the answer profile's edition (answer.editions). Read on
/// demand from DATA (the install image's XML metadata only).
pub fn readEditions(system: *const usos.catalog.SystemEntry, image_name: []const u8, out: *usos.flow.answer.editions.List) !void {
    out.len = 0;
    const state = try uefi.pool_allocator.create(State);
    defer uefi.pool_allocator.destroy(state);
    state.catalog = try data_volume.openCatalog();
    var path: native.PathBuffer = .{};
    const components = try path.build(system.image_directory, image_name);
    try ntfs.openFile(state.catalog.fs, state.catalog.reader(), components, &state.file);
    const iso = Iso{ .state = state };
    for (usos.image_probe.windows_detect.modern_install_images) |install| {
        if (!try exists(&iso, install)) continue;
        var node: udf.Node = undefined;
        if (!try udf.openPath(&iso, install, &node) or node.is_directory) return error.WindowsInstallImageMissing;
        var header: [124]u8 = undefined;
        try udf.readNodeAt(&iso, &node, 0, &header);
        const resource = try wim.xmlResource(&header, node.size);
        const bytes = try uefi.pool_allocator.alloc(u8, resource.size);
        defer uefi.pool_allocator.free(bytes);
        try udf.readNodeAt(&iso, &node, resource.offset, bytes);
        usos.flow.answer.editions.parse(try media.installXmlAscii(bytes), out);
        var message: [120]u8 = undefined;
        serial.writeAscii(std.fmt.bufPrint(&message, "[MEDIA] {s}: {d} install images\r\n", .{ image_name, out.len }) catch "[MEDIA] install images\r\n");
        return;
    }
    return error.WindowsInstallImageMissing;
}
