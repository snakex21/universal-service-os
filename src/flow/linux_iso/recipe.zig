//! How USOS boots a Linux ISO: which kernel and initrds to take from it and
//! which kernel arguments to pass (docs/design/linux-iso-boot.md section 4).
//! Shared by the UEFI menu and the BIOS Core; no allocator.
//!
//! The arguments start from the ISO's own first GRUB entry; the family,
//! detected by the ISO's structure, adds the medium hint (`live-media=`,
//! `archisolabel=`) and drops ISO-scan words that need a file system USOS
//! does not give the distro. `rdinit=/usos/init` is always first.
const std = @import("std");
const grub_cfg = @import("grub_cfg.zig");

pub const Family = enum {
    /// Ubuntu, Linux Mint (casper initramfs).
    casper,
    /// Debian live, GParted Live, Clonezilla (live-boot).
    live_boot,
    /// Debian netinst / DVD (debian-installer).
    debian_installer,
    /// Fedora Workstation Live (dracut dmsquash-live, root=live:CDLABEL=).
    dracut_live,
    /// Fedora netinst / Server DVD (anaconda: inst.stage2=).
    anaconda,
    /// SystemRescue, Arch (archiso).
    archiso,
    /// A GRUB entry USOS has no rule for: unverified.
    unknown,

    pub fn verified(self: Family) bool {
        return self != .unknown;
    }
};

/// Answer file the distro's installer can take (section 7 of the design).
pub const AnswerFormat = enum { none, autoinstall, preseed, kickstart };

pub const device_hint = "live-media=/dev/usos-iso";
pub const rdinit = "rdinit=/usos/init";

pub const Recipe = struct {
    family: Family = .unknown,
    answer: AnswerFormat = .none,
    /// The ISO has a Microsoft-signed-shim layout (\EFI\BOOT\BOOTX64.EFI and
    /// grubx64.efi): the Secure Boot relay can use it.
    shim_layout: bool = false,
    entry: grub_cfg.Entry = .{},
    label_buf: [32]u8 = undefined,
    label_len: usize = 0,
    cmdline_buf: [1536]u8 = undefined,
    cmdline_len: usize = 0,

    pub fn kernel(self: *const Recipe) []const u8 {
        return self.entry.kernel();
    }
    pub fn initrdCount(self: *const Recipe) usize {
        return self.entry.initrd_count;
    }
    pub fn initrd(self: *const Recipe, index: usize) []const u8 {
        return self.entry.initrd(index);
    }
    pub fn label(self: *const Recipe) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    pub fn cmdline(self: *const Recipe) []const u8 {
        return self.cmdline_buf[0..self.cmdline_len];
    }
};

pub const Error = error{ NoLinuxEntry, CommandLineTooLong };

/// GRUB configurations tried in order (SystemRescue keeps its entries in
/// grubsrcd.cfg; Fedora 44 in grub2/).
pub const grub_paths = [_][]const u8{
    "boot/grub/grub.cfg",
    "boot/grub2/grub.cfg",
    "EFI/BOOT/grub.cfg",
    "boot/grub/grubsrcd.cfg",
};

/// `source` must provide:
///   exists(path) bool
///   read(path, buffer) ?[]const u8   (whole small file, null if missing/too big)
///   volumeLabel() []const u8         (ISO9660 primary volume id, trimmed)
/// `text_buf` holds one grub.cfg at a time (64 KiB is plenty). It is the
/// caller's: not on the stack (UEFI stacks are small and USOS runs below
/// shim's frames under Secure Boot) and not static (the BIOS Core has no BSS).
pub fn plan(source: anytype, out: *Recipe, text_buf: []u8) Error!void {
    // Field by field: `out.* = .{}` is a 3 KiB constant (the undefined
    // buffers included) in the size-limited Legacy BIOS Core.
    out.family = .unknown;
    out.answer = .none;
    out.shim_layout = false;
    out.entry.kernel_len = 0;
    out.entry.initrd_lens = @splat(0);
    out.entry.initrd_count = 0;
    out.entry.args_len = 0;
    out.label_len = 0;
    out.cmdline_len = 0;
    const volume = source.volumeLabel();
    out.label_len = @min(volume.len, out.label_buf.len);
    @memcpy(out.label_buf[0..out.label_len], volume[0..out.label_len]);

    var found = false;
    for (grub_paths) |path| {
        const text = source.read(path, text_buf) orelse continue;
        if (grub_cfg.firstEntry(text)) |entry| {
            out.entry = entry;
            found = true;
            break;
        }
    }
    if (!found) return error.NoLinuxEntry;
    out.family = detect(source, out.entry.args());
    out.answer = switch (out.family) {
        .casper => if (isUbuntu(source)) .autoinstall else .none,
        .debian_installer => .preseed,
        .anaconda => .kickstart,
        else => .none,
    };
    out.shim_layout = source.exists("EFI/BOOT/BOOTX64.EFI") and source.exists("EFI/BOOT/grubx64.efi");
    try buildCmdline(out);
}

fn detect(source: anytype, args: []const u8) Family {
    if (source.exists("casper") and hasWord(args, "iso-scan/filename=") or source.exists(".disk/casper-uuid-generic") or source.exists("casper/vmlinuz")) return .casper;
    if (std.mem.indexOf(u8, args, "archisobasedir=") != null) return .archiso;
    if (source.exists("install.amd/vmlinuz")) return .debian_installer;
    if (std.mem.indexOf(u8, args, "inst.stage2=") != null or source.exists("images/install.img")) return .anaconda;
    if (std.mem.indexOf(u8, args, "root=live:") != null or hasWord(args, "rd.live.image")) return .dracut_live;
    if (hasWord(args, "boot=live") or source.exists("live/filesystem.squashfs")) return .live_boot;
    return .unknown;
}

fn isUbuntu(source: anytype) bool {
    var buffer: [256]u8 = undefined;
    const info = source.read(".disk/info", &buffer) orelse return false;
    return std.mem.startsWith(u8, info, "Ubuntu");
}

fn hasWord(args: []const u8, prefix: []const u8) bool {
    var words = grub_cfg.Tokens{ .text = args };
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, prefix)) return true;
    }
    return false;
}

/// Words USOS never passes: unresolved GRUB variables and ISO-scan options
/// that need the distro to mount the partition holding the ISO.
fn dropWord(word: []const u8) bool {
    if (std.mem.indexOfScalar(u8, word, '$') != null) return true;
    for ([_][]const u8{ "iso-scan/filename=", "findiso=", "fromiso=", "img_dev=", "img_loop=", "live-media=", "rdinit=" }) |prefix| {
        if (std.mem.startsWith(u8, word, prefix)) return true;
    }
    return false;
}

fn buildCmdline(out: *Recipe) Error!void {
    var w = Builder{ .out = &out.cmdline_buf };
    try w.word(rdinit);
    var words = grub_cfg.Tokens{ .text = out.entry.args() };
    var hint_done = false;
    const hint: ?[]const u8 = switch (out.family) {
        .casper, .live_boot, .unknown => device_hint,
        else => null,
    };
    var label_buf: [64]u8 = undefined;
    const archiso_label: ?[]const u8 = if (out.family == .archiso and !hasWord(out.entry.args(), "archisolabel="))
        std.fmt.bufPrint(&label_buf, "archisolabel={s}", .{out.label()}) catch return error.CommandLineTooLong
    else
        null;
    while (words.next()) |word| {
        // "---" / "--": everything after goes to the installed system; the
        // USOS words belong before it.
        if (std.mem.eql(u8, word, "---") or std.mem.eql(u8, word, "--")) {
            if (!hint_done) {
                if (hint) |h| try w.word(h);
                if (archiso_label) |l| try w.word(l);
                hint_done = true;
            }
        }
        if (dropWord(word)) continue;
        try w.word(word);
    }
    if (!hint_done) {
        if (hint) |h| try w.word(h);
        if (archiso_label) |l| try w.word(l);
    }
    out.cmdline_len = w.len;
}

const Builder = struct {
    out: []u8,
    len: usize = 0,

    fn word(self: *Builder, text: []const u8) Error!void {
        const need = text.len + @intFromBool(self.len != 0);
        if (self.len + need > self.out.len) return error.CommandLineTooLong;
        if (self.len != 0) {
            self.out[self.len] = ' ';
            self.len += 1;
        }
        @memcpy(self.out[self.len..][0..text.len], text);
        self.len += text.len;
    }
};

// ---------------------------------------------------------------- tests

const FakeIso = struct {
    label: []const u8,
    files: []const [2][]const u8,

    pub fn volumeLabel(self: *const FakeIso) []const u8 {
        return self.label;
    }
    pub fn exists(self: *const FakeIso, path: []const u8) bool {
        for (self.files) |f| {
            if (std.ascii.eqlIgnoreCase(f[0], path) or (std.mem.startsWith(u8, f[0], path) and f[0].len > path.len and f[0][path.len] == '/')) return true;
        }
        return false;
    }
    pub fn read(self: *const FakeIso, path: []const u8, buffer: []u8) ?[]const u8 {
        for (self.files) |f| {
            if (std.ascii.eqlIgnoreCase(f[0], path)) {
                if (f[1].len > buffer.len) return null;
                @memcpy(buffer[0..f[1].len], f[1]);
                return buffer[0..f[1].len];
            }
        }
        return null;
    }
};

fn expectPlan(iso: FakeIso, family: Family, answer: AnswerFormat, cmdline: []const u8) !void {
    var r: Recipe = undefined;
    var text: [4096]u8 = undefined;
    try plan(&iso, &r, &text);
    try std.testing.expectEqual(family, r.family);
    try std.testing.expectEqual(answer, r.answer);
    try std.testing.expectEqualStrings(cmdline, r.cmdline());
}

test "casper: Ubuntu server and Mint" {
    try expectPlan(.{ .label = "Ubuntu-Server 24.04.5 LTS amd64", .files = &.{
        .{ "boot/grub/grub.cfg", "menuentry \"Try\" {\n linux /casper/vmlinuz  ---\n initrd /casper/initrd\n}\n" },
        .{ "casper/vmlinuz", "" },
        .{ ".disk/info", "Ubuntu-Server 24.04.5 LTS \"Noble Numbat\" - Release amd64" },
        .{ "EFI/BOOT/BOOTX64.EFI", "" },
        .{ "EFI/BOOT/grubx64.efi", "" },
    } }, .casper, .autoinstall, "rdinit=/usos/init live-media=/dev/usos-iso ---");
    try expectPlan(.{ .label = "Linux Mint 22.3 Xfce 64-bit", .files = &.{
        .{ "boot/grub/grub.cfg", "menuentry \"Start\" {\n linux /casper/vmlinuz  boot=casper uuid=6e72 username=mint hostname=mint iso-scan/filename=${iso_path} quiet splash --\n initrd /casper/initrd.lz\n}\n" },
        .{ "casper/vmlinuz", "" },
        .{ ".disk/info", "Linux Mint 22.3 \"Zena\" - Release amd64" },
    } }, .casper, .none, "rdinit=/usos/init boot=casper uuid=6e72 username=mint hostname=mint quiet splash live-media=/dev/usos-iso --");
}

test "live-boot, debian-installer, dracut, archiso, unknown" {
    try expectPlan(.{ .label = "d-live 13.7.0 st amd64", .files = &.{
        .{ "boot/grub/grub.cfg", "source /boot/grub/config.cfg\nmenuentry \"Live\" {\n linux /live/vmlinuz-6.12.107+deb13-amd64 boot=live components quiet splash findiso=${iso_path}\n initrd /live/initrd.img-6.12.107+deb13-amd64\n}\n" },
        .{ "live/filesystem.squashfs", "" },
    } }, .live_boot, .none, "rdinit=/usos/init boot=live components quiet splash live-media=/dev/usos-iso");
    try expectPlan(.{ .label = "Debian 13.7.0 amd64 n", .files = &.{
        .{ "boot/grub/grub.cfg", "menuentry --hotkey=g 'Graphical install' {\n linux /install.amd/vmlinuz vga=788 --- quiet\n initrd /install.amd/gtk/initrd.gz\n}\n" },
        .{ "install.amd/vmlinuz", "" },
    } }, .debian_installer, .preseed, "rdinit=/usos/init vga=788 --- quiet");
    try expectPlan(.{ .label = "Fedora-WS-Live-44", .files = &.{
        .{ "boot/grub2/grub.cfg", "menuentry \"Start\" {\n linux ($root)/boot/x86_64/loader/linux quiet rhgb  root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image\n initrd ($root)/boot/x86_64/loader/initrd\n}\n" },
    } }, .dracut_live, .none, "rdinit=/usos/init quiet rhgb root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image");
    try expectPlan(.{ .label = "RESCUE1302", .files = &.{
        .{ "boot/grub/grubsrcd.cfg", "menuentry 'Boot' {\n linux /sysresccd/boot/x86_64/vmlinuz archisobasedir=sysresccd $archiso_param iomem=relaxed\n initrd /a.img /b.img /sysresccd/boot/x86_64/sysresccd.img\n}\n" },
    } }, .archiso, .none, "rdinit=/usos/init archisobasedir=sysresccd iomem=relaxed archisolabel=RESCUE1302");
    try expectPlan(.{ .label = "X", .files = &.{
        .{ "boot/grub/grub.cfg", "menuentry 'x' {\n linux /k root=/dev/sr0\n initrd /i\n}\n" },
    } }, .unknown, .none, "rdinit=/usos/init root=/dev/sr0 live-media=/dev/usos-iso");
    var r: Recipe = undefined;
    var text: [64]u8 = undefined;
    try std.testing.expectError(error.NoLinuxEntry, plan(&FakeIso{ .label = "", .files = &.{} }, &r, &text));
}
