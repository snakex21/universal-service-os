//! glibc SHA-512 crypt (`$6$`), Ulrich Drepper's "Unix crypt using SHA-256
//! and SHA-512" (the algorithm of glibc crypt(3), mkpasswd -m sha-512,
//! openssl passwd -6). Used by the Linux answer renderers (linux.zig) so an
//! answer file carries only the hash, never the password.
//!
//! No allocator: the result is written into a caller buffer of `max_len`.
const std = @import("std");
const Sha512 = std.crypto.hash.sha2.Sha512;

pub const default_rounds: u32 = 5000;
pub const min_rounds: u32 = 1000;
pub const max_rounds: u32 = 999_999_999;
pub const max_salt = 16;
/// "$6$rounds=999999999$" + 16 salt + "$" + 86 hash characters.
pub const max_len = 20 + max_salt + 1 + 86;

/// The crypt(3) base-64 alphabet (also the salt alphabet).
pub const alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

pub fn isSaltChar(c: u8) bool {
    return std.mem.indexOfScalar(u8, alphabet, c) != null;
}

/// 12 random bytes (96 bits) -> a 16-character salt from the crypt alphabet.
pub fn saltFromBytes(random: [12]u8) [16]u8 {
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const w = (@as(u32, random[i * 3]) << 16) | (@as(u32, random[i * 3 + 1]) << 8) | random[i * 3 + 2];
        for (0..4) |j| out[i * 4 + j] = alphabet[(w >> @intCast(6 * j)) & 0x3f];
    }
    return out;
}

/// Adds `source` repeated to `len` bytes (the P and S sequences, the B/K
/// blocks of step 2) to `h`.
fn addRepeated(h: *Sha512, source: *const [64]u8, len: usize) void {
    var left = len;
    while (left >= 64) : (left -= 64) h.update(source);
    h.update(source[0..left]);
}

/// `$6$[rounds=N$]<salt>$<hash>`. The salt is cut to 16 characters (like
/// glibc); `rounds` null writes no rounds= field and uses 5000, a value is
/// clamped to 1000..999999999 and always written. The salt must be from
/// the crypt alphabet (error.BadSalt otherwise, also when empty).
pub fn crypt(key: []const u8, salt_in: []const u8, rounds: ?u32, out: *[max_len]u8) error{BadSalt}![]const u8 {
    const salt = salt_in[0..@min(salt_in.len, max_salt)];
    if (salt.len == 0) return error.BadSalt;
    for (salt) |c| if (!isSaltChar(c)) return error.BadSalt;
    const n_rounds: u32 = if (rounds) |r| std.math.clamp(r, min_rounds, max_rounds) else default_rounds;

    // B = H(key salt key)
    var b: [64]u8 = undefined;
    {
        var h = Sha512.init(.{});
        h.update(key);
        h.update(salt);
        h.update(key);
        h.final(&b);
    }
    // A = H(key salt B-repeated-to-len(key) {bits of len(key): B or key})
    var a: [64]u8 = undefined;
    {
        var h = Sha512.init(.{});
        h.update(key);
        h.update(salt);
        addRepeated(&h, &b, key.len);
        var bits = key.len;
        while (bits > 0) : (bits >>= 1) {
            if (bits & 1 != 0) h.update(&b) else h.update(key);
        }
        h.final(&a);
    }
    // DP = H(key repeated len(key) times), P = DP repeated to len(key)
    var dp: [64]u8 = undefined;
    {
        var h = Sha512.init(.{});
        for (0..key.len) |_| h.update(key);
        h.final(&dp);
    }
    // DS = H(salt repeated 16 + A[0] times), S = DS repeated to len(salt)
    var ds: [64]u8 = undefined;
    {
        var h = Sha512.init(.{});
        for (0..16 + @as(usize, a[0])) |_| h.update(salt);
        h.final(&ds);
    }
    var c = a;
    for (0..n_rounds) |i| {
        var h = Sha512.init(.{});
        if (i & 1 != 0) addRepeated(&h, &dp, key.len) else h.update(&c);
        if (i % 3 != 0) addRepeated(&h, &ds, salt.len);
        if (i % 7 != 0) addRepeated(&h, &dp, key.len);
        if (i & 1 != 0) h.update(&c) else addRepeated(&h, &dp, key.len);
        h.final(&c);
    }

    var w: std.Io.Writer = .fixed(out);
    w.writeAll("$6$") catch unreachable;
    if (rounds != null) w.print("rounds={d}$", .{n_rounds}) catch unreachable;
    w.writeAll(salt) catch unreachable;
    w.writeByte('$') catch unreachable;
    const order = [21][3]u8{
        .{ 0, 21, 42 },  .{ 22, 43, 1 },  .{ 44, 2, 23 },  .{ 3, 24, 45 },  .{ 25, 46, 4 },
        .{ 47, 5, 26 },  .{ 6, 27, 48 },  .{ 28, 49, 7 },  .{ 50, 8, 29 },  .{ 9, 30, 51 },
        .{ 31, 52, 10 }, .{ 53, 11, 32 }, .{ 12, 33, 54 }, .{ 34, 55, 13 }, .{ 56, 14, 35 },
        .{ 15, 36, 57 }, .{ 37, 58, 16 }, .{ 59, 17, 38 }, .{ 18, 39, 60 }, .{ 40, 61, 19 },
        .{ 62, 20, 41 },
    };
    for (order) |t| b64(&w, c[t[0]], c[t[1]], c[t[2]], 4);
    b64(&w, 0, 0, c[63], 2);
    // Scrub the intermediate digests (they are password-derived).
    std.crypto.secureZero(u8, &b);
    std.crypto.secureZero(u8, &a);
    std.crypto.secureZero(u8, &dp);
    std.crypto.secureZero(u8, &ds);
    std.crypto.secureZero(u8, &c);
    return w.buffered();
}

fn b64(w: *std.Io.Writer, b2: u8, b1: u8, b0: u8, n: usize) void {
    var v = (@as(u32, b2) << 16) | (@as(u32, b1) << 8) | b0;
    for (0..n) |_| {
        w.writeByte(alphabet[v & 0x3f]) catch unreachable;
        v >>= 6;
    }
}

// ------------------------------------------------------------ tests

test "sha512crypt: Drepper reference vectors" {
    const cases = [_]struct { salt: []const u8, rounds: ?u32, key: []const u8, want: []const u8 }{
        .{ .salt = "saltstring", .rounds = null, .key = "Hello world!", .want = "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1" },
        .{ .salt = "saltstringsaltstring", .rounds = 10000, .key = "Hello world!", .want = "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v." },
        .{ .salt = "toolongsaltstring", .rounds = 5000, .key = "This is just a test", .want = "$6$rounds=5000$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0" },
        .{ .salt = "anotherlongsaltstring", .rounds = 1400, .key = "a very much longer text to encrypt.  This one even stretches over morethan one line.", .want = "$6$rounds=1400$anotherlongsalts$POfYwTEok97VWcjxIiSOjiykti.o/pQs.wPvMxQ6Fm7I6IoYN3CmLs66x9t0oSwbtEW7o7UmJEiDwGqd8p4ur1" },
        .{ .salt = "short", .rounds = 77777, .key = "we have a short salt string but not a short password", .want = "$6$rounds=77777$short$WuQyW2YR.hBNpjjRhpYD/ifIw05xdfeEyQoMxIXbkvr0gge1a1x3yRULJ5CCaUeOxFmtlcGZelFl5CxtgfiAc0" },
        .{ .salt = "asaltof16chars..", .rounds = 123456, .key = "a short string", .want = "$6$rounds=123456$asaltof16chars..$BtCwjqMJGx5hrJhZywWvt0RLE8uZ4oPwcelCjmw2kSYu.Ec6ycULevoBK25fs2xXgMNrCzIMVcgEJAstJeonj1" },
        .{ .salt = "roundstoolow", .rounds = 10, .key = "the minimum number is still observed", .want = "$6$rounds=1000$roundstoolow$kUMsbe306n21p9R.FRkW3IGn.S9NPN0x50YhH1xhLsPuWGsUSklZt58jaTfF4ZEQpyUNGc0dqbpBYYBaHHrsX." },
    };
    var out: [max_len]u8 = undefined;
    for (cases) |case| {
        errdefer std.debug.print("salt {s}\n", .{case.salt});
        try std.testing.expectEqualStrings(case.want, try crypt(case.key, case.salt, case.rounds, &out));
    }
}

test "sha512crypt: salt rules and salt generator" {
    var out: [max_len]u8 = undefined;
    try std.testing.expectError(error.BadSalt, crypt("x", "", null, &out));
    try std.testing.expectError(error.BadSalt, crypt("x", "bad$salt", null, &out));
    const s = saltFromBytes(@splat(0));
    try std.testing.expectEqualStrings("................", &s);
    const t = saltFromBytes(.{ 0xff, 0xff, 0xff, 0x12, 0x34, 0x56, 0xab, 0xcd, 0xef, 0x00, 0x01, 0x02 });
    for (t) |ch| try std.testing.expect(isSaltChar(ch));
    try std.testing.expectEqualStrings("zzzz", t[0..4]);
    const hash = try crypt("pw", &t, null, &out);
    try std.testing.expectEqual(@as(usize, 3 + 16 + 1 + 86), hash.len);
}
