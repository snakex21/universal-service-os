const std = @import("std");
const storage = @import("storage");
const e820 = @import("e820.zig");
const memory = @import("linux_memory.zig");
const headers = @import("linux_boot_header.zig");
const graphics_menu = @import("graphics_menu.zig");
const vbe = @import("vbe_probe.zig");
const console = @import("console.zig");
const contract = @import("windows_boot_contract.zig");
const fat = storage.fat32;
const Reader = storage.random_reader.Reader;
const kernel_path = [_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("EFI"), std.unicode.utf8ToUtf16LeStringLiteral("USOS"), std.unicode.utf8ToUtf16LeStringLiteral("windows-bios"), std.unicode.utf8ToUtf16LeStringLiteral("wimboot") };
const archive_path = [_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("EFI"), std.unicode.utf8ToUtf16LeStringLiteral("USOS"), std.unicode.utf8ToUtf16LeStringLiteral("windows-bios"), std.unicode.utf8ToUtf16LeStringLiteral("boot.cpio") };
extern fn core_wimboot_jump() callconv(.c) noreturn;
extern fn bios_vbe_text_mode() callconv(.c) u32;
extern const windows_disk_order_start: [512]u8;

pub const Error = fat.Error || headers.ParseError || headers.ImageError || memory.Error || e820.Error || error{
    InvalidWimbootFiles,
    ShortWimbootHeader,
    InvalidWimbootHeader,
    WimbootSetupMemoryUnavailable,
    NotEnoughWindowsPeMemory,
    ShortWimbootPrefix,
    InvalidWimbootEntry,
    WimbootPaddingOccupied,
    ShortWimbootPayload,
    ShortWindowsPeArchive,
    InvalidWindowsPeArchive,
};

pub const Progress = struct {
    session: ?vbe.Session,
    total: usize,
    last: usize = 101,
    pub fn update(ctx: *anyopaque, done: usize) void {
        const self: *Progress = @ptrCast(@alignCast(ctx));
        // Keep this in 32-bit arithmetic: the freestanding BIOS Core has no
        // compiler runtime for 64-bit division. Round thresholds up so 100%
        // is shown only after the complete archive has arrived.
        var percent = @min(@as(usize, 100), done / @max(@as(usize, 1), self.total / 100));
        while (percent > 0 and done < self.total / 100 * percent + (self.total % 100 * percent + 99) / 100) percent -= 1;
        if (percent == self.last) return;
        self.last = percent;
        if (self.session) |session| graphics_menu.windowsSetupProgress(&session, @intCast(percent));
    }
};

pub fn prepare(fs: fat.FileSystem, reader: Reader, bulk: Reader, drive: u8, graphics: ?vbe.Session) Error!void {
    const archive = try fat.fileInfo(fs, reader, &archive_path);
    const initrd = try allocate(fs, reader, bulk, drive, &kernel_path, archive.size);
    if (graphics) |session| graphics_menu.windowsSetupStart(&session);
    var progress = Progress{ .session = graphics, .total = archive.size };
    if (try fat.readFileSequentialProgress(fs, bulk, &archive_path, initrd[0..archive.size], .{ .context = &progress, .update_fn = Progress.update }) != archive.size) return error.ShortWindowsPeArchive;
    if (!std.mem.eql(u8, initrd[0..6], "070701")) return error.InvalidWindowsPeArchive;
    console.line("[WINDOWS_BIOS] WIMBOOT FILES LOADED PASS");
}

pub fn allocate(fs: fat.FileSystem, reader: Reader, bulk: Reader, drive: u8, kernel_components: []const []const u16, archive_size: u32) Error![]u8 {
    const kernel = try fat.fileInfo(fs, reader, kernel_components);
    console.line("[WINDOWS_BIOS] WIMBOOT FILE LOOKUP PASS");
    if (kernel.size != 76064 or archive_size < 512) return error.InvalidWimbootFiles;
    var header_bytes: [headers.minimum_header_bytes]u8 = undefined;
    if (try fat.readFileRange(fs, reader, kernel_components, 0, &header_bytes) != header_bytes.len) return error.ShortWimbootHeader;
    var header = try headers.parse(&header_bytes);
    if (header.protocol != 0x203 or header.protected_file_offset != 2560 or !header.isLoadedHigh()) return error.InvalidWimbootHeader;
    // wimboot 2.03 runs through its real-mode setup stub, which relocates its
    // payload below 1 MiB. Reserve additional low RAM for the Windows loader.
    header.pref_address = 0x100000;
    header.init_size = 0x1000000;
    header.initrd_addr_max = 0x7fffffff;
    var map: [e820.max_entries]e820.Entry = undefined;
    const count = try e820.probe(&map);
    if (!memory.rangeIsUsable(map[0..count], .{ .start = 0x90000, .end = 0x9f000 })) return error.WimbootSetupMemoryUnavailable;
    const layout = try memory.plan(map[0..count], header, kernel.size, archive_size);
    if (layout.initramfs.start < 0x10000000) return error.NotEnoughWindowsPeMemory;
    // Keep setup clear of the active Core stack. The final assembly handoff
    // moves it to 0x90000 only after the last Zig/BIOS-reader call.
    const prefix: [*]u8 = @ptrFromInt(contract.setup_staging);
    const payload: [*]u8 = @ptrFromInt(0x100000);
    const initrd: [*]u8 = @ptrFromInt(@as(usize, @intCast(layout.initramfs.start)));
    if (try fat.readFileRange(fs, bulk, kernel_components, 0, prefix[0..2560]) != 2560) return error.ShortWimbootPrefix;
    const entry = 0x202 + @as(usize, prefix[0x201]);
    if (entry + 5 > 0x400 or prefix[entry] != 0x1e or prefix[entry + 1] != 0x68 or prefix[entry + 4] != 0xcb) return error.InvalidWimbootEntry;
    for (prefix[0x400..0x600]) |byte| if (byte != 0) return error.WimbootPaddingOccupied;
    const continuation = std.mem.readInt(u16, prefix[entry + 2 ..][0..2], .little);
    @memcpy(prefix[0x400..0x600], &windows_disk_order_start);
    prefix[0x5fa] = drive;
    std.mem.writeInt(u16, prefix[0x5fc..0x5fe], continuation, .little);
    std.mem.writeInt(u16, prefix[entry + 2 ..][0..2], 0x400, .little);
    console.line("[WINDOWS_BIOS] WIMBOOT PREFIX PASS");
    const payload_size = kernel.size - 2560;
    if (try fat.readFileRange(fs, bulk, kernel_components, 2560, payload[0..payload_size]) != payload_size) return error.ShortWimbootPayload;
    console.line("[WINDOWS_BIOS] WIMBOOT PAYLOAD PASS");
    std.mem.writeInt(u32, prefix[0x218..0x21c], @intCast(layout.initramfs.start), .little);
    std.mem.writeInt(u32, prefix[0x21c..0x220], archive_size, .little);
    std.mem.writeInt(u32, prefix[0x228..0x22c], contract.command_address, .little);
    const command: [*]u8 = @ptrFromInt(contract.command_address);
    @memcpy(command[0..13], "quiet linear\x00");
    return initrd[0..archive_size];
}

pub fn start() noreturn {
    _ = bios_vbe_text_mode();
    console.line("[WINDOWS_BIOS] WIMBOOT REAL-MODE HANDOFF");
    core_wimboot_jump();
}
