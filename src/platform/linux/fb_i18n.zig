//! usos-fb-ui language: lang.bin arrives as /etc/usos/lang.bin inside the
//! second initrd (EFI/USOS/lang.cpio, written by the installer); when the
//! ESP is already mounted its EFI/USOS/lang.bin is used as a fallback.
//! Missing or invalid files mean the built-in English.
//!
//! The theme is the one the UEFI menu or the Legacy BIOS Core showed:
//! usos.theme= on the kernel command line (src/gui/theme_cmdline.zig).
//! Without it (loaders from before it), `theme=` of the mounted ESP's
//! usos-settings.ini (or its /run/usos-theme copy) names a built-in theme
//! or EFI/USOS/themes/<name>.ini;
//! anything invalid or unreadable-looking means the default theme.
const std = @import("std");
const usos = @import("usos");
const linux = std.os.linux;

pub const Context = struct {
    blob: [usos.i18n.max_blob_bytes]u8 = undefined,
    pack: ?usos.gui.font.Pack = null,
    table: usos.i18n.Table = usos.i18n.Table.english_only,
    theme: usos.gui.Theme = .{},

    /// Loads the font pack and the language. `self` must not move afterwards.
    pub fn load(self: *Context) void {
        self.theme = activeTheme();
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
        return usos.gui.ui.Ui.init(surface, self.theme, if (self.pack) |*pack| pack else null, &self.table);
    }
};

/// The theme of this boot (see the file comment).
pub fn activeTheme() usos.gui.Theme {
    var buffer: [usos.gui.theme_file.max_bytes + 1]u8 = undefined;
    if (readFile("/proc/cmdline", &buffer)) |cmdline| {
        if (usos.gui.theme_cmdline.valueOf(cmdline) != null) return usos.gui.theme_cmdline.fromCmdline(cmdline);
    }
    return espTheme(&buffer) orelse .{};
}

/// /run/usos-theme: the copy tools/micro_linux_init.sh makes when it mounts
/// the ESP, so the theme stays after the ESP is unmounted.
fn espTheme(buffer: []u8) ?usos.gui.Theme {
    for ([_][]const u8{ "/run/usos-theme", "/mnt/esp/EFI/USOS" }) |directory| {
        if (themeIn(directory, buffer)) |theme| return theme;
    }
    return null;
}

fn themeIn(directory: []const u8, buffer: []u8) ?usos.gui.Theme {
    const presets = usos.gui.theme_presets;
    var path: [96:0]u8 = undefined;
    const settings = readFile(std.fmt.bufPrintZ(&path, "{s}/usos-settings.ini", .{directory}) catch return null, buffer) orelse return null;
    const name = presets.settingValue(settings);
    if (presets.find(name)) |theme| return theme;
    if (!presets.nameUsable(name)) return null;
    const text = readFile(std.fmt.bufPrintZ(&path, "{s}/themes/{s}.ini", .{ directory, name }) catch return null, buffer) orelse return null;
    return usos.gui.theme_file.resolveTheme(text);
}

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
    return .{ .build = usos.build_info.id, .version = usos.build_info.version, .language = ui.t(.language_name), .clock = clock(ui, clock_buffer) };
}
