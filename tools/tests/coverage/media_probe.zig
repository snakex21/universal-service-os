//! Read-only coverage CLI using the production optical/identity parsers.
const std = @import("std");
const usos = @import("usos");
const ra = usos.image_probe.random_access;
const udf = usos.image_probe.udf;
const iso = usos.image_probe.iso9660;
const media = usos.image_probe.windows_media;
const legacy = usos.image_probe.windows_legacy_media;

const View = struct {
    reader: *ra.FileReader,
    node: ?udf.Node = null,
    offset: u64 = 0,
    length: u64,
    fn read(self: *const View, offset: u64, buffer: []u8) !void {
        if (offset > self.length or buffer.len > self.length - offset) return error.MetadataBounds;
        if (self.node) |*node| return udf.readNodeAt(self.reader, node, offset, buffer);
        try ra.readExactAt(self.reader, self.offset + offset, buffer);
    }
};

fn open(reader: *ra.FileReader, path: []const u8) !?View {
    var node: udf.Node = undefined;
    if (udf.openPath(reader, path, &node)) |found| {
        if (!found or node.is_directory) return null;
        return .{ .reader = reader, .node = node, .length = node.size };
    } else |err| if (err != error.NotUdf) return err;
    const record = (try iso.findRecord(reader, path)) orelse return null;
    if (record.is_directory) return null;
    var pvd: [2048]u8 = undefined;
    try ra.readExactAt(reader, 16 * 2048, &pvd);
    return .{ .reader = reader, .offset = @as(u64, record.extent_lba) * std.mem.readInt(u16, pvd[128..130], .little), .length = record.size };
}

fn exists(reader: *ra.FileReader, path: []const u8) bool {
    return (open(reader, path) catch null) != null;
}

fn text(allocator: std.mem.Allocator, reader: *ra.FileReader, path: []const u8) ![]const u8 {
    const view = (try open(reader, path)) orelse return "";
    if (view.length > 2 * 1024 * 1024) return error.MetadataBounds;
    const bytes = try allocator.alloc(u8, @intCast(view.length));
    try view.read(0, bytes);
    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xfe) {
        const ascii = try allocator.alloc(u8, bytes.len / 2 - 1);
        for (ascii, 0..) |*ch, i| ch.* = if (bytes[3 + i * 2] == 0) bytes[2 + i * 2] else '?';
        return ascii;
    }
    return bytes;
}

fn wimXml(allocator: std.mem.Allocator, reader: *ra.FileReader, path: []const u8) !?[]u8 {
    const view = (try open(reader, path)) orelse return null;
    var header: [208]u8 = undefined;
    try view.read(0, &header);
    const resource = try usos.wim_setup.xmlResource(&header, view.length);
    const xml = try allocator.alloc(u8, resource.size);
    try view.read(resource.offset, xml);
    return xml;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    _ = args.next();
    const path = args.next() orelse return error.ExpectedIsoPath;
    if (std.mem.eql(u8, path, "--catalog")) {
        for (usos.catalog.systems.all) |system| {
            if (system.category != .windows) continue;
            const route = usos.catalog.os_profiles.select(&system, .iso, .automatic, .uefi);
            const line = try std.json.Stringify.valueAlloc(allocator, .{
                .id = system.id, .name = system.name, .directory = system.image_directory,
                .family = system.family, .uefi_profile = if (route) |r| r.id else null,
                .preparation_block = usos.catalog.preparation_block.reason(system.id),
            }, .{});
            std.debug.print("{s}\n", .{line});
        }
        return;
    }
    var reader = try ra.FileReader.open(init.io, std.Io.Dir.cwd(), path);
    defer reader.close();
    const detection: usos.image_probe.windows_detect.Result = usos.image_probe.windows_detect.inspect(&reader) catch .{};
    const source = legacy.Source{
        .txtsetup = try text(allocator, &reader, if (exists(&reader, "amd64/txtsetup.sif")) "amd64/txtsetup.sif" else "i386/txtsetup.sif"),
        .dosnet = try text(allocator, &reader, "i386/dosnet.inf"),
        .prodspec = try text(allocator, &reader, "i386/prodspec.ini"),
        .setupp = try text(allocator, &reader, "i386/setupp.ini"),
        .flp_wim = exists(&reader, "setup/wim/winflp.wim"),
        .posready_wim = exists(&reader, "setup/wim/setup.wim"),
        .media_center = exists(&reader, "cmpnents/mediactr"),
        .tablet_pc = exists(&reader, "cmpnents/tabletpc"),
    };
    // Directories are represented separately by optical_fs.findPath.
    var legacy_source = source;
    legacy_source.media_center = (usos.image_probe.optical_fs.findPath(&reader, "cmpnents/mediactr") catch null) != null;
    legacy_source.tablet_pc = (usos.image_probe.optical_fs.findPath(&reader, "cmpnents/tabletpc") catch null) != null;
    var presence = media.Presence{
        .efi_x64 = exists(&reader, media.efi_x64), .efi_ia32 = exists(&reader, media.efi_ia32),
        .efi_aa64 = exists(&reader, media.efi_aa64), .efi_ia64 = exists(&reader, media.efi_ia64),
        .bootmgr = exists(&reader, media.bios_bootmgr), .boot_wim = exists(&reader, media.boot_wim),
        .setup_exe = exists(&reader, media.setup_exe), .install_image = false,
    };
    if (try open(&reader, media.boot_wim)) |boot| {
        var header: [208]u8 = undefined;
        try boot.read(0, &header);
        if (wimXml(allocator, &reader, media.boot_wim) catch null) |xml| {
            const index = usos.wim_setup.bootIndex(&header) catch 0;
            presence.wim_arch = media.wimArch(xml, index) catch null;
        }
    }
    var install: media.Install = .{};
    for (usos.image_probe.windows_detect.modern_install_images) |name| {
        if (!exists(&reader, name)) continue;
        presence.install_image = true;
        if (wimXml(allocator, &reader, name) catch null) |xml| install = media.parseInstall(xml) catch .{};
        break;
    }
    var editions: [512]u8 = undefined;
    var modern = media.classify(presence);
    modern.install = install;
    const output = try std.json.Stringify.valueAlloc(allocator, .{
        .optical_detection = detection,
        .legacy = legacy.inspect(legacy_source),
        .modern = modern,
        .install = install,
        .language = install.languageTag(),
        .editions = media.formatEditions(install, &editions, "Core", "Desktop"),
        .suggested_folder = media.suggestedFolder(install),
    }, .{});
    std.debug.print("{s}\n", .{output});
}
