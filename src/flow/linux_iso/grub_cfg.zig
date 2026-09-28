//! The first bootable entry of a Linux ISO's GRUB configuration: kernel path,
//! initrd paths and kernel arguments (docs/design/linux-iso-boot.md section 4).
//! Only what USOS needs: `menuentry` blocks, `linux`/`linuxefi`/`$linux_cmd`
//! and `initrd`/`initrdefi`/`$initrd_cmd` lines, `(...)` device prefixes.
//! Entries for memtest (`linux16`) or without an initrd are skipped.
const std = @import("std");

pub const max_initrds = 4;
pub const max_path = 128;
pub const max_args = 1024;

pub const Entry = struct {
    kernel_buf: [max_path]u8 = undefined,
    kernel_len: usize = 0,
    initrd_bufs: [max_initrds][max_path]u8 = undefined,
    initrd_lens: [max_initrds]usize = @splat(0),
    initrd_count: usize = 0,
    args_buf: [max_args]u8 = undefined,
    args_len: usize = 0,

    pub fn kernel(self: *const Entry) []const u8 {
        return self.kernel_buf[0..self.kernel_len];
    }
    pub fn initrd(self: *const Entry, index: usize) []const u8 {
        return self.initrd_bufs[index][0..self.initrd_lens[index]];
    }
    pub fn args(self: *const Entry) []const u8 {
        return self.args_buf[0..self.args_len];
    }
};

/// The first `menuentry` with a Linux kernel and at least one initrd.
pub fn firstEntry(text: []const u8) ?Entry {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_entry = false;
    var depth: usize = 0;
    var entry = Entry{};
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!in_entry) {
            if (startsWord(line, "menuentry")) {
                in_entry = true;
                depth = 1;
                entry = .{};
            }
            continue;
        }
        if (startsWord(line, "menuentry") or startsWord(line, "submenu")) {
            depth += 1;
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            depth -= 1;
            if (depth == 0) {
                if (entry.kernel_len != 0 and entry.initrd_count != 0) return entry;
                in_entry = false;
            }
            continue;
        }
        if (depth != 1) continue;
        var words = Tokens{ .text = line };
        const command = words.next() orelse continue;
        if (isKernelCommand(command) and entry.kernel_len == 0) {
            const path = stripDevice(words.next() orelse continue);
            if (path.len == 0 or path.len > max_path) continue;
            @memcpy(entry.kernel_buf[0..path.len], path);
            entry.kernel_len = path.len;
            const rest = std.mem.trim(u8, words.rest(), " \t");
            const n = @min(rest.len, max_args);
            @memcpy(entry.args_buf[0..n], rest[0..n]);
            entry.args_len = n;
        } else if (isInitrdCommand(command)) {
            while (words.next()) |word| {
                const path = stripDevice(word);
                if (path.len == 0 or path.len > max_path or entry.initrd_count == max_initrds) continue;
                @memcpy(entry.initrd_bufs[entry.initrd_count][0..path.len], path);
                entry.initrd_lens[entry.initrd_count] = path.len;
                entry.initrd_count += 1;
            }
        }
    }
    return null;
}

fn startsWord(line: []const u8, word: []const u8) bool {
    return std.mem.startsWith(u8, line, word) and (line.len == word.len or line[word.len] == ' ' or line[word.len] == '\t');
}

fn isKernelCommand(word: []const u8) bool {
    return std.mem.eql(u8, word, "linux") or std.mem.eql(u8, word, "linuxefi") or
        std.mem.eql(u8, word, "$linux_cmd") or std.mem.eql(u8, word, "${linux_cmd}");
}

fn isInitrdCommand(word: []const u8) bool {
    return std.mem.eql(u8, word, "initrd") or std.mem.eql(u8, word, "initrdefi") or
        std.mem.eql(u8, word, "$initrd_cmd") or std.mem.eql(u8, word, "${initrd_cmd}");
}

/// "($root)/boot/x" -> "boot/x", "/casper/vmlinuz" -> "casper/vmlinuz".
fn stripDevice(path: []const u8) []const u8 {
    var p = path;
    if (p.len != 0 and p[0] == '(') {
        const close = std.mem.indexOfScalar(u8, p, ')') orelse return "";
        p = p[close + 1 ..];
    }
    while (p.len != 0 and p[0] == '/') p = p[1..];
    return p;
}

/// Whitespace-separated words; double quotes keep spaces inside one word.
pub const Tokens = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *Tokens) ?[]const u8 {
        while (self.at < self.text.len and (self.text[self.at] == ' ' or self.text[self.at] == '\t')) self.at += 1;
        if (self.at >= self.text.len) return null;
        const start = self.at;
        var quoted = false;
        while (self.at < self.text.len) : (self.at += 1) {
            const c = self.text[self.at];
            if (c == '"') quoted = !quoted;
            if (!quoted and (c == ' ' or c == '\t')) break;
        }
        return self.text[start..self.at];
    }

    pub fn rest(self: *const Tokens) []const u8 {
        return self.text[self.at..];
    }
};

test "Ubuntu server entry" {
    const cfg =
        \\set timeout=30
        \\menuentry "Try or Install Ubuntu Server" {
        \\  set gfxpayload=keep
        \\  linux  /casper/vmlinuz  ---
        \\  initrd  /casper/initrd
        \\}
    ;
    const e = firstEntry(cfg).?;
    try std.testing.expectEqualStrings("casper/vmlinuz", e.kernel());
    try std.testing.expectEqualStrings("---", e.args());
    try std.testing.expectEqualStrings("casper/initrd", e.initrd(0));
}

test "GParted variables, SystemRescue three initrds, Fedora ($root), memtest skipped" {
    const gparted =
        \\menuentry "GParted Live (Default settings)" --id live-default {
        \\  search --set -f /live/vmlinuz
        \\  $linux_cmd /live/vmlinuz boot=live union=overlay ocs_live_extra_param="" nosplash
        \\  $initrd_cmd /live/initrd.img
        \\}
    ;
    const g = firstEntry(gparted).?;
    try std.testing.expectEqualStrings("live/vmlinuz", g.kernel());
    try std.testing.expectEqualStrings("boot=live union=overlay ocs_live_extra_param=\"\" nosplash", g.args());
    const rescue =
        \\menuentry 'Test memory' {
        \\  linux16 /boot/memtest86+x64.bin
        \\}
        \\menuentry 'Boot SystemRescue using default options' {
        \\  linux /sysresccd/boot/x86_64/vmlinuz archisobasedir=sysresccd $archiso_param iomem=relaxed
        \\  initrd /sysresccd/boot/intel_ucode.img /sysresccd/boot/amd_ucode.img /sysresccd/boot/x86_64/sysresccd.img
        \\}
    ;
    const r = firstEntry(rescue).?;
    try std.testing.expectEqual(@as(usize, 3), r.initrd_count);
    try std.testing.expectEqualStrings("sysresccd/boot/x86_64/sysresccd.img", r.initrd(2));
    const fedora =
        \\search --file --set=root /boot/0xf20784ad
        \\menuentry "Start Fedora-Workstation-Live" --class fedora --class os {
        \\  linux ($root)/boot/x86_64/loader/linux quiet rhgb  root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image
        \\  initrd ($root)/boot/x86_64/loader/initrd
        \\}
    ;
    const f = firstEntry(fedora).?;
    try std.testing.expectEqualStrings("boot/x86_64/loader/linux", f.kernel());
    try std.testing.expectEqualStrings("boot/x86_64/loader/initrd", f.initrd(0));
    try std.testing.expectEqualStrings("quiet rhgb  root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image", f.args());
    try std.testing.expect(firstEntry("menuentry x {\n linux16 /a\n}\n") == null);
}
