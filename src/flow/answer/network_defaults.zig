//! Legacy LAN policy. Setup schemas remain separate for 9x, NT4 and NT5.
const std = @import("std");
const Profile = @import("profile.zig").Profile;
const values = @import("network_values.zig");
pub const internet = "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
pub const wizard = "Software\\Microsoft\\Internet Connection Wizard";
pub const main = "Software\\Microsoft\\Internet Explorer\\Main";

pub fn home(p: *const Profile) []const u8 {
    return if (p.home_page.len == 0) "about:blank" else p.home_page.slice();
}
pub fn ip(p: *const Profile) []const u8 {
    return if (p.ip.len == 0) "dhcp" else p.ip.slice();
}

pub fn metadata(p: *const Profile, me: bool, w: *std.Io.Writer) !void {
    if (p.network == .off) return;
    try w.print(";USOS-NETWORK=on\r\n;USOS-IP={s}\r\n;USOS-GATEWAY={s}\r\n;USOS-DNS={s}\r\n;USOS-HOME={s}\r\n;USOS-DIALUP={s}\r\n", .{
        ip(p), p.gateway.slice(), p.dns.slice(), home(p), if (me) "off" else @tagName(p.dialup),
    });
}

pub fn msbatch(p: *const Profile, computer: []const u8, me: bool, w: *std.Io.Writer) !void {
    if (p.network == .off) {
        try w.writeAll("Clients=\r\nProtocols=\r\nServices=\r\n");
        return;
    }
    try w.writeAll("PrimaryLogon=Windows\r\nClients=VREDIR\r\nProtocols=MSTCP\r\nServices=\r\n");
    try w.writeAll("\r\n[VREDIR]\r\nValidatedLogon=0\r\n\r\n[MSTCP]\r\n");
    if (values.prefix(ip(p))) |n| {
        const slash = std.mem.indexOfScalar(u8, ip(p), '/').?;
        var buf: [15]u8 = undefined;
        try w.print("DHCP=0\r\nIPAddress={s}\r\nIPMask={s}\r\n", .{ ip(p)[0..slash], try values.dotted(values.mask(n), &buf) });
        if (p.gateway.len > 0) try w.print("Gateways={s}\r\n", .{p.gateway.slice()});
    } else try w.writeAll("DHCP=1\r\n");
    // Enable the resolver before the first lease; omit servers to use DHCP.
    const enable_dns = values.prefix(ip(p)) == null or p.dns.len > 0;
    try w.print("DNS={s}\r\n", .{if (enable_dns) "1" else "0"});
    if (enable_dns) try w.print("Hostname={s}\r\n", .{computer});
    if (p.dns.len > 0) try w.print("DNSServers={s}\r\n", .{p.dns.slice()});
    try w.print("\r\n[OptionalComponents]\r\n\"Dial-Up Networking\"={d}\r\n\"Dial-Up Server\"=0\r\n\"Direct Cable Connection\"=0\r\n", .{@as(u8, if (!me and p.dialup == .on) 1 else 0)});
    try metadata(p, me, w);
}

pub fn msbatchRegistry(p: *const Profile, w: *std.Io.Writer) !void {
    try w.writeAll("\r\n[USOS.Lan]\r\n");
    for ([_][]const u8{ "EnableAutodial", "ProxyEnable", "GlobalUserOffline" }) |name|
        try w.print("HKCU,\"{s}\",{s},0x00010001,0\r\n", .{ internet, name });
    try w.print("HKCU,\"{s}\",NoNetAutodial,0x00010001,1\r\nHKLM,\"{s}\",EnableAutodial,0x00010001,0\r\n", .{ internet, internet });
    try w.print("HKCU,\"{s}\",Completed,1,01,00,00,00\r\nHKCU,\"{s}\",\"Start Page\",,\"about:blank\"\r\n", .{ wizard, main });
    try w.print("HKCU,\"{s}\",\"First Home Page\",,\"about:blank\"\r\n", .{main});
    for ([_][]const u8{ "RunOnceHasShown", "RunOnceComplete" }) |name|
        try w.print("HKCU,\"{s}\",{s},0x00010001,1\r\n", .{ main, name });
    const winlogon = "Software\\Microsoft\\Windows\\CurrentVersion\\Winlogon";
    try w.print("HKLM,\"{s}\",AutoAdminLogon,,\"1\"\r\nHKLM,\"{s}\",DefaultUserName,,\"{s}\"\r\nHKLM,\"{s}\",DefaultPassword,,\"\"\r\n", .{ winlogon, winlogon, if (p.user.len > 0) p.user.slice() else "USOS", winlogon });
    try w.writeAll("HKLM,\"System\\CurrentControlSet\\Services\\VxD\\MSTCP\",EnableDNS,,\"1\"\r\n");
    try w.writeAll("HKLM,\"Software\\Microsoft\\Windows\\CurrentVersion\\Run\",USOSLan,,\"C:\\USOS9X\\USOSLAN.EXE\"\r\n");
}

/// REG set syntax consumed by usos-reg, with a caller-supplied line prefix.
pub fn ntRegistry(p: *const Profile, prefix: []const u8, w: *std.Io.Writer) !void {
    if (p.network == .off) return;
    const eol = if (std.mem.eql(u8, prefix, "reg=")) "\n" else "\r\n";
    for ([_][]const u8{ "USER", "DEFAULT" }) |root| {
        for ([_][]const u8{ "EnableAutodial", "ProxyEnable", "GlobalUserOffline" }) |name|
            try w.print("{s}{s}\\{s}|{s}|dword|0{s}", .{ prefix, root, internet, name, eol });
        try w.print("{s}{s}\\{s}|NoNetAutodial|dword|1{s}", .{ prefix, root, internet, eol });
        try w.print("{s}{s}\\{s}|Completed|binary|01,00,00,00{s}", .{ prefix, root, wizard, eol });
        // Custom URLs are applied from the data file, never interpolated in CMD/INF.
        try w.print("{s}{s}\\{s}|Start Page|sz|about:blank{s}", .{ prefix, root, main, eol });
        try w.print("{s}{s}\\{s}|First Home Page|sz|about:blank{s}", .{ prefix, root, main, eol });
        for ([_][]const u8{ "RunOnceHasShown", "RunOnceComplete" }) |name|
            try w.print("{s}{s}\\{s}|{s}|dword|1{s}", .{ prefix, root, main, name, eol });
    }
    try w.print("{s}HKLM\\{s}|EnableAutodial|dword|0{s}", .{ prefix, internet, eol });
}

pub fn nt4(p: *const Profile, workgroup: []const u8, w: *std.Io.Writer) !void {
    if (p.network == .off) return;
    // Q197302: install TCP/IP using the inbox loopback, independent of the VM NIC.
    // Native TCPCFG's unattended parser rejects zero in every address octet.
    // POST replaces this unconnected address with the requested LAN policy.
    try w.print("\r\n[Network]\r\nJoinWorkgroup={s}\r\nInstallAdapters=USOS.Adapters\r\nInstallProtocols=USOS.Protocols\r\nDoNotInstallInternetServer=Yes\r\n", .{workgroup});
    try w.writeAll("\r\n[USOS.Adapters]\r\nLOOP=USOS.Loop\r\n\r\n[USOS.Loop]\r\n\r\n[USOS.Protocols]\r\nTC=USOS.TCPIP\r\n\r\n[USOS.TCPIP]\r\nDHCP=No\r\nIPAddress=198.51.100.1\r\nSubnet=255.255.255.0\r\n");
    try metadata(p, false, w);
    try ntRegistry(p, ";USOS-REG=", w);
    try w.writeAll(";USOS-REG=HKLM\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer|Start|dword|4\r\n");
    try w.writeAll(";USOS-REG=HKLM\\SYSTEM\\CurrentControlSet\\Services\\Browser|Start|dword|4\r\n");
}

test "LAN off preserves the pre-network byte stream" {
    var p = Profile{};
    p.network = .off;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try msbatch(&p, "USOS", false, &w);
    try std.testing.expectEqualStrings("Clients=\r\nProtocols=\r\nServices=\r\n", w.buffered());
    w = .fixed(&buf);
    try nt4(&p, "WORKGROUP", &w);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "NT4 setup address satisfies the original TCPCFG unattended octet bounds" {
    const p = Profile{};
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try nt4(&p, "WORKGROUP", &w);
    const start = (std.mem.indexOf(u8, w.buffered(), "\r\nIPAddress=") orelse return error.MissingAddress) + "\r\nIPAddress=".len;
    const end = start + (std.mem.indexOf(u8, w.buffered()[start..], "\r\n") orelse return error.MissingLineEnd);
    var octets = std.mem.splitScalar(u8, w.buffered()[start..end], '.');
    var count: usize = 0;
    while (octets.next()) |octet| : (count += 1) {
        const value = try std.fmt.parseInt(u16, octet, 10);
        try std.testing.expect(value >= 1 and value <= (if (count == 0) @as(u16, 223) else 255));
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}
