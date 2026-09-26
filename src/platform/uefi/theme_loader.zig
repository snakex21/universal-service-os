//! Menu theme for the UEFI menu: `theme=` in usos-settings.ini names a
//! built-in theme (src/gui/theme_presets.zig) or a user theme: first
//! \EFI\USOS\themes\<name>.ini on the ESP (written by the theme editor,
//! read by the Legacy BIOS Core too), then the folder
//! DATA\Themes\<name>\theme.ini (src/gui/theme_file.zig). A missing,
//! unreadable, malformed or unreadable-looking user theme gives the
//! default theme and a line on the serial port; the menu always starts.
//!
//! \UI\theme.css (the installer's palette file) still overrides the
//! default theme, as before, but never a theme the user picked.
//!
//! The splash is drawn before DATA is opened, so it uses the built-in
//! part of the choice (`splashTheme`); a user theme applies from the
//! first menu frame.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const data_volume = @import("data_volume.zig");
const file_read = @import("file_read.zig");
const serial = @import("serial.zig");

const gui = usos.gui;
const Theme = gui.Theme;
const presets = gui.theme_presets;
const theme_file = gui.theme_file;
const ntfs = usos.storage.ntfs;

const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const max_user_themes = 16;
pub const Name = struct {
    buffer: [presets.max_name_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Name) []const u8 {
        return self.buffer[0..self.len];
    }
};

var css_buffer: [2048]u8 = undefined;
var file_buffer: [theme_file.max_bytes + 1]u8 = undefined;
var file: ntfs.File = .{};
var esp_root: ?*uefi.protocol.File = null;

/// User themes of the theme editor on the ESP: <name>.ini.
pub const esp_directory = "\\EFI\\USOS\\themes";

/// Where a user theme was found.
pub const Source = enum { esp, data };

/// Theme for the splash: the chosen built-in one, else the default.
pub fn splashTheme(settings: []const u8) Theme {
    return presets.fromSettings(settings);
}

/// The theme chosen in `settings` (see the file comment).
pub fn load(root: *uefi.protocol.File, settings: []const u8) Theme {
    return forName(root, presets.settingValue(settings));
}

pub fn forName(root: *uefi.protocol.File, name: []const u8) Theme {
    esp_root = root;
    if (name.len == 0 or presets.index(name) == 0) return defaultTheme(root);
    if (presets.find(name)) |theme| return theme;
    const outcome = readUser(name);
    if (outcome.problem) |problem| {
        say3("[THEME] user theme ", name, " not used: ");
        serial.writeAscii(problem);
        if (outcome.line != 0) {
            var buffer: [24]u8 = undefined;
            serial.writeAscii(std.fmt.bufPrint(&buffer, " (line {d})", .{outcome.line}) catch "");
        }
        serial.writeAscii("; default theme\n");
        return defaultTheme(root);
    }
    say3("[THEME] user theme ", name, " applied\n");
    return outcome.theme;
}

fn defaultTheme(root: *uefi.protocol.File) Theme {
    if (file_read.into(root, "\\UI\\theme.css", &css_buffer)) |css| return Theme.parse(css);
    return .{};
}

fn say3(a: []const u8, b: []const u8, c: []const u8) void {
    serial.writeAscii(a);
    serial.writeAscii(b);
    serial.writeAscii(c);
}

/// Reads and validates the user theme `name` (ESP first, then DATA).
pub fn readUser(name: []const u8) theme_file.Outcome {
    if (!presets.nameUsable(name)) return rejected("name is not A-Z, 0-9, - or _");
    if (readEsp(name)) |text| {
        if (text.len > theme_file.max_bytes) return rejected("file too large");
        return theme_file.resolve(text);
    }
    return readData(name);
}

/// The text of the user theme file `name` (ESP first), for the editor.
pub fn readUserText(name: []const u8) ?[]const u8 {
    if (!presets.nameUsable(name)) return null;
    if (readEsp(name)) |text| return text;
    if (readData(name).problem != null) return null;
    return file_buffer[0..last_data_len];
}

pub fn sourceOf(name: []const u8) ?Source {
    if (!presets.nameUsable(name)) return null;
    if (readEsp(name) != null) return .esp;
    if (readData(name).problem == null) return .data;
    return null;
}

pub fn setEspRoot(root: *uefi.protocol.File) void {
    esp_root = root;
}

fn readEsp(name: []const u8) ?[]const u8 {
    const root = esp_root orelse return null;
    var path: [80]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path, "{s}\\{s}.ini", .{ esp_directory, name }) catch return null;
    return file_read.into(root, file_path, &file_buffer);
}

var last_data_len: usize = 0;

/// Reads and validates DATA\Themes\<name>\theme.ini.
fn readData(name: []const u8) theme_file.Outcome {
    const catalog = uefi.pool_allocator.create(data_volume.Catalog) catch return rejected("out of memory");
    defer uefi.pool_allocator.destroy(catalog);
    catalog.* = data_volume.openCatalog() catch return rejected("DATA partition not readable");
    var name16: [presets.max_name_len]u16 = undefined;
    for (name, 0..) |c, i| name16[i] = c;
    const path = [_][]const u16{ wide(theme_file.folder), name16[0..name.len], wide(theme_file.file_name) };
    ntfs.openFile(catalog.fs, catalog.reader(), &path, &file) catch return rejected("theme.ini not found");
    const size = file.size();
    if (size > theme_file.max_bytes) return rejected("file too large");
    const n: usize = @intCast(size);
    file.readAt(catalog.fs, catalog.reader(), 0, file_buffer[0..n]) catch return rejected("theme.ini not readable");
    last_data_len = n;
    return theme_file.resolve(file_buffer[0..n]);
}

fn rejected(problem: []const u8) theme_file.Outcome {
    return .{ .theme = .{}, .problem = problem };
}

/// User theme names: <name>.ini on the ESP and folder names under
/// DATA\Themes that can be theme names (usable names, each once, sorted,
/// at most `names.len`).
pub fn listUser(names: []Name) usize {
    var count: usize = 0;
    if (esp_root) |root| {
        var files: [max_user_themes]usos.catalog.FixedText = undefined;
        const found = @import("directory_scan.zig").listFilesWithExtension(root, esp_directory, ".ini", files[0..@min(files.len, names.len)]);
        for (files[0..found]) |*entry| {
            const full = entry.slice();
            const stem = full[0 .. full.len - 4];
            if (stem.len > presets.max_name_len or !presets.nameUsable(stem) or presets.index(stem) != null) continue;
            var name = Name{};
            @memcpy(name.buffer[0..stem.len], stem);
            name.len = stem.len;
            names[count] = name;
            count += 1;
        }
    }
    count = listData(names, count);
    // Stable order independent of the directory order.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0 and std.ascii.lessThanIgnoreCase(names[j].slice(), names[j - 1].slice())) : (j -= 1) {
            std.mem.swap(Name, &names[j], &names[j - 1]);
        }
    }
    return count;
}

fn listData(names: []Name, start: usize) usize {
    const catalog = uefi.pool_allocator.create(data_volume.Catalog) catch return start;
    defer uefi.pool_allocator.destroy(catalog);
    catalog.* = data_volume.openCatalog() catch return start;
    const path = [_][]const u16{wide(theme_file.folder)};
    var count: usize = start;
    var skip: usize = 0;
    while (count < names.len) {
        var items: [8]ntfs.DirectoryItem = undefined;
        const page = ntfs.listDirectoryPage(catalog.fs, catalog.reader(), &path, skip, &items) catch break;
        for (items[0..page.count]) |item| {
            if (!item.isDirectory() or item.name_len > presets.max_name_len or count == names.len) continue;
            var name = Name{};
            name.len = item.copyNameAscii(&name.buffer);
            if (!presets.nameUsable(name.slice()) or presets.index(name.slice()) != null) continue;
            // An ESP theme of the same name wins (listed once).
            const duplicate = for (names[0..start]) |*other| {
                if (std.ascii.eqlIgnoreCase(other.slice(), name.slice())) break true;
            } else false;
            if (duplicate) continue;
            names[count] = name;
            count += 1;
        }
        if (!page.has_more or page.count == 0) break;
        skip += page.count;
    }
    return count;
}
