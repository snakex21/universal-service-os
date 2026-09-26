// Diagnostic records beside the loader.
// record/recordNamed: one bounded record, overwritten on each boot (latest state).
// Session: a per-path ring log (usos-boot-csm.log / usos-boot-uefiseven.log) that
// keeps the last `slots` boots, so a CSM boot never erases UefiSeven evidence.
const std = @import("std");
const uefi = std.os.uefi;
pub fn record(device: uefi.Handle, directory: []const u16, message: []const u8) void {
    recordNamed(device, directory, std.unicode.utf8ToUtf16LeStringLiteral("usos-boot.log"), message);
}
fn openFile(device: uefi.Handle, directory: []const u16, name: []const u16) ?*uefi.protocol.File {
    const bs = uefi.system_table.boot_services orelse return null;
    const fs = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return null) orelse return null;
    const root = fs.openVolume() catch return null;
    defer root.close() catch {};
    var path: [512:0]u16 = undefined;
    if (directory.len + name.len >= path.len) return null;
    @memcpy(path[0..directory.len], directory);
    @memcpy(path[directory.len..][0..name.len], name);
    path[directory.len + name.len] = 0;
    return root.open(path[0 .. directory.len + name.len :0], .read_write_create, .{}) catch null;
}
/// Small text file beside the dispatcher (the no-GOP reset counter).
pub fn readSmall(device: uefi.Handle, directory: []const u16, name: []const u16, buffer: []u8) []const u8 {
    const file = openFile(device, directory, name) orelse return "";
    defer file.close() catch {};
    const got = file.read(buffer) catch 0;
    return buffer[0..got];
}

pub fn writeSmall(device: uefi.Handle, directory: []const u16, name: []const u16, text: []const u8) void {
    const file = openFile(device, directory, name) orelse return;
    defer file.close() catch {};
    var bytes = [_]u8{' '} ** 16;
    @memcpy(bytes[0..@min(text.len, bytes.len)], text[0..@min(text.len, bytes.len)]);
    _ = file.write(&bytes) catch return;
    file.flush() catch {};
}

pub fn recordNamed(device: uefi.Handle, directory: []const u16, name: []const u16, message: []const u8) void {
    const file = openFile(device, directory, name) orelse return;
    defer file.close() catch {};
    var bytes = [_]u8{' '} ** 2048;
    const size = @min(message.len, bytes.len - 2);
    @memcpy(bytes[0..size], message[0..size]);
    bytes[bytes.len - 2] = '\r';
    bytes[bytes.len - 1] = '\n';
    _ = file.write(&bytes) catch return;
    file.flush() catch {};
}

// Ring layout: 64-byte header, then `slots` fixed slots of `slot_bytes`.
// Total size is fixed (64 + 8 * 4096 = 32832 bytes per file).
pub const slots = 8;
pub const slot_bytes = 4096;
pub const header_bytes = 64;
pub const Kind = enum { csm, uefiseven };
const header_prefix = "USOS boot log v1 slots=8 slot=4096 last_boot=";

/// Parses the boot counter from a ring header; 0 for a new/foreign file.
pub fn parseHeader(header: []const u8) u32 {
    if (header.len < header_prefix.len + 8 or !std.mem.startsWith(u8, header, header_prefix)) return 0;
    return std.fmt.parseInt(u32, header[header_prefix.len..][0..8], 10) catch 0;
}
pub fn formatHeader(out: *[header_bytes]u8, boot: u32) void {
    @memset(out, ' ');
    _ = std.fmt.bufPrint(out, header_prefix ++ "{d:0>8}", .{boot % 100_000_000}) catch {};
    out[header_bytes - 2] = '\r';
    out[header_bytes - 1] = '\n';
}
pub fn slotOffset(boot: u32) u64 {
    return header_bytes + @as(u64, (boot -% 1) % slots) * slot_bytes;
}

/// QEMU TCG only (same CPUID gate as windows7_video.prepareEmulatedVga):
/// mirror session lines to the debugcon port 0x402, because the harness's
/// vvfat ESP does not reliably persist rewritten files. Never on hardware.
fn qemuTcg() bool {
    if (@import("builtin").cpu.arch != .x86_64) return false;
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [aout] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [a] "{eax}" (@as(u32, 0x40000000)),
          [sub] "{ecx}" (@as(u32, 0)),
    );
    return b == 0x54474354 and c == 0x43544743 and d == 0x47435447;
}
fn debugcon(bytes: []const u8) void {
    for (bytes) |byte| asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (byte),
          [p] "{dx}" (@as(u16, 0x402)),
    );
}

pub const Session = struct {
    mirror: bool = false,
    device: ?uefi.Handle = null,
    directory: [256]u16 = undefined,
    directory_len: usize = 0,
    name: []const u16 = &.{},
    boot: u32 = 0,
    buffer: [slot_bytes]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    /// Starts a new boot record in the ring for `kind`. Never fails the boot.
    pub fn begin(self: *Session, device: uefi.Handle, directory: []const u16, kind: Kind) void {
        if (directory.len > self.directory.len) return;
        self.device = device;
        @memcpy(self.directory[0..directory.len], directory);
        self.directory_len = directory.len;
        self.name = switch (kind) {
            .csm => std.unicode.utf8ToUtf16LeStringLiteral("usos-boot-csm.log"),
            .uefiseven => std.unicode.utf8ToUtf16LeStringLiteral("usos-boot-uefiseven.log"),
        };
        const file = openFile(device, directory, self.name) orelse {
            self.device = null;
            return;
        };
        defer file.close() catch {};
        var header: [header_bytes]u8 = undefined;
        const got = file.read(&header) catch 0;
        const previous = parseHeader(header[0..got]);
        if (previous == 0) {
            // New or foreign file: lay out every slot so the size is fixed from now on.
            var blank = [_]u8{' '} ** slot_bytes;
            const empty = "(empty slot)";
            @memcpy(blank[0..empty.len], empty);
            blank[slot_bytes - 2] = '\r';
            blank[slot_bytes - 1] = '\n';
            for (0..slots) |i| {
                file.setPosition(header_bytes + i * slot_bytes) catch return;
                _ = file.write(&blank) catch return;
            }
        }
        self.boot = if (previous >= 99_999_999) 1 else previous + 1;
        formatHeader(&header, self.boot);
        file.setPosition(0) catch return;
        _ = file.write(&header) catch return;
        file.flush() catch {};
        self.len = 0;
        self.truncated = false;
        self.mirror = qemuTcg();
        var time_text: [32]u8 = undefined;
        const time: []const u8 = blk: {
            const rt = uefi.system_table.runtime_services;
            const t = (rt.getTime() catch break :blk "time unavailable")[0];
            break :blk std.fmt.bufPrint(&time_text, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ t.year, t.month, t.day, t.hour, t.minute, t.second }) catch "time unavailable";
        };
        self.print("=== USOS Windows 7 dispatcher boot {d} ({s}, firmware clock {s}) ===", .{ self.boot, @tagName(kind), time });
    }
    pub fn line(self: *Session, message: []const u8) void {
        if (self.device == null) return;
        const room = self.buffer.len - 2 - 32; // keep space for CRLF and the truncation mark
        if (self.len + message.len + 2 > room) {
            if (!self.truncated) {
                const mark = "[slot full; later lines dropped]\r\n";
                @memcpy(self.buffer[self.len..][0..mark.len], mark);
                self.len += mark.len;
                self.truncated = true;
                self.flush();
            }
            return;
        }
        if (self.mirror) {
            debugcon(message);
            debugcon("\r\n");
        }
        @memcpy(self.buffer[self.len..][0..message.len], message);
        self.len += message.len;
        self.buffer[self.len] = '\r';
        self.buffer[self.len + 1] = '\n';
        self.len += 2;
        self.flush();
    }
    pub fn print(self: *Session, comptime fmt: []const u8, args: anytype) void {
        var text: [1024]u8 = undefined;
        self.line(std.fmt.bufPrint(&text, fmt, args) catch "(log line too long)");
    }
    fn flush(self: *Session) void {
        const device = self.device orelse return;
        const file = openFile(device, self.directory[0..self.directory_len], self.name) orelse return;
        defer file.close() catch {};
        var out = [_]u8{' '} ** slot_bytes;
        @memcpy(out[0..self.len], self.buffer[0..self.len]);
        out[slot_bytes - 2] = '\r';
        out[slot_bytes - 1] = '\n';
        file.setPosition(slotOffset(self.boot)) catch return;
        _ = file.write(&out) catch return;
        file.flush() catch {};
    }
};
pub var session: Session = .{};

test "ring header round-trips and wraps slots" {
    var header: [header_bytes]u8 = undefined;
    formatHeader(&header, 42);
    try std.testing.expectEqual(@as(u32, 42), parseHeader(&header));
    try std.testing.expectEqual(@as(u32, 0), parseHeader("garbage"));
    try std.testing.expectEqual(@as(u32, 0), parseHeader(""));
    try std.testing.expectEqual(@as(u64, header_bytes), slotOffset(1));
    try std.testing.expectEqual(@as(u64, header_bytes + 7 * slot_bytes), slotOffset(8));
    try std.testing.expectEqual(@as(u64, header_bytes), slotOffset(9));
    try std.testing.expectEqual(@as(u8, '\n'), header[header_bytes - 1]);
}
