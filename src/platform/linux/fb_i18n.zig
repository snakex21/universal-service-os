//! usos-fb-ui language: lang.bin arrives as /etc/usos/lang.bin inside the
//! second initrd (EFI/USOS/lang.cpio, written by the installer); when the
//! ESP is already mounted its EFI/USOS/lang.bin is used as a fallback.
//! Missing or invalid files mean the built-in English.
const std = @import("std");
const usos = @import("usos");
const linux = std.os.linux;

pub const Context = struct {
    blob: [usos.i18n.max_blob_bytes]u8 = undefined,
    pack: ?usos.gui.font.Pack = null,
    table: usos.i18n.Table = usos.i18n.Table.english_only,

    /// Loads the font pack and the language. `self` must not move afterwards.
    pub fn load(self: *Context) void {
        self.pack = usos.gui.font.Pack.parse(usos.gui.font_pack) catch null;
        const pack = if (self.pack) |*value| value else return;
        const coverage = usos.i18n.Coverage{ .context = @ptrCast(pack), .has = usos.gui.font.coverageHas };
        const paths = [_][:0]const u8{ usos.i18n.linux_path, "/mnt/esp/EFI/USOS/lang.bin" };
        for (paths) |path| {
            const bytes = readFile(path, &self.blob) orelse continue;
            self.table = usos.i18n.Table.parse(bytes, coverage) catch continue;
            return;
        }
    }

    pub fn ui(self: *const Context, surface: usos.gui.Surface) usos.gui.ui.Ui {
        return usos.gui.ui.Ui.init(surface, usos.gui.Theme{}, if (self.pack) |*pack| pack else null, &self.table);
    }
};

fn readFile(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    if (@import("builtin").os.tag != .linux) return null;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var used: usize = 0;
    while (used < buffer.len) {
        const result = linux.read(fd, buffer.ptr + used, buffer.len - used);
        const err = linux.errno(result);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return null;
        if (result == 0) return buffer[0..used];
        used += result;
    }
    return null;
}

/// "Śr 23.09.2026 14:32" from the Linux realtime clock.
pub fn clock(ui: *const usos.gui.ui.Ui, buffer: []u8) []const u8 {
    if (@import("builtin").os.tag != .linux) return "";
    var now: linux.timespec = undefined;
    if (linux.clock_gettime(.REALTIME, &now) != 0 or now.sec < 0) return "";
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(now.sec) };
    const year = epoch.getEpochDay().calculateYearDay();
    const date = year.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return usos.gui.ui.clockText(ui, buffer, .{
        .year = year.year,
        .month = @intFromEnum(date.month),
        .day = date.day_index + 1,
        .hour = time.getHoursIntoDay(),
        .minute = time.getMinutesIntoHour(),
    });
}

pub fn header(ui: *const usos.gui.ui.Ui, clock_buffer: []u8) usos.gui.ui.HeaderInfo {
    return .{ .build = usos.build_info.id, .language = ui.t(.language_name), .clock = clock(ui, clock_buffer) };
}
