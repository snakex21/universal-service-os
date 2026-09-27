//! Native Windows start from an ISO on DATA through wimboot: the ISO's boot
//! files are loaded into a RAM file system and wimboot boots its WinPE; the
//! injected helpers (support.cpio) mount the same ISO read-only in WinPE and
//! run its own Setup. Nothing is copied to WORK.
//!
//!   Windows 7 / Vista   PE7 hybrid or the external PE10 donor (win7/vista-support.cpio)
//!   Windows 10 / 11     the ISO's own PE; modern-support.cpio adds the user drivers,
//!                       the answer file and the ESP guard/finalizer (/noreboot)
//!   WinPE / rescue ISO  booted as it is, without any USOS helper
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const udf = usos.image_probe.udf;
const ntfs = usos.storage.ntfs;
const wim = usos.wim_setup;
const data_volume = @import("data_volume.zig");
const files = @import("wimboot_files.zig");
const source_config = usos.windows_iso_config;
const esp_image = @import("esp_image_start.zig");
const serial = @import("serial.zig");
const scanner = usos.windows7_iso;
const directory_source = @import("catalog_ntfs_directory_source.zig");
const driver_files = @import("windows_driver_files.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const BootState = struct {
    catalog: data_volume.Catalog,
    source: ntfs.File,
    donor: ntfs.File,
    answer: ntfs.File,
    volume: files.Volume,
};
noinline fn initBootState(state: *BootState) !void {
    // Store the catalog before creating any reader: reader.context points into
    // catalog.block. Keep state stationary through donor probing and StartImage.
    state.catalog = try data_volume.openCatalog();
    state.volume = .{};
}
const Iso = struct {
    catalog: *data_volume.Catalog,
    file: *ntfs.File,
    pub fn size(self: *const Iso) u64 { return self.file.size(); }
    pub fn readAt(self: *const Iso, offset: u64, output: []u8) !usize {
        try self.file.readAt(self.catalog.fs, self.catalog.reader(), offset, output);
        return output.len;
    }
};
fn widen(name: []const u8, buffer: []u16) []const u16 {
    for (name, 0..) |ch, i| buffer[i] = ch;
    return buffer[0..name.len];
}
/// NTFS path components of `directory` (either separator) plus `name`.
pub const PathBuffer = struct {
    storage: [512]u16 = undefined,
    slices: [12][]const u16 = undefined,

    pub fn build(self: *PathBuffer, directory: []const u8, name: []const u8) ![]const []const u16 {
        if (directory.len + name.len > self.storage.len) return error.InvalidImageName;
        var count: usize = 0;
        var at: usize = 0;
        var parts = std.mem.tokenizeAny(u8, directory, "\\/");
        while (parts.next()) |part| {
            if (count + 1 >= self.slices.len) return error.InvalidImageName;
            self.slices[count] = widen(part, self.storage[at..]);
            at += part.len;
            count += 1;
        }
        self.slices[count] = widen(name, self.storage[at..]);
        return self.slices[0 .. count + 1];
    }
};
fn openIn(catalog: *data_volume.Catalog, directory: []const u8, name: []const u8, file: *ntfs.File) !void {
    try source_config.validateName(name);
    var path: PathBuffer = .{};
    try ntfs.openFile(catalog.fs, catalog.reader(), try path.build(directory, name), file);
}
fn openIso(catalog: *data_volume.Catalog, folder: []const u8, name: []const u8, file: *ntfs.File) !void {
    try source_config.validateName(name);
    try source_config.validateName(folder);
    var name_buffer: [255]u16 = undefined;
    var folder_buffer: [64]u16 = undefined;
    if (folder.len > folder_buffer.len) return error.UnsupportedWindowsFolder;
    const path = [_][]const u16{ wide("Systems"), wide("Windows"), widen(folder, &folder_buffer), wide("Images"), widen(name, &name_buffer) };
    try ntfs.openFile(catalog.fs, catalog.reader(), &path, file);
}

/// DATA folder of a Windows 7 / Vista route: "Windows 7", "Windows Vista"
/// or the Server folder ("Windows Server 2008 R2", "Windows Server 2008").
pub fn legacyFolder(system: *const usos.catalog.SystemEntry) []const u8 {
    return usos.catalog.os_profiles.windowsFolder(system) orelse
        if (usos.catalog.os_profiles.traits(system.id).native_uefi == .vista) "Windows Vista" else "Windows 7";
}
const DonorContext = struct {
    state: *BootState,
    pub fn probeDonor(self: *DonorContext, directory: []const u8, name: []const u8) !usos.wim_setup.Setup {
        try openIn(&self.state.catalog, directory, name, &self.state.donor);
        var iso = Iso{ .catalog = &self.state.catalog, .file = &self.state.donor };
        return scanner.inspectDonor(uefi.pool_allocator, &iso);
    }
};
fn inspectState(state: *BootState, folder: []const u8, name: []const u8, vista: bool) !scanner.Inspection {
    try openIso(&state.catalog, folder, name, &state.source);
    var iso = Iso{ .catalog = &state.catalog, .file = &state.source };
    const selected = if (vista) try scanner.inspectVista(uefi.pool_allocator, &iso) else try scanner.inspectSelected(uefi.pool_allocator, &iso);
    var adapter = directory_source.Adapter.init(state.catalog.fs, state.catalog.reader());
    var context = DonorContext{ .state = state };
    return scanner.resolveDonor(selected, adapter.source(), &context);
}
pub noinline fn inspect(folder: []const u8, name: []const u8, vista: bool) !scanner.Inspection {
    if (uefi.system_table.boot_services == null) return error.NoBootServices;
    // BootState inherits the BlockIo bounce buffer's 4096-byte alignment;
    // raw AllocatePool guarantees only 8 bytes. The typed allocator aligns it.
    const state = try uefi.pool_allocator.create(BootState);
    defer uefi.pool_allocator.destroy(state);
    try initBootState(state);
    const inspection = try inspectState(state, folder, name, vista);
    if (inspection.mode == .original) try checkDonorRecord(state, &inspection, null, null);
    return inspection;
}
pub fn externalDriverCount() !usize {
    var catalog = try data_volume.openCatalog();
    return driver_files.infCount(&catalog);
}
/// DATA\Drivers\<folder>\Storage has nothing in it (a missing folder or a
/// DATA that cannot be read counts as empty: the caller only shows a hint).
pub fn userStorageEmpty(folder: []const u8) bool {
    const catalog = uefi.pool_allocator.create(data_volume.Catalog) catch return true;
    defer uefi.pool_allocator.destroy(catalog);
    catalog.* = data_volume.openCatalog() catch return true;
    var adapter = directory_source.Adapter.init(catalog.fs, catalog.reader());
    var path: [128]u8 = undefined;
    const directory = std.fmt.bufPrint(&path, "Drivers\\{s}\\Storage", .{folder}) catch return true;
    var entries: [1]usos.catalog.directory_source.Entry = undefined;
    const page = adapter.source().listPage(directory, 0, &entries) catch return true;
    return page.count == 0;
}

/// DATA\Drivers\<folder>: [used, skipped] INFs, null when there are none.
pub fn userDriverCountsFor(folder: []const u8) ?[2]usize {
    const catalog = uefi.pool_allocator.create(data_volume.Catalog) catch return null;
    defer uefi.pool_allocator.destroy(catalog);
    catalog.* = data_volume.openCatalog() catch return null;
    return driver_files.userCountsFor(catalog, folder);
}

// ------------------------------------------------------------ donor record

pub const donor_record_path = scanner.donor_record_path;
pub const DonorRecord = scanner.DonorRecord;
const parseDonorRecord = scanner.parseDonorRecord;

fn readDonorRecord(root: *uefi.protocol.File) ?DonorRecord {
    const file = root.open(wide(donor_record_path), .read, .{}) catch return null;
    defer file.close() catch {};
    var buffer: [1024]u8 = undefined;
    const got = file.read(&buffer) catch return null;
    return parseDonorRecord(buffer[0..got]);
}

var record_root: ?*uefi.protocol.File = null;

/// Remembers the ESP root so the menu's inspection can read the record.
pub fn setEspRoot(root: *uefi.protocol.File) void {
    record_root = root;
}

/// The donor the menu resolved must be the one the installer recorded
/// (same name and size). With `progress`, its whole content is hashed too
/// (right before it is used). No record (older installs): structural checks only.
fn checkDonorRecord(state: *BootState, inspection: *const scanner.Inspection, root: ?*uefi.protocol.File, progress: ?*const fn (IsoStage, []const u8) void) !void {
    const esp = root orelse record_root orelse return;
    const record = readDonorRecord(esp) orelse return;
    if (!std.ascii.eqlIgnoreCase(record.nameSlice(), inspection.donor_name.slice())) return error.Windows10PeDonorNotRecorded;
    try openIn(&state.catalog, inspection.donor_directory, inspection.donor_name.slice(), &state.donor);
    const donor_bytes = ntfs.File.size(&state.donor);
    if (donor_bytes != record.size) return error.Windows10PeDonorCorrupt;
    const report = progress orelse return;
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const chunk = try bs.allocatePool(.loader_data, 8 * 1024 * 1024);
    defer bs.freePool(chunk.ptr) catch {};
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const total = donor_bytes;
    var offset: u64 = 0;
    var last_percent: u64 = 101;
    while (offset < total) {
        const amount: usize = @intCast(@min(total - offset, chunk.len));
        try state.donor.readAt(state.catalog.fs, state.catalog.reader(), offset, chunk[0..amount]);
        hash.update(chunk[0..amount]);
        offset += amount;
        const percent = offset * 100 / total;
        if (percent != last_percent and percent % 5 == 0) {
            last_percent = percent;
            var message: [96]u8 = undefined;
            report(.validating, std.fmt.bufPrint(&message, "Checking the WinPE helper image: {d}%", .{percent}) catch "Checking the WinPE helper image");
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    if (!std.mem.eql(u8, &digest, &record.sha256)) return error.Windows10PeDonorCorrupt;
    serial.writeAscii("[WIN7_NATIVE] PE10 donor SHA-256 matches winpe-donor.ini\r\n");
}

const IsoStage = @import("usos").flow.preparation_boot_progress.DirectIsoStage;

/// An answer rendered from a USOS profile (docs/answer-profiles.md): goes
/// into the RAM disk as usos-unattend.xml (the file the WinPE scripts use)
/// with usos-plan.ini next to it, instead of a DATA answer file.
pub const Rendered = struct {
    xml: []const u8,
    plan: []const u8,
};

/// `int10_dispatcher` (os_profiles trait): Vista's finalizer also installs
/// the USOS Int10 dispatcher on the target ESP (Windows 7 always does).
pub noinline fn start(root: *uefi.protocol.File, folder: []const u8, name: []const u8, answer_name: ?[]const u8, rendered: ?Rendered, vista: bool, int10_dispatcher: bool, progress: *const fn (IsoStage, []const u8) void) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.WindowsSetupRequiresX64;
    try source_config.validateName(name);
    if (answer_name) |answer| try source_config.validateName(answer);
    if (answer_name != null and rendered != null) return error.TwoAnswerSources;
    if (vista and rendered != null) return error.VistaUnattendedNotSupported;
    if (uefi.system_table.boot_services == null) return error.NoBootServices;
    const state = try uefi.pool_allocator.create(BootState);
    defer uefi.pool_allocator.destroy(state);
    try initBootState(state);
    const catalog = &state.catalog;
    if (vista and answer_name != null) return error.VistaUnattendedNotSupported;
    progress(.validating, "Validating the installation ISO and resolving the boot source");
    const inspection = try inspectState(state, folder, name, vista);
    const source = &state.source;
    const external_pe10 = inspection.mode == .original;
    if (external_pe10) {
        try checkDonorRecord(state, &inspection, root, progress);
        // Reopen the chosen donor: enumeration may have probed other candidates.
        var context = DonorContext{ .state = state };
        const current = try context.probeDonor(inspection.donor_directory, inspection.donor_name.slice());
        if (!std.meta.eql(current, inspection.boot_setup)) return error.Windows10PeDonorChanged;
    }
    var boot_iso = Iso{ .catalog = catalog, .file = if (external_pe10) &state.donor else source };
    const setup = inspection.boot_setup;
    var boot_message: [384]u8 = undefined;
    serial.writeAscii(try std.fmt.bufPrint(&boot_message, "[WIN7_NATIVE] {s}; boot ISO={s}; PE={d}.{d}.{d} x64 index={d}\r\n", .{
        if (vista) "Vista SP2 x64 -> external PE10" else inspection.mode.label(), inspection.bootName(name), setup.major, setup.minor, setup.build, setup.index,
    }));
    progress(.validating, inspection.bootName(name));
    const volume = &state.volume;
    var owned = Owned{};
    defer owned.release();
    var config: [544]u8 = undefined;
    // The client folders keep the plan's defaults (hardware-tested order and names).
    const client_folder = std.mem.eql(u8, folder, if (vista) "Windows Vista" else "Windows 7");
    const plan = usos.flow.plan.wimbootPlan(.{ .kind = if (vista) .vista else .win7, .folder = if (client_folder) "" else folder, .answer = answer_name != null or rendered != null, .external_pe10 = external_pe10, .nvme_packages = inspection.nvme_packages, .int10_dispatcher = int10_dispatcher });
    try inject(root, state, volume, &owned, &boot_iso, &plan, name, answer_name, rendered, &config, progress);
    return launch(root, volume, setup.index, if (external_pe10) "Starting external PE10; the install source remains the selected Windows ISO" else "Starting the hybrid ISO's own WinPE and Setup", progress);
}

// ------------------------------------ Vista without firmware CSM (CSMWrap)

/// Where the UEFI menu leaves the Vista CSMWrap request for the micro-Linux
/// preparation (tools/vista_csmwrap_prepare.sh).
pub const csmwrap_directory = "\\EFI\\USOS\\vista-csmwrap";

pub const CsmwrapAnswer = union(enum) {
    none,
    /// A USOS profile rendered to \EFI\USOS\answer (answer_profiles.stage).
    profile,
    /// A file from Systems\Windows\<folder>\Unattended.
    file: []const u8,
};

/// request.ini: DATA-relative paths of the Vista ISO and the PE10 donor, the
/// DATA system folder and the answer source. No key or password in it.
pub fn formatCsmwrapRequest(buffer: []u8, folder: []const u8, name: []const u8, donor_directory: []const u8, donor_name: []const u8, answer: CsmwrapAnswer) ![]const u8 {
    try source_config.validateName(folder);
    try source_config.validateName(name);
    try source_config.validateName(donor_name);
    var donor_dir: [128]u8 = undefined;
    if (donor_directory.len > donor_dir.len or donor_directory.len == 0) return error.InvalidImageName;
    for (donor_directory, 0..) |c, i| donor_dir[i] = if (c == '\\') '/' else c;
    const dir = std.mem.trim(u8, donor_dir[0..donor_directory.len], "/");
    if (std.mem.indexOf(u8, dir, "..") != null) return error.InvalidImageName;
    var answer_text: [300]u8 = undefined;
    const answer_value = switch (answer) {
        .none => "none",
        .profile => "profile",
        .file => |file| blk: {
            try source_config.validateName(file);
            break :blk try std.fmt.bufPrint(&answer_text, "file:{s}", .{file});
        },
    };
    return std.fmt.bufPrint(buffer, "version=1\r\nprofile=vista-x64-sp2-uefi-csmwrap\r\niso=Systems/Windows/{s}/Images/{s}\r\ndonor={s}/{s}\r\nfolder={s}\r\nanswer={s}\r\n", .{ folder, name, dir, donor_name, folder, answer_value });
}

fn ensureEspDirectory(root: *uefi.protocol.File, path_text: []const u8) !void {
    var name: [96]u16 = undefined;
    const units = try std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], path_text);
    name[units] = 0;
    const z: [*:0]const u16 = @ptrCast(&name);
    const dir = try root.open(z, .read_write_create, .{ .directory = true });
    dir.close() catch {};
}

/// Vista without firmware CSM (profile vista-x64-sp2-uefi-csmwrap): the same
/// ISO and PE10 donor checks as the wimboot start (donor hashed against
/// winpe-donor.ini), then the request for the micro-Linux preparation:
/// usos-source.ini (the DATA binding the wimboot start injects) and
/// request.ini in \EFI\USOS\vista-csmwrap. Nothing is booted here.
pub noinline fn prepareCsmwrap(root: *uefi.protocol.File, folder: []const u8, name: []const u8, answer: CsmwrapAnswer, progress: *const fn (IsoStage, []const u8) void) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.WindowsSetupRequiresX64;
    try source_config.validateName(name);
    if (uefi.system_table.boot_services == null) return error.NoBootServices;
    const state = try uefi.pool_allocator.create(BootState);
    defer uefi.pool_allocator.destroy(state);
    try initBootState(state);
    progress(.validating, "Validating the installation ISO and resolving the boot source");
    const inspection = try inspectState(state, folder, name, true);
    // The CSMWrap path always boots the PE10 donor (it has the USB 3 stack).
    if (inspection.mode != .original) return error.Windows10PeDonorMissing;
    try checkDonorRecord(state, &inspection, root, progress);
    var context = DonorContext{ .state = state };
    const current = try context.probeDonor(inspection.donor_directory, inspection.donor_name.slice());
    if (!std.meta.eql(current, inspection.boot_setup)) return error.Windows10PeDonorChanged;
    var config: [544]u8 = undefined;
    const binding = try source_config.sourceConfigForFolder(&config, state.catalog.partition.part_guid, state.source.size(), folder, name);
    var request: [1024]u8 = undefined;
    const text = try formatCsmwrapRequest(&request, folder, name, inspection.donor_directory, inspection.donor_name.slice(), answer);
    const settings_store = @import("settings_store.zig");
    try ensureEspDirectory(root, csmwrap_directory);
    try settings_store.replaceFile(root, csmwrap_directory ++ "\\usos-source.ini", binding);
    try settings_store.replaceFile(root, csmwrap_directory ++ "\\request.ini", text);
    serial.writeAscii("[VISTA_CSMWRAP] request written: ");
    serial.writeAscii(text);
}

test "Vista CSMWrap request names DATA-relative paths and the answer source" {
    var buffer: [1024]u8 = undefined;
    const text = try formatCsmwrapRequest(&buffer, "Windows Vista", "pl_vista.iso", "Programs/USOS/WinPE", "PE10.iso", .none);
    try std.testing.expectEqualStrings("version=1\r\nprofile=vista-x64-sp2-uefi-csmwrap\r\niso=Systems/Windows/Windows Vista/Images/pl_vista.iso\r\ndonor=Programs/USOS/WinPE/PE10.iso\r\nfolder=Windows Vista\r\nanswer=none\r\n", text);
    const legacy = try formatCsmwrapRequest(&buffer, "Windows Server 2008", "srv.iso", "Systems\\Windows\\Windows 10\\Images", "PE10.iso", .{ .file = "a.xml" });
    try std.testing.expect(std.mem.indexOf(u8, legacy, "donor=Systems/Windows/Windows 10/Images/PE10.iso\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, legacy, "answer=file:a.xml\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, try formatCsmwrapRequest(&buffer, "Windows Vista", "v.iso", "Programs/USOS/WinPE", "PE10.iso", .profile), "answer=profile\r\n"));
    try std.testing.expectError(error.InvalidImageName, formatCsmwrapRequest(&buffer, "Windows Vista", "v.iso", "../x", "PE10.iso", .none));
    try std.testing.expectError(error.InvalidImageName, formatCsmwrapRequest(&buffer, "Windows Vista", "a/b.iso", "Programs/USOS/WinPE", "PE10.iso", .none));
}

// ------------------------------------------------- Windows 10/11 and WinPE

pub const systemFolder = scanner.systemFolder;

pub const ModernInspection = struct {
    setup: wim.Setup,
    install: []const u8,
};

/// Windows 10/11 Setup media: x64 boot.wim (its declared boot index) of
/// version 10, BCD and boot.sdi, sources/setup.exe and an install image.
fn inspectModernIso(iso: anytype) !ModernInspection {
    const setup = try scanner.setupInfo(uefi.pool_allocator, iso);
    if (setup.major != 10) return error.UnsupportedWindowsSetupVersion;
    try scanner.validateBootFiles(iso);
    var node: udf.Node = undefined;
    if (!try udf.openPath(iso, "sources/setup.exe", &node) or node.is_directory or node.size == 0) return error.WindowsSetupMissing;
    for (usos.image_probe.windows_detect.modern_install_images) |path| {
        if (try udf.openPath(iso, path, &node) and !node.is_directory and node.size > 0) return .{ .setup = setup, .install = path };
    }
    return error.WindowsInstallImageMissing;
}

pub noinline fn inspectModern(image_directory: []const u8, name: []const u8) !ModernInspection {
    if (uefi.system_table.boot_services == null) return error.NoBootServices;
    const state = try uefi.pool_allocator.create(BootState);
    defer uefi.pool_allocator.destroy(state);
    try initBootState(state);
    try openIn(&state.catalog, image_directory, name, &state.source);
    var iso = Iso{ .catalog = &state.catalog, .file = &state.source };
    return inspectModernIso(&iso);
}

/// Starts Windows 10/11 Setup from the selected ISO (`winpe == false`) or a
/// WinPE/rescue ISO as it is (`winpe == true`, no USOS helpers, no Setup).
pub noinline fn startModern(root: *uefi.protocol.File, image_directory: []const u8, name: []const u8, answer_name: ?[]const u8, rendered: ?Rendered, winpe: bool, progress: *const fn (IsoStage, []const u8) void) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.WindowsSetupRequiresX64;
    try source_config.validateName(name);
    if (answer_name) |answer| try source_config.validateName(answer);
    if (answer_name != null and rendered != null) return error.TwoAnswerSources;
    if (winpe and (answer_name != null or rendered != null)) return error.WinPeHasNoAnswerFile;
    const folder = try systemFolder(image_directory);
    const state = try uefi.pool_allocator.create(BootState);
    defer uefi.pool_allocator.destroy(state);
    try initBootState(state);
    const catalog = &state.catalog;
    progress(.validating, "Reading the selected Windows ISO");
    try openIn(catalog, image_directory, name, &state.source);
    var iso = Iso{ .catalog = catalog, .file = &state.source };
    const setup = if (winpe) blk: {
        const pe = try scanner.setupInfo(uefi.pool_allocator, &iso);
        try scanner.validateBootFiles(&iso);
        break :blk pe;
    } else (try inspectModernIso(&iso)).setup;
    var message: [384]u8 = undefined;
    serial.writeAscii(try std.fmt.bufPrint(&message, "[WIN_NATIVE] {s} {s}\\{s}; PE={d}.{d}.{d} x64 index={d}; no WORK copy\r\n", .{
        if (winpe) "WinPE boot" else "Windows Setup", folder, name, setup.major, setup.minor, setup.build, setup.index,
    }));
    progress(.validating, name);
    const volume = &state.volume;
    var owned = Owned{};
    defer owned.release();
    var config: [544]u8 = undefined;
    const plan = usos.flow.plan.wimbootPlan(.{ .kind = if (winpe) .winpe else .modern_setup, .folder = folder, .answer = answer_name != null or rendered != null });
    try inject(root, state, volume, &owned, &iso, &plan, name, answer_name, rendered, &config, progress);
    return launch(root, volume, setup.index, if (winpe) "Starting WinPE from the ISO; nothing is installed" else "Starting the ISO's own WinPE and Windows Setup", progress);
}

// ------------------------------------------------------------------ shared

const Owned = struct {
    items: [10][]align(8) u8 = undefined,
    count: usize = 0,

    fn keep(self: *Owned, bytes: []align(8) u8) !void {
        if (self.count == self.items.len) return error.TooManyWimbootBuffers;
        self.items[self.count] = bytes;
        self.count += 1;
    }

    fn allocate(self: *Owned, size: usize) ![]align(8) u8 {
        const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
        const bytes = try bs.allocatePool(.loader_data, size);
        self.keep(bytes) catch |err| {
            bs.freePool(bytes.ptr) catch {};
            return err;
        };
        return bytes;
    }

    fn release(self: *Owned) void {
        const bs = uefi.system_table.boot_services orelse return;
        for (self.items[0..self.count]) |allocation| bs.freePool(allocation.ptr) catch {};
        self.count = 0;
    }
};

/// Fills the wimboot RAM disk exactly as `plan` lists it
/// (src/flow/plan.zig, pinned by the routing golden). `config` must outlive
/// the launch: the volume keeps references, not copies.
fn inject(root: *uefi.protocol.File, state: *BootState, volume: *files.Volume, owned: *Owned, boot_iso: *Iso, plan: *const usos.flow.plan.WimbootPlan, name: []const u8, answer_name: ?[]const u8, rendered: ?Rendered, config: *[544]u8, progress: *const fn (IsoStage, []const u8) void) !void {
    const catalog = &state.catalog;
    for (plan.slice(), 0..) |item, index| {
        var line: [192]u8 = undefined;
        var described: [160]u8 = undefined;
        serial.writeAscii(std.fmt.bufPrint(&line, "[WIMBOOT_PLAN] {d}: {s}\r\n", .{ index, usos.flow.plan.describe(item, &described) catch "?" }) catch "[WIMBOOT_PLAN] ?\r\n");
        switch (item) {
            .support => |support| try addSupport(root, volume, owned, support.path, support.limit_mib),
            .flag => |flag_name| try volume.add(flag_name, usos.flow.plan.flag_content),
            .bundled_drivers => |user_folder| {
                progress(.loading, "Reading optional Windows 7 x64 driver packages");
                const drivers = try driver_files.loadWithUser(catalog, user_folder);
                try owned.keep(drivers.bytes);
                try volume.add("usos-drivers.bin", drivers.bytes);
                var driver_message: [128]u8 = undefined;
                serial.writeAscii(try std.fmt.bufPrint(&driver_message, "[WIN7_NATIVE] external driver INF files={d}; user INFs used={d} skipped={d}; Windows validates hardware match\r\n", .{ drivers.inf_count, drivers.user_infs, drivers.user_skipped }));
            },
            .user_drivers => |folder| {
                progress(.loading, "Reading your driver packages (DATA\\Drivers)");
                if (try driver_files.loadUser(catalog, folder)) |drivers| {
                    try owned.keep(drivers.bytes);
                    try volume.add("usos-drivers.bin", drivers.bytes);
                    var driver_message: [128]u8 = undefined;
                    serial.writeAscii(try std.fmt.bufPrint(&driver_message, "[WIN_NATIVE] user INFs used={d} skipped={d} (Drivers\\{s})\r\n", .{ drivers.user_infs, drivers.user_skipped, folder }));
                }
            },
            .source_ini => |folder| try volume.add("usos-source.ini", try source_config.sourceConfigForFolder(config, catalog.partition.part_guid, state.source.size(), folder, name)),
            .answer => |folder| if (rendered) |answer| {
                // A USOS profile rendered just now: the same file name the
                // WinPE scripts look for, plus the plan (no key in it).
                try volume.add("usos-unattend.xml", answer.xml);
                try volume.add("usos-plan.ini", answer.plan);
                var answer_message: [96]u8 = undefined;
                serial.writeAscii(try std.fmt.bufPrint(&answer_message, "[WIMBOOT_PLAN] answer rendered from a USOS profile: {d} bytes\r\n", .{answer.xml.len}));
            } else try addAnswer(state, volume, owned, folder, answer_name orelse return error.AnswerFileMissing),
            .boot_files => try addBootFiles(boot_iso, volume, owned, progress),
        }
    }
}

fn addSupport(root: *uefi.protocol.File, volume: *files.Volume, owned: *Owned, path: []const u8, limit_mib: usize) !void {
    var path16: [96:0]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&path16, path);
    path16[n] = 0;
    const file = try root.open(path16[0..n :0], .read, .{});
    defer file.close() catch {};
    const bytes = try owned.allocate(limit_mib * 1024 * 1024);
    const len = try file.read(bytes);
    if (len == bytes.len) return error.SupportArchiveTooLarge;
    try volume.addCpio(bytes[0..len]);
}

fn addBootFiles(boot_iso: *Iso, volume: *files.Volume, owned: *Owned, progress: *const fn (IsoStage, []const u8) void) !void {
    var node: udf.Node = undefined;
    const names = [_][]const u8{ "BCD", "boot.sdi", "boot.wim" };
    for (scanner.boot_paths, names) |boot_path, boot_name| {
        if (!try udf.openPath(boot_iso, boot_path, &node) or node.is_directory or node.size == 0 or node.size > scanner.max_boot_file_size) return error.InvalidWindowsBootFile;
        const bytes = try owned.allocate(@intCast(node.size));
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = @min(bytes.len - offset, 1024 * 1024);
            try udf.readNodeAt(boot_iso, &node, offset, bytes[offset..][0..amount]);
            offset += amount;
            if (std.mem.eql(u8, boot_name, "boot.wim") and (offset % (8 * 1024 * 1024) == 0 or offset == bytes.len)) {
                var message: [100]u8 = undefined;
                progress(.loading, try std.fmt.bufPrint(&message, "Loading boot-source boot.wim: {d}%", .{offset * 100 / bytes.len}));
            }
        }
        try volume.add(boot_name, bytes);
    }
}

fn addAnswer(state: *BootState, volume: *files.Volume, owned: *Owned, folder: []const u8, answer: []const u8) !void {
    const catalog = &state.catalog;
    var directory: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&directory, "Systems\\Windows\\{s}\\Unattended", .{folder});
    try openIn(catalog, path, answer, &state.answer);
    if (state.answer.size() == 0 or state.answer.size() > 1024 * 1024) return error.InvalidAnswerFileSize;
    const bytes = try owned.allocate(@intCast(state.answer.size()));
    try state.answer.readAt(catalog.fs, catalog.reader(), 0, bytes);
    try volume.add("usos-unattend.xml", bytes);
}

fn launch(root: *uefi.protocol.File, volume: *files.Volume, index: u32, starting: []const u8, progress: *const fn (IsoStage, []const u8) void) !void {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const image = try esp_image.load(root, "\\EFI\\USOS\\windows-native\\wimboot");
    defer _ = bs._unloadImage(image);
    const handle = try files.install(volume);
    defer files.uninstall(handle, volume);
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, image)) orelse return error.NoLoadedImage;
    loaded.device_handle = handle;
    var option_text: [32]u8 = undefined;
    const option_ascii = try @import("diagnostic_boot.zig").wimbootOptions(&option_text, index, @import("diagnostic_boot.zig").requested(root));
    var options: [32:0]u16 = undefined;
    for (option_ascii, 0..) |ch, i| options[i] = ch;
    options[option_ascii.len] = 0;
    loaded.load_options = &options;
    loaded.load_options_size = @intCast((option_ascii.len + 1) * 2);
    progress(.starting, starting);
    serial.writeAscii("[WIN7_NATIVE] CORE -> WIMBOOT UEFI\r\n");
    const code = try @import("verified_image.zig").start(image);
    if (code != .success) return error.WimbootReturnedError;
    return error.WimbootReturned;
}

test "path buffer splits either separator" {
    var buffer: PathBuffer = .{};
    const parts = try buffer.build("Programs/USOS/WinPE", "PE10.iso");
    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expectEqualSlices(u16, wide("WinPE"), parts[2]);
    const other = try buffer.build("\\Systems\\Windows\\Windows 10\\Images", "a.iso");
    try std.testing.expectEqual(@as(usize, 5), other.len);
    try std.testing.expectEqualSlices(u16, wide("a.iso"), other[4]);
}
