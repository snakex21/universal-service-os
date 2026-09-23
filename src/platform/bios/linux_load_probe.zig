const std = @import("std");
const storage = @import("storage");
const console = @import("console.zig");
const e820 = @import("e820.zig");
const linux_boot_header = @import("linux_boot_header.zig");
const linux_boot_params = @import("linux_boot_params.zig");
const linux_memory = @import("linux_memory.zig");
const vbe_probe = @import("vbe_probe.zig");
const graphics_menu = @import("graphics_menu.zig");

const fat32 = storage.fat32;
const random_reader = storage.random_reader;

const p_efi = [_]u16{ 'E', 'F', 'I' };
const p_usos = [_]u16{ 'U', 'S', 'O', 'S' };
const p_micro = [_]u16{ 'm', 'i', 'c', 'r', 'o', '-', 'l', 'i', 'n', 'u', 'x' };
const p_kernel = [_]u16{ 'v', 'm', 'l', 'i', 'n', 'u', 'z', '-', 'v', 'i', 'r', 't' };
const p_initramfs = [_]u16{ 'i', 'n', 'i', 't', 'r', 'a', 'm', 'f', 's', '-', 'u', 's', 'o', 's' };
const p_probe_marker = [_]u16{ 'l', 'e', 'g', 'a', 'c', 'y', '-', 'l', 'i', 'n', 'u', 'x', '-', 'p', 'r', 'o', 'b', 'e', '.', 'f', 'l', 'a', 'g' };
const p_boot_marker = [_]u16{ 'l', 'e', 'g', 'a', 'c', 'y', '-', 'l', 'i', 'n', 'u', 'x', '-', 'b', 'o', 'o', 't', '.', 'f', 'l', 'a', 'g' };

const p_lang_cpio = [_]u16{ 'l', 'a', 'n', 'g', '.', 'c', 'p', 'i', 'o' };
const kernel_path = [_][]const u16{ &p_efi, &p_usos, &p_micro, &p_kernel };
/// lang.bin as a newc archive (written by the installer); appended to the
/// initramfs so usos-fb-ui finds /etc/usos/lang.bin.
const lang_cpio_path = [_][]const u16{ &p_efi, &p_usos, &p_lang_cpio };
const initramfs_path = [_][]const u16{ &p_efi, &p_usos, &p_micro, &p_initramfs };
const probe_marker_path = [_][]const u16{ &p_efi, &p_usos, &p_probe_marker };
const boot_marker_path = [_][]const u16{ &p_efi, &p_usos, &p_boot_marker };

const Mode = enum { load_only, boot };

pub const Error = fat32.Error || linux_boot_header.ParseError || linux_boot_header.ImageError || linux_boot_header.CompatibilityError || linux_boot_params.Error || linux_memory.Error || e820.Error || error{
    ShortHeaderRead,
    ShortKernelRead,
    ShortInitramfsRead,
    AddressNotReachable,
    BadInitramfsMagic,
    CpuNoLongMode,
    BootParamsMemoryNotUsable,
    CommandLineMemoryNotUsable,
    VesaModeLostBeforeHandoff,
    UnsupportedWindowsSystem,
};

const BiosDriveInfoRaw = extern struct {
    sectors_low: u32,
    sectors_high: u32,
    bytes_per_sector: u16,
    cylinders: u16,
    heads: u16,
    sectors_per_track: u16,
};

const BiosInventory = struct {
    encoded: [1024]u8 = undefined,
    len: usize = 0,
    detected: u8 = 0,
    edd_sized: u8 = 0,

    fn slice(self: *const BiosInventory) []const u8 {
        return self.encoded[0..self.len];
    }
};

const LoadProgress = struct {
    session: ?vbe_probe.Session,
    total: u32,
    base: u32 = 0,
    last_percent: u8 = 255,

    fn sink(self: *LoadProgress) fat32.ReadProgress {
        return .{ .context = self, .update_fn = update };
    }

    fn update(context: *anyopaque, file_bytes_done: usize) void {
        const self: *LoadProgress = @ptrCast(@alignCast(context));
        const file_done: u32 = @intCast(file_bytes_done);
        const done = @min(self.total, self.base +| file_done);
        const percent = loadPercent(done, self.total);
        if (percent == self.last_percent) return;
        self.last_percent = percent;
        if (self.session) |session| graphics_menu.preparationProgress(&session, percent);
    }
};

fn loadPercent(done: u32, total: u32) u8 {
    if (total == 0 or done == 0) return 0;
    if (done >= total) return 100;
    const unit = @max(@as(u32, 1), total / 100);
    return @intCast(@min(@as(u32, 99), done / unit));
}

extern fn core_cpu_has_long_mode() callconv(.c) u32;
extern fn core_linux_jump(entry: u32, boot_params: u32) callconv(.c) noreturn;
extern fn bios_drive_info(drive: u32, output: *BiosDriveInfoRaw) callconv(.c) u32;

pub fn runIfRequested(
    fs: fat32.FileSystem,
    reader: random_reader.Reader,
    bulk_reader: random_reader.Reader,
    esp_part_guid_disk: [16]u8,
    graphics_session: ?vbe_probe.Session,
) void {
    const mode = requested(fs, reader) catch |err| {
        fail(err);
        return;
    } orelse return;

    run(fs, reader, bulk_reader, esp_part_guid_disk, graphics_session, mode, .none) catch |err| {
        fail(err);
        return;
    };
}

pub fn offerXpResume(
    fs: fat32.FileSystem,
    reader: random_reader.Reader,
    bulk_reader: random_reader.Reader,
    esp_part_guid_disk: [16]u8,
    graphics_session: ?vbe_probe.Session,
) void {
    const name = [_]u16{ 'x', 'p', '-', 'r', 'e', 's', 'u', 'm', 'e', '.', 'i', 'n', 'i' };
    const path = [_][]const u16{ &p_efi, &p_usos, &name };
    if (!markerExists(fs, reader, &path)) return;
    if (graphics_session) |session| graphics_menu.xpResume(&session);
    console.line("XP RESUME AVAILABLE: ENTER after Text Mode; ESC for USOS menu");
    while (true) {
        const key = console.readKey();
        if (key.scan == 0x01) return;
        if (key.scan != 0x1c) continue;
        if (graphics_session) |session| graphics_menu.preparationStart(&session);
        run(fs, reader, bulk_reader, esp_part_guid_disk, graphics_session, .boot, .xp_resume) catch |err| {
            fail(err);
            if (graphics_session) |session| graphics_menu.backendFailure(&session, "XP RESUME", @errorName(err));
            _ = console.readKey();
        };
        return;
    }
}

pub fn runXpStaging(
    fs: fat32.FileSystem,
    reader: random_reader.Reader,
    bulk_reader: random_reader.Reader,
    esp_part_guid_disk: [16]u8,
    bios_boot_drive: u8,
    graphics_session: ?vbe_probe.Session,
    system_id: []const u8,
    image_name: []const u8,
    unattended_name: ?[]const u8,
) Error!void {
    if (graphics_session) |session| graphics_menu.preparationStart(&session);
    console.print("LEGACY XP STAGING REQUEST image=");
    console.line(image_name);
    var bios_inventory = collectBiosDiskInventory(bios_boot_drive);
    const request = linux_boot_params.XpStagingRequest{
        .image_name = image_name,
        .unattended_name = unattended_name,
        .bios_boot_drive = bios_boot_drive,
        .bios_inventory = bios_inventory.slice(),
    };
    const command: linux_boot_params.CommandRequest = if (std.mem.eql(u8, system_id, "windows-2000"))
        .{ .windows2000_staging = request }
    else if (std.mem.eql(u8, system_id, "windows-xp"))
        .{ .xp_staging = request }
    else
        return error.UnsupportedWindowsSystem;
    try run(fs, reader, bulk_reader, esp_part_guid_disk, graphics_session, .boot, command);
}

pub fn runWindowsIso(fs: fat32.FileSystem, reader: random_reader.Reader, bulk_reader: random_reader.Reader, esp_guid: [16]u8, boot_drive: u8, graphics_session: ?vbe_probe.Session, system_id: []const u8, image_name: []const u8, unattended_name: ?[]const u8) Error!void {
    if (graphics_session) |session| graphics_menu.preparationStart(&session);
    const request = linux_boot_params.XpStagingRequest{
        .image_name = image_name, .unattended_name = unattended_name, .bios_boot_drive = boot_drive, .bios_inventory = "",
    };
    const command: linux_boot_params.CommandRequest = if (std.mem.eql(u8, system_id, "windows-vista"))
        .{ .windows_vista_iso = request }
    else if (std.mem.eql(u8, system_id, "windows-7"))
        .{ .windows7_iso = request }
    else
        return error.UnsupportedWindowsSystem;
    try run(fs, reader, bulk_reader, esp_guid, graphics_session, .boot, command);
}

pub fn runHardware(fs: fat32.FileSystem, reader: random_reader.Reader, bulk: random_reader.Reader, esp_guid: [16]u8, graphics: ?vbe_probe.Session) Error!void {
    if (graphics) |session| graphics_menu.environmentStart(&session, "Hardware & SMART");
    console.line("HARDWARE DIAGNOSTICS: loading service environment");
    try run(fs, reader, bulk, esp_guid, graphics, .boot, .hardware);
}

fn requested(fs: fat32.FileSystem, reader: random_reader.Reader) fat32.Error!?Mode {
    if (markerExists(fs, reader, &boot_marker_path)) return .boot;
    if (markerExists(fs, reader, &probe_marker_path)) return .load_only;
    return null;
}

fn markerExists(fs: fat32.FileSystem, reader: random_reader.Reader, path: []const []const u16) bool {
    _ = fat32.fileInfo(fs, reader, path) catch return false;
    return true;
}

fn run(
    fs: fat32.FileSystem,
    reader: random_reader.Reader,
    bulk_reader: random_reader.Reader,
    esp_part_guid_disk: [16]u8,
    graphics_session: ?vbe_probe.Session,
    mode: Mode,
    request: linux_boot_params.CommandRequest,
) Error!void {
    console.line(if (mode == .boot) "LINUX BOOT BEGIN" else "LINUX LOAD PROBE BEGIN");
    if (core_cpu_has_long_mode() == 0) return error.CpuNoLongMode;

    const kernel_info = try fat32.fileInfo(fs, reader, &kernel_path);
    const initramfs_info = try fat32.fileInfo(fs, reader, &initramfs_path);
    const lang_size: u32 = if (fat32.fileInfo(fs, reader, &lang_cpio_path)) |info| info.size else |_| 0;
    const initramfs_padded: u32 = (initramfs_info.size + 3) & ~@as(u32, 3);
    const initrd_size: u32 = if (lang_size > 0) initramfs_padded + lang_size else initramfs_info.size;

    var setup_header: [linux_boot_header.minimum_header_bytes]u8 = undefined;
    const header_read = try fat32.readFileRange(fs, reader, &kernel_path, 0, &setup_header);
    if (header_read != setup_header.len) return error.ShortHeaderRead;

    const header = try linux_boot_header.parse(&setup_header);
    try linux_boot_header.validateImageSize(header, kernel_info.size);
    try linux_boot_header.validateForUsosMicroLinux(header);

    var map: [e820.max_entries]e820.Entry = undefined;
    const map_count = try e820.probe(&map);
    const memory_map = map[0..map_count];
    e820.dumpEntries(memory_map);
    const layout = try linux_memory.plan(memory_map, header, kernel_info.size, initrd_size);

    const params_range = linux_memory.Range{
        .start = linux_boot_params.boot_params_phys,
        .end = linux_boot_params.boot_params_phys + linux_boot_params.boot_params_bytes,
    };
    if (!linux_memory.rangeIsUsable(memory_map, params_range)) return error.BootParamsMemoryNotUsable;
    const cmdline_range = linux_memory.Range{
        .start = linux_boot_params.cmdline_phys,
        .end = linux_boot_params.cmdline_phys + linux_boot_params.cmdline_capacity,
    };
    if (!linux_memory.rangeIsUsable(memory_map, cmdline_range)) return error.CommandLineMemoryNotUsable;

    printHeader(header, kernel_info.size, initramfs_info.size);
    printLayout(layout);

    const kernel_memory = try writableRange(layout.kernel_protected);
    const initrd_memory = try writableRange(layout.initramfs);
    const initramfs_memory = initrd_memory[0..initramfs_info.size];
    var load_progress = LoadProgress{
        .session = graphics_session,
        .total = @intCast(kernel_memory.len + initramfs_memory.len),
    };
    if (graphics_session) |session| graphics_menu.preparationProgress(&session, 0);

    const kernel_read = if (graphics_session != null)
        try fat32.readFileRangeProgress(fs, bulk_reader, &kernel_path, header.protected_file_offset, kernel_memory, load_progress.sink())
    else
        try fat32.readFileRange(fs, bulk_reader, &kernel_path, header.protected_file_offset, kernel_memory);
    if (kernel_read != kernel_memory.len) return error.ShortKernelRead;

    load_progress.base = @intCast(kernel_memory.len);
    load_progress.last_percent = 255;
    const initramfs_read = if (graphics_session != null)
        try fat32.readFileRangeProgress(fs, bulk_reader, &initramfs_path, 0, initramfs_memory, load_progress.sink())
    else
        try fat32.readFileRange(fs, bulk_reader, &initramfs_path, 0, initramfs_memory);
    if (initramfs_read != initramfs_memory.len) return error.ShortInitramfsRead;
    if (initramfs_memory.len < 4 or initramfs_memory[0] != 0x1F or initramfs_memory[1] != 0x8B) return error.BadInitramfsMagic;
    if (lang_size > 0) {
        @memset(initrd_memory[initramfs_info.size..initramfs_padded], 0);
        const lang_memory = initrd_memory[initramfs_padded..];
        const lang_read = fat32.readFile(fs, bulk_reader, &lang_cpio_path, lang_memory) catch 0;
        // A missing or short language archive only costs the translation.
        if (lang_read != lang_memory.len) @memset(lang_memory, 0);
    }

    console.print("LINUX LOAD kernel_first=0x");
    console.printHex8(kernel_memory[0]);
    console.printHex8(kernel_memory[1]);
    console.printHex8(kernel_memory[2]);
    console.printHex8(kernel_memory[3]);
    console.print(" initramfs_first=0x");
    console.printHex8(initramfs_memory[0]);
    console.printHex8(initramfs_memory[1]);
    console.printHex8(initramfs_memory[2]);
    console.printHex8(initramfs_memory[3]);
    console.line("");

    if (mode == .load_only) {
        console.line("LINUX LOAD PROBE PASS - KERNEL NOT STARTED");
        return;
    }

    const params: *[linux_boot_params.boot_params_bytes]u8 = @ptrFromInt(linux_boot_params.boot_params_phys);
    const cmdline: *[linux_boot_params.cmdline_capacity]u8 = @ptrFromInt(linux_boot_params.cmdline_phys);
    const built = try linux_boot_params.build(
        params,
        cmdline,
        &setup_header,
        layout.initramfs.start,
        layout.initramfs.size(),
        memory_map,
        esp_part_guid_disk,
        graphics_session,
        request,
    );

    console.print("LINUX BOOT_PARAMS addr=0x");
    console.printHex32(linux_boot_params.boot_params_phys);
    console.print(" cmdline=0x");
    console.printHex32(linux_boot_params.cmdline_phys);
    console.print(" e820=");
    console.printU32(@intCast(built.e820_count));
    console.line("");
    console.print("LINUX CMDLINE ");
    console.line(cmdline[0..built.cmdline_len]);

    if (graphics_session) |session| {
        console.print("LINUX HANDOFF VBE 4F03 expected=0x");
        console.printHex32(session.mode_id);
        const current = session.currentMode();
        if (current) |mode_id| {
            console.print(" current=0x");
            console.printHex32(mode_id);
            const matches = mode_id == session.mode_id;
            console.print(" match=");
            console.line(if (matches) "yes" else "NO");
            if (!matches) return error.VesaModeLostBeforeHandoff;
        } else {
            console.line(" current=UNAVAILABLE match=NO");
            return error.VesaModeLostBeforeHandoff;
        }
        console.print("LINUX HANDOFF FRAMEBUFFER fb=0x");
        console.printHex64(session.framebuffer.address);
        console.print(" size=");
        console.printU32(session.framebuffer.width);
        console.put('x');
        console.printU32(session.framebuffer.height);
        console.line("x32");
    } else {
        console.line("LINUX HANDOFF TEXT - NO VESA LFB");
    }

    console.print("LINUX JUMP entry=0x");
    console.printHex32(@intCast(layout.kernel_protected.start));
    console.line(" - NO RETURN");

    core_linux_jump(@intCast(layout.kernel_protected.start), linux_boot_params.boot_params_phys);
}

fn collectBiosDiskInventory(boot_drive: u8) BiosInventory {
    var inventory = BiosInventory{};
    console.line("[LEGACY_XP] BIOS DISK INVENTORY BEGIN scan=0x80..0x8F");
    var drive: u32 = 0x80;
    while (drive <= 0x8F) : (drive += 1) {
        var raw = BiosDriveInfoRaw{
            .sectors_low = 0,
            .sectors_high = 0,
            .bytes_per_sector = 0,
            .cylinders = 0,
            .heads = 0,
            .sectors_per_track = 0,
        };
        const status = bios_drive_info(drive, &raw);
        if (status == 1) continue;
        inventory.detected +|= 1;

        console.print("[LEGACY_XP] BIOS DISK drive=0x");
        console.printHex8(@truncate(drive));
        switch (status) {
            0 => {
                inventory.edd_sized +|= 1;
                const sectors = @as(u64, raw.sectors_low) | (@as(u64, raw.sectors_high) << 32);
                console.print(" edd=yes sectors=0x");
                console.printHex64(sectors);
                console.print(" bps=");
                console.printU32(raw.bytes_per_sector);
                printGeometry(raw);
                appendInventoryRecord(&inventory, @truncate(drive), 0, sectors, raw.bytes_per_sector, raw.cylinders, raw.heads, raw.sectors_per_track);
            },
            2 => {
                console.print(" edd=no size=unknown");
                printGeometry(raw);
                appendInventoryRecord(&inventory, @truncate(drive), 2, 0, 0, raw.cylinders, raw.heads, raw.sectors_per_track);
            },
            else => {
                console.print(" edd=yes parameters=FAIL size=unknown");
                printGeometry(raw);
                appendInventoryRecord(&inventory, @truncate(drive), 3, 0, 0, raw.cylinders, raw.heads, raw.sectors_per_track);
            },
        }
        if (@as(u8, @truncate(drive)) == boot_drive) {
            console.line(" decision=REJECT reason=USOS-boot-drive");
        } else {
            console.line(" decision=ACCEPT reason=non-USOS-BIOS-drive");
        }
    }
    console.print("[LEGACY_XP] BIOS DISK INVENTORY END detected=");
    console.printU32(inventory.detected);
    console.print(" edd_sized=");
    console.printU32(inventory.edd_sized);
    console.print(" boot=0x");
    console.printHex8(boot_drive);
    console.line("");
    return inventory;
}

fn printGeometry(raw: BiosDriveInfoRaw) void {
    console.print(" chs=");
    if (raw.cylinders == 0 or raw.heads == 0 or raw.sectors_per_track == 0) {
        console.print("unavailable");
        return;
    }
    console.printU32(raw.cylinders);
    console.put('/');
    console.printU32(raw.heads);
    console.put('/');
    console.printU32(raw.sectors_per_track);
}

fn appendInventoryRecord(
    inventory: *BiosInventory,
    drive: u8,
    status: u8,
    sectors: u64,
    bytes_per_sector: u16,
    cylinders: u16,
    heads: u16,
    sectors_per_track: u16,
) void {
    if (inventory.len != 0) appendByte(inventory, ',');
    appendHex8(inventory, drive);
    appendByte(inventory, ':');
    appendByte(inventory, hexNibble(status & 0x0f));
    appendByte(inventory, ':');
    appendHex64(inventory, sectors);
    appendByte(inventory, ':');
    appendHex16(inventory, bytes_per_sector);
    appendByte(inventory, ':');
    appendHex16(inventory, cylinders);
    appendByte(inventory, ':');
    appendHex16(inventory, heads);
    appendByte(inventory, ':');
    appendHex16(inventory, sectors_per_track);
}

fn appendByte(inventory: *BiosInventory, byte: u8) void {
    if (inventory.len >= inventory.encoded.len) return;
    inventory.encoded[inventory.len] = byte;
    inventory.len += 1;
}

fn appendHex8(inventory: *BiosInventory, value: u8) void {
    appendByte(inventory, hexNibble(value >> 4));
    appendByte(inventory, hexNibble(value & 0x0f));
}

fn appendHex16(inventory: *BiosInventory, value: u16) void {
    appendHex8(inventory, @truncate(value >> 8));
    appendHex8(inventory, @truncate(value));
}

fn appendHex64(inventory: *BiosInventory, value: u64) void {
    appendHex32(inventory, @truncate(value >> 32));
    appendHex32(inventory, @truncate(value));
}

fn appendHex32(inventory: *BiosInventory, value: u32) void {
    appendByte(inventory, hexNibble(@truncate((value >> 28) & 0x0f)));
    appendByte(inventory, hexNibble(@truncate((value >> 24) & 0x0f)));
    appendByte(inventory, hexNibble(@truncate((value >> 20) & 0x0f)));
    appendByte(inventory, hexNibble(@truncate((value >> 16) & 0x0f)));
    appendByte(inventory, hexNibble(@truncate((value >> 12) & 0x0f)));
    appendByte(inventory, hexNibble(@truncate((value >> 8) & 0x0f)));
    appendByte(inventory, hexNibble(@truncate((value >> 4) & 0x0f)));
    appendByte(inventory, hexNibble(@truncate(value & 0x0f)));
}

fn hexNibble(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn writableRange(range: linux_memory.Range) Error![]u8 {
    if (range.end <= range.start) return error.AddressNotReachable;
    const length_u64 = range.end - range.start;
    if (range.start > std.math.maxInt(usize) or length_u64 > std.math.maxInt(usize)) return error.AddressNotReachable;
    const start: usize = @intCast(range.start);
    const length: usize = @intCast(length_u64);
    const pointer: [*]u8 = @ptrFromInt(start);
    return pointer[0..length];
}

fn printHeader(header: linux_boot_header.Header, kernel_size: u32, initramfs_size: u32) void {
    console.print("LINUX HEADER protocol=0x");
    console.printHex32(header.protocol);
    console.print(" setup=");
    console.printU32(header.setup_sects);
    console.print(" kernel_bytes=");
    console.printU32(kernel_size);
    console.print(" protected_offset=0x");
    console.printHex32(header.protected_file_offset);
    console.print(" initramfs_bytes=");
    console.printU32(initramfs_size);
    console.line("");
}

fn printLayout(layout: linux_memory.Layout) void {
    console.print("LINUX LAYOUT kernel=0x");
    console.printHex64(layout.kernel_protected.start);
    console.print("..0x");
    console.printHex64(layout.kernel_protected.end);
    console.print(" runtime=0x");
    console.printHex64(layout.kernel_runtime.start);
    console.print("..0x");
    console.printHex64(layout.kernel_runtime.end);
    console.print(" initrd=0x");
    console.printHex64(layout.initramfs.start);
    console.print("..0x");
    console.printHex64(layout.initramfs.end);
    console.line("");
}

fn fail(err: anyerror) void {
    console.print("LINUX LOAD PROBE FAIL error=");
    console.print(@errorName(err));
    console.line("");
}
