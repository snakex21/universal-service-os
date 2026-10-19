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
    // DHCP DNS is supplied by the lease. The hardware step enforces EnableDNS=1.
    try w.print("DNS={s}\r\n", .{if (p.dns.len > 0) "1" else "0"});
    if (p.dns.len > 0) try w.print("DNSServers={s}\r\nHostname={s}\r\n", .{ p.dns.slice(), computer });
    try w.print("\r\n[OptionalComponents]\r\n\"Dial-Up Networking\"={d}\r\n\"Dial-Up Server\"=0\r\n\"Direct Cable Connection\"=0\r\n", .{@as(u8, if (!me and p.dialup == .on) 1 else 0)});
    try metadata(p, me, w);
}

pub fn msbatchRegistry(w: *std.Io.Writer) !void {
    try w.writeAll("\r\n[USOS.Lan]\r\n");
    for ([_][]const u8{ "EnableAutodial", "ProxyEnable", "GlobalUserOffline" }) |name|
        try w.print("HKCU,\"{s}\",{s},0x00010001,0\r\n", .{ internet, name });
    try w.print("HKCU,\"{s}\",NoNetAutodial,0x00010001,1\r\nHKLM,\"{s}\",EnableAutodial,0x00010001,0\r\n", .{ internet, internet });
    try w.print("HKCU,\"{s}\",Completed,1,01,00,00,00\r\nHKCU,\"{s}\",\"Start Page\",,\"about:blank\"\r\n", .{ wizard, main });
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
    }
    try w.print("{s}HKLM\\{s}|EnableAutodial|dword|0{s}", .{ prefix, internet, eol });
}

pub fn nt4(p: *const Profile, workgroup: []const u8, w: *std.Io.Writer) !void {
    if (p.network == .off) return;
    // Q197302: install TCP/IP using the inbox loopback, independent of the VM NIC.
    // This is an unconnected placeholder until an NT4-compatible LAN driver exists.
    try w.print("\r\n[Network]\r\nJoinWorkgroup={s}\r\nInstallAdapters=USOS.Adapters\r\nInstallProtocols=USOS.Protocols\r\nDoNotInstallInternetServer=Yes\r\n", .{workgroup});
    try w.writeAll("\r\n[USOS.Adapters]\r\nLOOP=USOS.Loop\r\n\r\n[USOS.Loop]\r\n\r\n[USOS.Protocols]\r\nTC=USOS.TCPIP\r\n\r\n[USOS.TCPIP]\r\nDHCP=No\r\nIPAddress=192.0.2.1\r\nSubnet=255.255.255.0\r\n");
    try metadata(p, false, w);
    try ntRegistry(p, ";USOS-REG=", w);
    try w.writeAll(";USOS-REG=HKLM\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer|Start|dword|4\r\n");
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
