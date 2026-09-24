//! Host tool: renders the boot menu screens into BMP files for review
//! without booting a VM.
//!   usos-ui-preview <out-dir> <width> <height> [lang.bin]
const std = @import("std");
const usos = @import("usos");
const gui = usos.gui;

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const out_dir = args.next() orelse return usage();
    const width = std.fmt.parseInt(u32, args.next() orelse return usage(), 10) catch return usage();
    const height = std.fmt.parseInt(u32, args.next() orelse return usage(), 10) catch return usage();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var blob: ?[]u8 = null;
    defer if (blob) |bytes| init.gpa.free(bytes);
    if (args.next()) |path| blob = try cwd.readFileAlloc(io, path, init.gpa, .limited(256 * 1024));

    const pack = try gui.font.Pack.parse(gui.font_pack);
    const coverage = usos.i18n.Coverage{ .context = @ptrCast(&pack), .has = gui.font.coverageHas };
    const table = usos.i18n.Table.parseOrEnglish(blob, coverage);

    const pixels = try init.gpa.alloc(u32, @as(usize, width) * height);
    defer init.gpa.free(pixels);
    const buffer = gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, width, height, .bgrx8).?;
    const ui = gui.ui.Ui.init(buffer.surface, gui.Theme{}, &pack, &table);
    const header = gui.ui.HeaderInfo{ .firmware = "UEFI", .build = "B260923-124620-62F8A603", .language = languageName(table.languageCode()), .clock = "Wed 23.09.2026 14:32" };
    const hints = [_]gui.ui.Hint{
        .{ .key = "\u{2191}\u{2193}", .label = ui.t(.key_select) },
        .{ .key = "Enter", .label = ui.t(.key_open) },
        .{ .key = "Esc", .label = ui.t(.key_power) },
    };

    const home_items = [_]gui.menu_screens.HomeItem{
        .{ .icon = .windows, .title = "Windows", .description = ui.t(.category_windows_desc) },
        .{ .icon = .terminal, .title = "Linux", .description = ui.t(.category_linux_desc) },
        .{ .icon = .flask, .title = ui.t(.category_beta), .description = ui.t(.category_beta_desc) },
        .{ .icon = .floppy, .title = "DOS", .description = ui.t(.category_dos_desc) },
        .{ .icon = .gear, .title = ui.t(.category_utilities), .description = ui.t(.category_utilities_desc) },
        .{ .icon = .power, .title = ui.t(.category_power), .description = ui.t(.category_power_desc) },
    };
    gui.menu_screens.home(&ui, header, &home_items, 0, 3, &hints);
    try save(io, cwd, init.gpa, out_dir, "01-home", pixels, width, height);

    var count_buffer: [48]u8 = undefined;
    const rows = [_]gui.ui.Row{
        .{ .title = "Windows 11", .detail = ui.format(&count_buffer, .system_image_count, &.{"2"}), .icon = .{ .vector = .windows }, .badge = .{ .text = ui.t(.system_ready), .tone = .success } },
        .{ .title = "Windows 10", .detail = ui.t(.system_no_image), .icon = .{ .vector = .windows }, .badge = .{ .text = ui.t(.system_no_image) }, .enabled = false },
        .{ .title = "Windows 8.1", .detail = ui.t(.system_no_image), .icon = .{ .vector = .windows }, .enabled = false },
        .{ .title = "Windows 7", .detail = ui.format(&count_buffer, .system_image_count, &.{"1"}), .icon = .{ .vector = .windows }, .badge = .{ .text = ui.t(.system_ready), .tone = .success } },
        .{ .title = "Windows Vista", .detail = ui.t(.system_no_image), .icon = .{ .vector = .windows }, .enabled = false },
        .{ .title = "Windows XP", .detail = ui.t(.system_no_image), .icon = .{ .vector = .windows }, .badge = .{ .text = ui.t(.system_requires_bios), .tone = .warning }, .enabled = false },
        .{ .title = "Windows XP UEFI-CSM PAE", .detail = "Images: 1", .icon = .{ .vector = .windows }, .badge = .{ .text = ui.t(.badge_experimental), .tone = .warning } },
        .{ .title = "Windows 2000", .detail = ui.t(.system_no_image), .icon = .{ .vector = .windows }, .enabled = false },
    };
    _ = gui.menu_screens.listScreen(&ui, header, .{ .title = "Windows", .subtitle = ui.t(.systems_subtitle), .rows = &rows, .selected = 0, .hover = 3, .hints = &hints }, 0);
    try save(io, cwd, init.gpa, out_dir, "02-systems", pixels, width, height);

    // UEFI with Secure Boot on: rows that need Secure Boot off or BIOS stay
    // selectable and explain themselves in the help panel.
    const sb_badge = gui.ui.Badge{ .text = ui.t(.summary_secure_boot_badge), .tone = .warning };
    const bios_badge = gui.ui.Badge{ .text = ui.t(.system_requires_bios), .tone = .warning };
    const blocked_rows = [_]gui.ui.Row{
        .{ .title = "Windows 11", .detail = ui.format(&count_buffer, .system_image_count, &.{"2"}), .icon = .{ .vector = .windows }, .badge = .{ .text = ui.t(.system_ready), .tone = .success } },
        .{ .title = "Windows 10", .detail = ui.t(.system_no_image), .icon = .{ .vector = .windows }, .enabled = false },
        .{ .title = "Windows 7", .detail = ui.t(.summary_secure_boot_detail), .icon = .{ .vector = .windows }, .badge = sb_badge, .enabled = false },
        .{ .title = "Windows XP", .detail = ui.t(.summary_secure_boot_detail), .icon = .{ .vector = .windows }, .badge = sb_badge, .enabled = false },
        .{ .title = "Windows 2000", .detail = ui.t(.system_requires_bios_detail), .icon = .{ .vector = .windows }, .badge = bios_badge, .enabled = false },
        .{ .title = "Windows 98 SE", .detail = ui.t(.system_requires_bios_detail), .icon = .{ .vector = .windows }, .badge = bios_badge, .enabled = false },
        .{ .title = "Windows 3.1", .detail = ui.t(.system_requires_bios_detail), .icon = .{ .vector = .windows }, .badge = bios_badge, .enabled = false },
    };
    const bios_help_lines = [_][]const u8{ ui.t(.system_requires_bios_detail), ui.t(.system_requires_bios_hint) };
    _ = gui.menu_screens.listScreen(&ui, header, .{ .title = "Windows", .subtitle = ui.t(.systems_subtitle), .rows = &blocked_rows, .selected = blocked_rows.len - 1, .help = .{ .title = ui.t(.system_requires_bios), .lines = &bios_help_lines }, .hints = &hints }, 0);
    try save(io, cwd, init.gpa, out_dir, "02b-systems-requires-bios", pixels, width, height);
    const sb_help_lines = [_][]const u8{ ui.t(.summary_secure_boot_line1), ui.t(.summary_secure_boot_line2) };
    _ = gui.menu_screens.listScreen(&ui, header, .{ .title = "Windows", .subtitle = ui.t(.systems_subtitle), .rows = &blocked_rows, .selected = 3, .help = .{ .title = ui.t(.summary_secure_boot_badge), .lines = &sb_help_lines }, .hints = &hints }, 0);
    try save(io, cwd, init.gpa, out_dir, "02c-systems-secure-boot-off", pixels, width, height);

    const methods = [_]gui.ui.Row{
        .{ .title = ui.t(.method_auto_iso), .badge = .{ .text = ui.t(.badge_recommended), .tone = .accent } },
        .{ .title = "ISO", .badge = .{ .text = ui.t(.badge_ready), .tone = .success } },
        .{ .title = "WIMBoot", .badge = .{ .text = "WIM" }, .enabled = false },
        .{ .title = ui.t(.method_chainload), .badge = .{ .text = ui.t(.badge_ready), .tone = .success } },
    };
    const help_lines = [_][]const u8{ ui.t(.help_auto_iso_line1), ui.t(.help_auto_iso_line2) };
    _ = gui.menu_screens.listScreen(&ui, header, .{ .title = ui.t(.methods_title), .subtitle = "Win11_24H2_Polish_x64.iso", .rows = &methods, .two_line = false, .help = .{ .title = ui.t(.help_auto_title), .lines = &help_lines, .badge = .{ .text = ui.t(.badge_ready), .tone = .success } }, .hints = &hints }, 0);
    try save(io, cwd, init.gpa, out_dir, "03-methods", pixels, width, height);

    const labels = [_][]const u8{ ui.t(.summary_system), ui.t(.summary_image), ui.t(.summary_method) };
    const values = [_][]const u8{ "Windows 11", "Win11_24H2_Polish_x64.iso", ui.t(.method_auto_iso) };
    _ = gui.menu_screens.summary(&ui, header, .{ .title = ui.t(.summary_title), .subtitle = ui.t(.summary_subtitle), .labels = &labels, .values = &values, .action = ui.t(.action_iso), .hints = &hints });
    try save(io, cwd, init.gpa, out_dir, "04-summary", pixels, width, height);

    gui.preparation_screen.render(&ui, .{ .mode = .progress, .current = 4, .title = "Copying WIM file", .detail = "Measured byte progress, transfer speed and ETA.", .image = "Win11_24H2_Polish_x64.iso", .percent = 44, .bytes_done = 2_300_000_000, .bytes_total = 5_200_000_000, .speed_bps = 96_000_000 }, header);
    try save(io, cwd, init.gpa, out_dir, "05-progress", pixels, width, height);

    // micro-Linux XP hand-off notice (the English literals legacy_xp_staging.sh sends).
    const xp_labels = [_][]const u8{ "Loading the preparation environment", "Detecting disks", "Choosing the target disk", "Preparing workspace", "Copying and verifying files" };
    gui.preparation_screen.render(&ui, .{ .mode = .done, .current = 5, .heading = "Windows XP", .labels = &xp_labels, .title = "Windows XP will now install on its own", .notice = "After the restart, Windows XP Setup runs on its own up to the graphical setup wizard. Until then do not press any keys: the disk has already been chosen here.", .action = "Proceed" }, header);
    try save(io, cwd, init.gpa, out_dir, "05b-xp-notice", pixels, width, height);

    const power_rows = [_]gui.ui.Row{
        .{ .title = ui.t(.power_restart), .icon = .{ .vector = .restart } },
        .{ .title = ui.t(.power_shutdown), .icon = .{ .vector = .shutdown } },
        .{ .title = ui.t(.power_firmware), .icon = .{ .vector = .firmware } },
    };
    _ = gui.menu_screens.listScreen(&ui, header, .{ .title = ui.t(.power_title), .subtitle = ui.t(.power_subtitle), .rows = &power_rows, .two_line = false, .hints = &hints }, 0);
    var sprite = gui.cursor.Sprite{};
    sprite.build(ui.fonts.scale.twice());
    var patch = gui.cursor.Patch{};
    patch.save(buffer.surface, width / 2, height / 2, sprite.width, sprite.height);
    sprite.draw(buffer.surface, width / 2, height / 2, &patch.pixels);
    try save(io, cwd, init.gpa, out_dir, "06-power", pixels, width, height);
    return 0;
}

fn languageName(code: []const u8) []const u8 {
    const names = [_][2][]const u8{ .{ "pl", "Polski" }, .{ "ru", "Русский" }, .{ "el", "Ελληνικά" }, .{ "de", "Deutsch" }, .{ "cs", "Čeština" } };
    for (names) |pair| {
        if (std.mem.eql(u8, pair[0], code)) return pair[1];
    }
    return "English";
}

fn usage() u8 {
    std.debug.print("usage: usos-ui-preview <out-dir> <width> <height> [lang.bin]\n", .{});
    return 2;
}

fn save(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, out_dir: []const u8, name: []const u8, pixels: []const u32, width: u32, height: u32) !void {
    const row_bytes = width * 4;
    const data_len = row_bytes * height;
    const bytes = try gpa.alloc(u8, 54 + data_len);
    defer gpa.free(bytes);
    @memset(bytes[0..54], 0);
    bytes[0] = 'B';
    bytes[1] = 'M';
    std.mem.writeInt(u32, bytes[2..6], @intCast(54 + data_len), .little);
    std.mem.writeInt(u32, bytes[10..14], 54, .little);
    std.mem.writeInt(u32, bytes[14..18], 40, .little);
    std.mem.writeInt(i32, bytes[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, bytes[22..26], -@as(i32, @intCast(height)), .little);
    std.mem.writeInt(u16, bytes[26..28], 1, .little);
    std.mem.writeInt(u16, bytes[28..30], 32, .little);
    std.mem.writeInt(u32, bytes[34..38], data_len, .little);
    for (pixels, 0..) |pixel, index| std.mem.writeInt(u32, bytes[54 + index * 4 ..][0..4], pixel | 0xff000000, .little);
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}.bmp", .{ out_dir, name });
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}
