//! Strict legacy-network input validation, independent of a target OS.
const std = @import("std");
pub const Mode = enum { on, off };

pub fn address(text: []const u8) ?u32 {
    var parts = std.mem.splitScalar(u8, text, '.');
    var result: u32 = 0;
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) return null;
        for (part) |c| if (!std.ascii.isDigit(c)) return null;
        const value = std.fmt.parseInt(u8, part, 10) catch return null;
        result = (result << 8) | value;
        count += 1;
    }
    if (count != 4 or (result >> 24) == 0 or result >= 0xe0000000 or (result >> 24) == 127) return null;
    return result;
}

pub fn prefix(text: []const u8) ?u5 {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
    const suffix = text[slash + 1 ..];
    if (suffix.len == 0 or suffix.len > 2 or suffix[0] == '0') return null;
    for (suffix) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u8, suffix, 10) catch return null;
    if (n < 1 or n > 30) return null;
    return @intCast(n);
}
pub fn mask(n: u5) u32 {
    const shift: u5 = @intCast(32 - @as(u6, n));
    return @as(u32, 0xffffffff) << shift;
}
pub fn validIp(text: []const u8) bool {
    if (text.len == 0 or std.ascii.eqlIgnoreCase(text, "dhcp")) return true;
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return false;
    const ip = address(text[0..slash]) orelse return false;
    const n = prefix(text) orelse return false;
    const host = ip & ~mask(n);
    return host != 0 and host != ~mask(n);
}
pub fn validGateway(ip: []const u8, gateway: []const u8) bool {
    if (gateway.len == 0) return true;
    const gw = address(gateway) orelse return false;
    const n = prefix(ip) orelse return false;
    const slash = std.mem.indexOfScalar(u8, ip, '/') orelse return false;
    const own = address(ip[0..slash]) orelse return false;
    return (gw & mask(n)) == (own & mask(n)) and gw != own and (gw & ~mask(n)) != 0 and (gw & ~mask(n)) != ~mask(n);
}
pub fn validDns(text: []const u8) bool {
    if (text.len == 0) return true;
    var it = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (it.next()) |ip| {
        _ = address(ip) orelse return false;
        count += 1;
    }
    return count <= 3;
}
pub fn validHome(text: []const u8) bool {
    if (text.len == 0 or std.mem.eql(u8, text, "about:blank")) return true;
    const start: usize = if (std.mem.startsWith(u8, text, "http://")) 7 else if (std.mem.startsWith(u8, text, "https://")) 8 else return false;
    if (text.len <= start or text[start] == '/' or text[start] == '?' or text[start] == '#') return false;
    for (text[start..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~:/?#[!$&()*+,;=%]", c) == null) return false;
    }
    return true;
}
pub fn dotted(ip: u32, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 });
}

test "legacy network values reject ambiguous or executable input" {
    for ([_][]const u8{ "", "dhcp", "192.168.1.20/24", "10.0.0.1/8" }) |v| try std.testing.expect(validIp(v));
    for ([_][]const u8{ "01.2.3.4/24", "127.0.0.1/8", "224.0.0.1/24", "192.168.1.0/24", "192.168.1.255/24", "10.0.0.1/33", "1.2.3.4/24;cmd" }) |v| try std.testing.expect(!validIp(v));
    try std.testing.expect(validGateway("192.168.1.20/24", "192.168.1.1"));
    try std.testing.expect(!validGateway("dhcp", "192.168.1.1"));
    try std.testing.expect(!validGateway("192.168.1.20/24", "10.0.0.1"));
    try std.testing.expect(validDns("1.1.1.1,8.8.8.8"));
    try std.testing.expect(!validDns("1.1.1.1,"));
    try std.testing.expect(validHome("http://68k.news"));
    try std.testing.expect(!validHome("javascript:alert(1)"));
    try std.testing.expect(!validHome("http://example/\"\r\n[Install]"));
}
