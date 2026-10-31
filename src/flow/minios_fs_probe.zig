//! File system facts of one partition for the MiniOS erase confirmation, in
//! the form tools/xp_disk_overview.sh prints them on the Alpine route: the
//! lsblk FSTYPE name ("ntfs", "vfat", "exfat", "ext4", "swap", ...), the
//! label (lsblk LABEL, filtered like the script: [:alnum:] ._- , 18 chars)
//! and, for the file systems the script mounts (ntfs, vfat, ext2/3/4), the
//! df used / available space. Read only, from the partition's first
//! sectors and a few bounded metadata reads done by the caller (the NTFS
//! $Volume record, the FAT root directory and FSInfo, the NTFS $Bitmap).
//! Pure: host-tested.
const std = @import("std");

pub const Fs = enum {
    unknown,
    ntfs,
    vfat,
    exfat,
    ext2,
    ext3,
    ext4,
    swap,
    xfs,
    btrfs,
    bitlocker,

    /// The lsblk FSTYPE text (Alpine shows "unknown" for none).
    pub fn name(self: Fs) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .bitlocker => "BitLocker",
            else => @tagName(self),
        };
    }

    /// The file systems xp_disk_overview.sh mounts (ntfs3, vfat, ext4) and
    /// so shows used / free space and a system for.
    pub fn mounted(self: Fs) bool {
        return switch (self) {
            .ntfs, .vfat, .ext2, .ext3, .ext4 => true,
            else => false,
        };
    }
};

/// Bytes of the partition start the caller reads for `detect` (the btrfs
/// superblock sits at 64 KiB).
pub const head_bytes: usize = 0x10000 + 4096;

pub const Probe = struct {
    fs: Fs = .unknown,
    label: [18]u8 = undefined,
    label_len: usize = 0,
    /// df -kP "Used" / "Available" in bytes (null: unknown).
    used: ?u64 = null,
    free: ?u64 = null,
    /// xp_detect_system.sh text, null: not inspected ("System unknown").
    system: ?[]const u8 = null,

    pub fn labelText(self: *const Probe) []const u8 {
        return self.label[0..self.label_len];
    }

    /// The script's `tr -cd '[:alnum:] ._- ' | cut -c1-18` on ASCII text.
    pub fn setLabel(self: *Probe, raw: []const u8) void {
        var n: usize = 0;
        for (raw) |c| {
            if (c == 0) break;
            const keep = std.ascii.isAlphanumeric(c) or c == ' ' or c == '.' or c == '_' or c == '-';
            if (!keep) continue;
            if (n == self.label.len) break;
            self.label[n] = c;
            n += 1;
        }
        // blkid trims the padding of fixed-width labels (FAT, XFS).
        while (n > 0 and self.label[n - 1] == ' ') n -= 1;
        self.label_len = n;
    }

    /// UTF-16LE label (NTFS $VOLUME_NAME, exFAT): ASCII units only, as the
    /// script's tr filter drops multibyte characters.
    pub fn setLabelUtf16(self: *Probe, bytes: []const u8) void {
        var ascii: [64]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i + 1 < bytes.len and n < ascii.len) : (i += 2) {
            const unit = std.mem.readInt(u16, bytes[i..][0..2], .little);
            if (unit == 0) break;
            if (unit >= 0x80) continue;
            ascii[n] = @intCast(unit);
            n += 1;
        }
        self.setLabel(ascii[0..n]);
    }
};

fn at(head: []const u8, offset: usize, comptime magic: []const u8) bool {
    return head.len >= offset + magic.len and std.mem.eql(u8, head[offset..][0..magic.len], magic);
}

/// The file system type from the partition head (blkid's magic checks).
pub fn detect(head: []const u8) Fs {
    if (at(head, 3, "NTFS    ")) return .ntfs;
    if (at(head, 3, "-FVE-FS-")) return .bitlocker;
    if (at(head, 3, "EXFAT   ")) return .exfat;
    if (FatBpb.parse(head) != null) return .vfat;
    if (head.len >= 1024 + 1024 and std.mem.readInt(u16, head[1024 + 56 ..][0..2], .little) == 0xef53) return extKind(head[1024..2048]);
    if (at(head, 4096 - 10, "SWAPSPACE2") or at(head, 4096 - 10, "SWAP-SPACE")) return .swap;
    if (at(head, 0, "XFSB")) return .xfs;
    if (at(head, 0x10040, "_BHRfS_M")) return .btrfs;
    return .unknown;
}

/// Type, label and (ext) space from the head alone; NTFS, FAT and exFAT
/// labels and space need the caller's metadata reads.
pub fn probeHead(head: []const u8) Probe {
    var p: Probe = .{ .fs = detect(head) };
    switch (p.fs) {
        .vfat => {
            const bpb = FatBpb.parse(head).?;
            if (!std.mem.eql(u8, bpb.label(head), "NO NAME    ")) p.setLabel(bpb.label(head));
        },
        .ext2, .ext3, .ext4 => {
            const sb = head[1024..2048];
            p.setLabel(sb[120..136]);
            const space = extSpace(sb);
            p.used = space.used;
            p.free = space.free;
        },
        .swap => if (at(head, 4096 - 10, "SWAPSPACE2")) p.setLabel(head[1024 + 28 ..][0..16]),
        .xfs => p.setLabel(head[108..120]),
        .btrfs => p.setLabel(head[0x10000 + 0x12b ..][0..@min(256, head.len - (0x10000 + 0x12b))]),
        else => {},
    }
    return p;
}

// ------------------------------------------------------------------- ext

/// blkid's ext2 / ext3 / ext4 decision: features beyond ext3's set make
/// it ext4, a journal ext3.
fn extKind(sb: []const u8) Fs {
    const compat = std.mem.readInt(u32, sb[92..96], .little);
    const incompat = std.mem.readInt(u32, sb[96..100], .little);
    const ro_compat = std.mem.readInt(u32, sb[100..104], .little);
    const ext3_incompat: u32 = 0x0002 | 0x0004 | 0x0010; // FILETYPE, RECOVER, META_BG
    const ext3_ro: u32 = 0x0001 | 0x0002 | 0x0004; // SPARSE_SUPER, LARGE_FILE, BTREE_DIR
    if (incompat & ~ext3_incompat != 0 or ro_compat & ~ext3_ro != 0) return .ext4;
    if (compat & 0x0004 != 0) return .ext3; // HAS_JOURNAL
    return .ext2;
}

pub const Space = struct { used: ?u64 = null, free: ?u64 = null };

/// statfs of ext4 as df shows it: used = blocks - free, available = free -
/// reserved (the "bsddf" metadata overhead is not subtracted here).
pub fn extSpace(sb: []const u8) Space {
    if (sb.len < 0x160) return .{};
    const log = std.mem.readInt(u32, sb[24..28], .little);
    if (log > 6) return .{};
    const block: u64 = @as(u64, 1024) << @intCast(log);
    const wide = std.mem.readInt(u32, sb[96..100], .little) & 0x80 != 0; // 64BIT
    const hi = struct {
        fn get(s: []const u8, lo: usize, hi_off: usize, w: bool) u64 {
            const l: u64 = std.mem.readInt(u32, s[lo..][0..4], .little);
            const h: u64 = if (w) std.mem.readInt(u32, s[hi_off..][0..4], .little) else 0;
            return l | (h << 32);
        }
    };
    const blocks = hi.get(sb, 4, 0x150, wide);
    const reserved = hi.get(sb, 8, 0x154, wide);
    const free = hi.get(sb, 12, 0x158, wide);
    if (free > blocks) return .{};
    return .{ .used = (blocks - free) * block, .free = (free -| reserved) * block };
}

// ------------------------------------------------------------------- FAT

pub const FatBpb = struct {
    bits: u8,
    bytes_per_sector: u32,
    sectors_per_cluster: u32,
    reserved: u32,
    fats: u32,
    root_entries: u32,
    fat_sectors: u32,
    total_sectors: u32,
    root_cluster: u32,
    fsinfo_sector: u32,
    clusters: u32,

    pub fn clusterBytes(self: FatBpb) u64 {
        return @as(u64, self.bytes_per_sector) * self.sectors_per_cluster;
    }
    pub fn rootDirSector(self: FatBpb) u32 {
        return self.reserved + self.fats * self.fat_sectors;
    }
    pub fn rootDirSectors(self: FatBpb) u32 {
        return (self.root_entries * 32 + self.bytes_per_sector - 1) / self.bytes_per_sector;
    }
    pub fn dataSector(self: FatBpb) u32 {
        return self.rootDirSector() + self.rootDirSectors();
    }
    /// Partition byte offset of data cluster `cluster` (>= 2).
    pub fn clusterOffset(self: FatBpb, cluster: u32) u64 {
        return (@as(u64, self.dataSector()) + @as(u64, cluster - 2) * self.sectors_per_cluster) * self.bytes_per_sector;
    }
    /// BPB volume label (FAT12/16 at 43, FAT32 at 71).
    pub fn label(self: FatBpb, boot: []const u8) []const u8 {
        return if (self.bits == 32) boot[71..82] else boot[43..54];
    }

    /// A FAT BPB (Microsoft's FAT spec: the cluster count decides the FAT
    /// width). Null: not FAT.
    pub fn parse(boot: []const u8) ?FatBpb {
        if (boot.len < 512 or boot[510] != 0x55 or boot[511] != 0xaa) return null;
        if (boot[0] != 0xeb and boot[0] != 0xe9) return null;
        const bps: u32 = std.mem.readInt(u16, boot[11..13], .little);
        const spc: u32 = boot[13];
        if (bps < 512 or bps > 4096 or bps & (bps - 1) != 0) return null;
        if (spc == 0 or spc & (spc - 1) != 0) return null;
        const reserved: u32 = std.mem.readInt(u16, boot[14..16], .little);
        const fats: u32 = boot[16];
        if (reserved == 0 or fats == 0 or fats > 4) return null;
        if (boot[21] != 0xf0 and boot[21] < 0xf8) return null; // media byte
        const root_entries: u32 = std.mem.readInt(u16, boot[17..19], .little);
        const total16: u32 = std.mem.readInt(u16, boot[19..21], .little);
        const total: u32 = if (total16 != 0) total16 else std.mem.readInt(u32, boot[32..36], .little);
        const fat16: u32 = std.mem.readInt(u16, boot[22..24], .little);
        const fat_sectors: u32 = if (fat16 != 0) fat16 else std.mem.readInt(u32, boot[36..40], .little);
        if (total == 0 or fat_sectors == 0) return null;
        var bpb: FatBpb = .{ .bits = 0, .bytes_per_sector = bps, .sectors_per_cluster = spc, .reserved = reserved, .fats = fats, .root_entries = root_entries, .fat_sectors = fat_sectors, .total_sectors = total, .root_cluster = 0, .fsinfo_sector = 0, .clusters = 0 };
        const data = bpb.dataSector();
        if (data >= total) return null;
        bpb.clusters = (total - data) / spc;
        bpb.bits = if (bpb.clusters < 4085) 12 else if (bpb.clusters < 65525) 16 else 32;
        if (bpb.bits == 32) {
            if (fat16 != 0 or root_entries != 0) return null;
            bpb.root_cluster = std.mem.readInt(u32, boot[44..48], .little);
            bpb.fsinfo_sector = std.mem.readInt(u16, boot[48..50], .little);
        }
        return bpb;
    }
};

/// FSInfo free cluster count (FAT32), null when the signatures or the
/// count are not valid (Linux then counts the FAT).
pub fn fsinfoFree(sector: []const u8, clusters: u32) ?u32 {
    if (sector.len < 512) return null;
    if (std.mem.readInt(u32, sector[0..4], .little) != 0x41615252) return null;
    if (std.mem.readInt(u32, sector[484..488], .little) != 0x61417272) return null;
    if (std.mem.readInt(u32, sector[508..512], .little) != 0xaa550000) return null;
    const free = std.mem.readInt(u32, sector[488..492], .little);
    return if (free <= clusters) free else null;
}

/// Free clusters in a slice of the FAT. `first` is the cluster number of
/// the first entry in `fat` (entries 0 and 1 are reserved; counting
/// stops after cluster clusters + 1). FAT12 slices must start at an
/// even cluster.
pub fn countFreeFat(bits: u8, fat: []const u8, first: u32, clusters: u32) u32 {
    const last = clusters + 1;
    var free: u32 = 0;
    var cluster = first;
    switch (bits) {
        32 => {
            var i: usize = 0;
            while (i + 4 <= fat.len and cluster <= last) : ({
                i += 4;
                cluster += 1;
            }) {
                if (cluster >= 2 and std.mem.readInt(u32, fat[i..][0..4], .little) & 0x0fffffff == 0) free += 1;
            }
        },
        16 => {
            var i: usize = 0;
            while (i + 2 <= fat.len and cluster <= last) : ({
                i += 2;
                cluster += 1;
            }) {
                if (cluster >= 2 and std.mem.readInt(u16, fat[i..][0..2], .little) == 0) free += 1;
            }
        },
        12 => {
            var i: usize = 0;
            while (i + 3 <= fat.len and cluster <= last) : (i += 3) {
                const pair: u32 = @as(u32, fat[i]) | (@as(u32, fat[i + 1]) << 8) | (@as(u32, fat[i + 2]) << 16);
                if (cluster >= 2 and pair & 0xfff == 0) free += 1;
                cluster += 1;
                if (cluster <= last and cluster >= 2 and pair >> 12 == 0) free += 1;
                cluster += 1;
            }
        },
        else => {},
    }
    return free;
}

/// FAT byte length holding the entries of clusters 0 .. clusters + 1.
pub fn fatBytes(bits: u8, clusters: u32) u64 {
    const entries: u64 = @as(u64, clusters) + 2;
    return switch (bits) {
        32 => entries * 4,
        16 => entries * 2,
        else => (entries * 3 + 1) / 2,
    };
}

/// The volume label entry (attribute 08h) of a FAT root directory slice:
/// blkid prefers it over the BPB label.
pub fn fatDirLabel(dir: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 32 <= dir.len) : (i += 32) {
        const e = dir[i..][0..32];
        if (e[0] == 0) return null;
        if (e[0] == 0xe5) continue;
        if (e[11] == 0x0f) continue; // LFN
        if (e[11] & 0x08 != 0 and e[11] & 0x10 == 0) return e[0..11];
    }
    return null;
}

pub const DirHit = union(enum) {
    /// No such entry in this slice; the directory goes on.
    more,
    /// The end-of-directory entry: no such entry at all.
    end,
    /// Found: the entry's first cluster.
    found: u32,
};

/// An 8.3 name ("NTLDR      ", "BOOTMGR    ") in a FAT directory slice;
/// `directory`: wanted as a directory, else as a file.
pub fn fatDirFind(dir: []const u8, name83: *const [11]u8, directory: bool) DirHit {
    var i: usize = 0;
    while (i + 32 <= dir.len) : (i += 32) {
        const e = dir[i..][0..32];
        if (e[0] == 0) return .end;
        if (e[0] == 0xe5 or e[11] == 0x0f or e[11] & 0x08 != 0) continue;
        if (!std.ascii.eqlIgnoreCase(e[0..11], name83)) continue;
        if ((e[11] & 0x10 != 0) != directory) continue;
        const hi: u32 = std.mem.readInt(u16, e[20..22], .little);
        return .{ .found = (hi << 16) | std.mem.readInt(u16, e[26..28], .little) };
    }
    return .more;
}

pub fn fatDirHas(dir: []const u8, name83: *const [11]u8, directory: bool) bool {
    return fatDirFind(dir, name83, directory) == .found;
}

/// Byte offset of cluster `cluster`'s entry in the FAT.
pub fn fatEntryOffset(bits: u8, cluster: u32) u64 {
    return switch (bits) {
        32 => @as(u64, cluster) * 4,
        16 => @as(u64, cluster) * 2,
        else => @as(u64, cluster) + cluster / 2,
    };
}

/// The FAT entry of `cluster` from the (at least 2, FAT32 4) bytes at
/// fatEntryOffset; null: end of chain, bad or free cluster.
pub fn fatNext(bits: u8, bytes: []const u8, cluster: u32) ?u32 {
    const value: u32 = switch (bits) {
        32 => std.mem.readInt(u32, bytes[0..4], .little) & 0x0fffffff,
        16 => std.mem.readInt(u16, bytes[0..2], .little),
        else => blk: {
            const pair: u32 = std.mem.readInt(u16, bytes[0..2], .little);
            break :blk if (cluster & 1 != 0) pair >> 4 else pair & 0xfff;
        },
    };
    const end: u32 = switch (bits) {
        32 => 0x0ffffff7,
        16 => 0xfff7,
        else => 0xff7,
    };
    return if (value < 2 or value >= end) null else value;
}

/// Free / used bytes of a FAT volume from its free cluster count (statfs of
/// Linux vfat: f_blocks = cluster count, f_bfree = free clusters).
pub fn fatSpace(bpb: FatBpb, free_clusters: u32) Space {
    const free = @min(free_clusters, bpb.clusters);
    return .{ .used = @as(u64, bpb.clusters - free) * bpb.clusterBytes(), .free = @as(u64, free) * bpb.clusterBytes() };
}

// ----------------------------------------------------------------- exFAT

pub const Exfat = struct {
    heap_offset: u32,
    root_cluster: u32,
    sector_shift: u5,
    cluster_shift: u5,

    pub fn parse(boot: []const u8) ?Exfat {
        if (boot.len < 512 or !at(boot, 3, "EXFAT   ")) return null;
        const ss = boot[108];
        const cs = boot[109];
        if (ss < 9 or ss > 12 or cs > 25 or @as(u32, ss) + cs > 31) return null;
        return .{ .heap_offset = std.mem.readInt(u32, boot[88..92], .little), .root_cluster = std.mem.readInt(u32, boot[96..100], .little), .sector_shift = @intCast(ss), .cluster_shift = @intCast(cs) };
    }
    pub fn clusterOffset(self: Exfat, cluster: u32) u64 {
        return (@as(u64, self.heap_offset) << self.sector_shift) + (@as(u64, cluster -| 2) << (@as(u6, self.sector_shift) + self.cluster_shift));
    }
};

/// The exFAT volume label directory entry (type 83h): count at byte 1,
/// UTF-16LE text from byte 2 (at most 11 units).
pub fn exfatLabel(dir: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 32 <= dir.len) : (i += 32) {
        const e = dir[i..][0..32];
        if (e[0] == 0) return null;
        if (e[0] == 0x83) return e[2..][0 .. @as(usize, @min(e[1], 11)) * 2];
    }
    return null;
}

// ------------------------------------------------------------------ NTFS

pub const Ntfs = struct {
    bytes_per_sector: u32,
    cluster_bytes: u64,
    total_clusters: u64,
    mft_lcn: u64,
    record_bytes: u32,

    pub fn parse(boot: []const u8) ?Ntfs {
        if (boot.len < 512 or !at(boot, 3, "NTFS    ")) return null;
        const bps: u32 = std.mem.readInt(u16, boot[11..13], .little);
        if (bps < 256 or bps > 4096 or bps & (bps - 1) != 0) return null;
        const raw = boot[13];
        const spc: u64 = if (raw <= 0x80) raw else if (raw >= 0xf4) @as(u64, 1) << @intCast(256 - @as(u16, raw)) else return null;
        if (spc == 0) return null;
        const cluster = spc * bps;
        const code: i8 = @bitCast(boot[64]);
        const record: u64 = if (code > 0) @as(u64, @intCast(code)) * cluster else if (code >= -31 and code < 0) @as(u64, 1) << @intCast(-@as(i16, code)) else return null;
        if (record < 512 or record > 4096) return null;
        const sectors = std.mem.readInt(u64, boot[40..48], .little);
        return .{ .bytes_per_sector = bps, .cluster_bytes = cluster, .total_clusters = sectors / spc, .mft_lcn = std.mem.readInt(u64, boot[48..56], .little), .record_bytes = @intCast(record) };
    }

    /// Partition byte offset of MFT record `n` (the first 16 records are
    /// always in the MFT's first run).
    pub fn recordOffset(self: Ntfs, n: u64) u64 {
        return self.mft_lcn * self.cluster_bytes + n * self.record_bytes;
    }

    pub fn space(self: Ntfs, used_clusters: u64) Space {
        const used = @min(used_clusters, self.total_clusters);
        return .{ .used = used * self.cluster_bytes, .free = (self.total_clusters - used) * self.cluster_bytes };
    }
};

/// Applies the update sequence array of an MFT record in place.
pub fn applyFixups(record: []u8, bytes_per_sector: u32) bool {
    if (record.len < 48 or !std.mem.eql(u8, record[0..4], "FILE")) return false;
    const usa: usize = std.mem.readInt(u16, record[4..6], .little);
    const count: usize = std.mem.readInt(u16, record[6..8], .little);
    if (count < 1 or usa + count * 2 > record.len or (count - 1) * bytes_per_sector > record.len) return false;
    const check = record[usa..][0..2].*;
    for (1..count) |i| {
        const end = i * bytes_per_sector - 2;
        if (!std.mem.eql(u8, record[end..][0..2], &check)) return false;
        @memcpy(record[end..][0..2], record[usa + i * 2 ..][0..2]);
    }
    return true;
}

/// The resident $VOLUME_NAME (60h) value of the $Volume record (MFT 3),
/// fixups applied: UTF-16LE.
pub fn ntfsVolumeName(record: []const u8) ?[]const u8 {
    if (record.len < 48 or !std.mem.eql(u8, record[0..4], "FILE")) return null;
    var offset: usize = std.mem.readInt(u16, record[20..22], .little);
    while (offset + 24 <= record.len) {
        const kind = std.mem.readInt(u32, record[offset..][0..4], .little);
        if (kind == 0xffffffff) return null;
        const len = std.mem.readInt(u32, record[offset + 4 ..][0..4], .little);
        if (len < 24 or offset + len > record.len) return null;
        if (kind == 0x60 and record[offset + 8] == 0) {
            const vlen = std.mem.readInt(u32, record[offset + 16 ..][0..4], .little);
            const voff = std.mem.readInt(u16, record[offset + 20 ..][0..2], .little);
            if (voff + vlen > len) return null;
            return record[offset + voff ..][0..vlen];
        }
        offset += len;
    }
    return null;
}

/// Set bits of a $Bitmap slice (clusters in use), counting at most
/// `bits` bits.
pub fn countSetBits(bytes: []const u8, bits: u64) u64 {
    var total: u64 = 0;
    const whole: usize = @intCast(@min(bits / 8, bytes.len));
    for (bytes[0..whole]) |b| total += @popCount(b);
    if (whole < bytes.len and bits % 8 != 0 and bits / 8 == whole) {
        const mask: u8 = (@as(u8, 1) << @intCast(bits % 8)) - 1;
        total += @popCount(bytes[whole] & mask);
    }
    return total;
}

// ----------------------------------------------------------------- tests

fn fatBoot(bits: u8) [512]u8 {
    var b: [512]u8 = @splat(0);
    b[0] = 0xeb;
    b[510] = 0x55;
    b[511] = 0xaa;
    std.mem.writeInt(u16, b[11..13], 512, .little);
    b[16] = 2;
    b[21] = 0xf8;
    if (bits == 32) {
        b[13] = 1;
        std.mem.writeInt(u16, b[14..16], 32, .little);
        std.mem.writeInt(u32, b[32..36], 204800, .little); // 100 MiB
        std.mem.writeInt(u32, b[36..40], 1600, .little);
        std.mem.writeInt(u32, b[44..48], 2, .little);
        std.mem.writeInt(u16, b[48..50], 1, .little);
        @memcpy(b[71..82], "SYSTEM     ");
        @memcpy(b[82..90], "FAT32   ");
    } else {
        b[13] = 4;
        std.mem.writeInt(u16, b[14..16], 1, .little);
        std.mem.writeInt(u16, b[17..19], 512, .little);
        std.mem.writeInt(u16, b[19..21], 40960, .little); // 20 MiB
        std.mem.writeInt(u16, b[22..24], 40, .little);
        @memcpy(b[43..54], "NO NAME    ");
        @memcpy(b[54..62], "FAT16   ");
    }
    return b;
}

test "FAT BPB: FAT32 and FAT16 geometry, BPB labels, root directory label wins" {
    var head: [head_bytes]u8 = @splat(0);
    const b32 = fatBoot(32);
    @memcpy(head[0..512], &b32);
    try std.testing.expectEqual(Fs.vfat, detect(&head));
    const bpb = FatBpb.parse(&head).?;
    try std.testing.expectEqual(@as(u8, 32), bpb.bits);
    try std.testing.expectEqual(@as(u32, 204800 - 3232), bpb.clusters);
    try std.testing.expectEqual(@as(u64, 3232 * 512), bpb.clusterOffset(2));
    var p = probeHead(&head);
    try std.testing.expectEqualStrings("SYSTEM", p.labelText());

    var dir: [96]u8 = @splat(0);
    @memcpy(dir[0..11], "BOOTMGR    ");
    dir[11] = 0x27;
    @memcpy(dir[32..43], "Win 10 Boot");
    dir[43] = 0x08;
    p.setLabel(fatDirLabel(&dir).?);
    try std.testing.expectEqualStrings("Win 10 Boot", p.labelText());
    try std.testing.expect(fatDirHas(&dir, "bootmgr    ", false));
    try std.testing.expect(!fatDirHas(&dir, "BOOTMGR    ", true));
    try std.testing.expect(!fatDirHas(&dir, "NTLDR      ", false));
    dir[20] = 0x01;
    dir[26] = 0x34;
    dir[27] = 0x12;
    try std.testing.expectEqual(DirHit{ .found = 0x11234 }, fatDirFind(&dir, "BOOTMGR    ", false));
    try std.testing.expectEqual(DirHit.end, fatDirFind(&dir, "WINDOWS    ", true));
    try std.testing.expectEqual(DirHit.more, fatDirFind(dir[0..64], "WINDOWS    ", true));

    try std.testing.expectEqual(@as(u64, 4), fatEntryOffset(12, 3));
    try std.testing.expectEqual(@as(?u32, 0x123), fatNext(12, &[_]u8{ 0x30, 0x12 }, 3)); // odd: high 12 bits
    try std.testing.expectEqual(@as(?u32, 0x230), fatNext(12, &[_]u8{ 0x30, 0x12 }, 2)); // even: low 12 bits
    try std.testing.expectEqual(@as(?u32, null), fatNext(16, &[_]u8{ 0xff, 0xff }, 2));
    try std.testing.expectEqual(@as(?u32, 7), fatNext(32, &[_]u8{ 7, 0, 0, 0xf0 }, 2));
    try std.testing.expectEqual(@as(?u32, null), fatNext(32, &[_]u8{ 0xf8, 0xff, 0xff, 0x0f }, 2));

    const b16 = fatBoot(16);
    const g16 = FatBpb.parse(&b16).?;
    try std.testing.expectEqual(@as(u8, 16), g16.bits);
    try std.testing.expectEqual(@as(u32, 81), g16.rootDirSector());
    try std.testing.expectEqual(@as(u32, 32), g16.rootDirSectors());
    try std.testing.expectEqual(@as(usize, 0), probeHead(&b16).label_len); // NO NAME
    var bad = b16;
    bad[510] = 0;
    try std.testing.expect(FatBpb.parse(&bad) == null);
}

test "FAT free space: FSInfo, FAT32 / FAT16 / FAT12 entry counts" {
    var info: [512]u8 = @splat(0);
    std.mem.writeInt(u32, info[0..4], 0x41615252, .little);
    std.mem.writeInt(u32, info[484..488], 0x61417272, .little);
    std.mem.writeInt(u32, info[508..512], 0xaa550000, .little);
    std.mem.writeInt(u32, info[488..492], 1000, .little);
    try std.testing.expectEqual(@as(?u32, 1000), fsinfoFree(&info, 25000));
    try std.testing.expectEqual(@as(?u32, null), fsinfoFree(&info, 999));
    std.mem.writeInt(u32, info[488..492], 0xffffffff, .little);
    try std.testing.expectEqual(@as(?u32, null), fsinfoFree(&info, 25000));

    // FAT32: entries 0,1 reserved; clusters 2..5 = used, free, free, EOC; 6 beyond.
    const fat32 = [_]u32{ 0x0ffffff8, 0x0fffffff, 3, 0, 0xf0000000, 0x0fffffff, 0 };
    try std.testing.expectEqual(@as(u32, 2), countFreeFat(32, std.mem.sliceAsBytes(&fat32), 0, 4));
    const fat16 = [_]u16{ 0xfff8, 0xffff, 0, 0, 5, 0xffff };
    try std.testing.expectEqual(@as(u32, 2), countFreeFat(16, std.mem.sliceAsBytes(&fat16), 0, 4));
    // FAT12 entries 0..5: ff8, fff, 000, 003, 000, fff (two per 3 bytes).
    const fat12 = [_]u8{ 0xf8, 0xff, 0xff, 0x00, 0x30, 0x00, 0x00, 0xf0, 0xff };
    try std.testing.expectEqual(@as(u32, 2), countFreeFat(12, &fat12, 0, 4));
    try std.testing.expectEqual(@as(u64, 9), fatBytes(12, 4));
    try std.testing.expectEqual(@as(u64, 24), fatBytes(32, 4));

    const bpb = FatBpb.parse(&fatBoot(32)).?;
    const s = fatSpace(bpb, 20000);
    try std.testing.expectEqual(@as(u64, 20000 * 512), s.free.?);
    try std.testing.expectEqual(@as(u64, (bpb.clusters - 20000) * 512), s.used.?);
}

test "NTFS: boot geometry, fixups, $VOLUME_NAME, $Bitmap bit count" {
    var boot: [512]u8 = @splat(0);
    @memcpy(boot[3..11], "NTFS    ");
    std.mem.writeInt(u16, boot[11..13], 512, .little);
    boot[13] = 8;
    std.mem.writeInt(u64, boot[40..48], 1048576, .little); // 512 MiB
    std.mem.writeInt(u64, boot[48..56], 4, .little);
    boot[64] = 0xf6; // -10: 1024-byte records
    try std.testing.expectEqual(Fs.ntfs, detect(&boot));
    const n = Ntfs.parse(&boot).?;
    try std.testing.expectEqual(@as(u64, 4096), n.cluster_bytes);
    try std.testing.expectEqual(@as(u64, 131072), n.total_clusters);
    try std.testing.expectEqual(@as(u32, 1024), n.record_bytes);
    try std.testing.expectEqual(@as(u64, 4 * 4096 + 3 * 1024), n.recordOffset(3));
    const sp = n.space(31072);
    try std.testing.expectEqual(@as(u64, 31072 * 4096), sp.used.?);
    try std.testing.expectEqual(@as(u64, 100000 * 4096), sp.free.?);
    boot[13] = 0xf4; // 2^12 sectors per cluster (64K-cluster volumes and up)
    try std.testing.expectEqual(@as(u64, 4096 * 512), Ntfs.parse(&boot).?.cluster_bytes);

    var rec: [1024]u8 = @splat(0);
    @memcpy(rec[0..4], "FILE");
    std.mem.writeInt(u16, rec[4..6], 48, .little);
    std.mem.writeInt(u16, rec[6..8], 3, .little);
    std.mem.writeInt(u16, rec[48..50], 0xabcd, .little);
    std.mem.writeInt(u16, rec[50..52], 0x1111, .little);
    std.mem.writeInt(u16, rec[52..54], 0x2222, .little);
    std.mem.writeInt(u16, rec[20..22], 56, .little);
    // $STANDARD_INFORMATION stub, then $VOLUME_NAME "Windows", then end.
    std.mem.writeInt(u32, rec[56..60], 0x10, .little);
    std.mem.writeInt(u32, rec[60..64], 24, .little);
    const a = 80;
    std.mem.writeInt(u32, rec[a..][0..4], 0x60, .little);
    std.mem.writeInt(u32, rec[a + 4 ..][0..4], 40, .little);
    std.mem.writeInt(u32, rec[a + 16 ..][0..4], 14, .little);
    std.mem.writeInt(u16, rec[a + 20 ..][0..2], 24, .little);
    const name16 = std.unicode.utf8ToUtf16LeStringLiteral("Windows");
    @memcpy(rec[a + 24 ..][0..14], std.mem.sliceAsBytes(name16));
    std.mem.writeInt(u32, rec[a + 40 ..][0..4], 0xffffffff, .little);
    std.mem.writeInt(u16, rec[510..512], 0xabcd, .little);
    std.mem.writeInt(u16, rec[1022..1024], 0xabcd, .little);
    try std.testing.expect(applyFixups(&rec, 512));
    try std.testing.expectEqual(@as(u16, 0x1111), std.mem.readInt(u16, rec[510..512], .little));
    var p: Probe = .{ .fs = .ntfs };
    p.setLabelUtf16(ntfsVolumeName(&rec).?);
    try std.testing.expectEqualStrings("Windows", p.labelText());
    std.mem.writeInt(u16, rec[1022..1024], 0x0bad, .little);
    std.mem.writeInt(u16, rec[48..50], 0x0bad + 1, .little);
    try std.testing.expect(!applyFixups(&rec, 512));

    try std.testing.expectEqual(@as(u64, 16), countSetBits(&[_]u8{ 0xff, 0x0f, 0xff }, 20));
    try std.testing.expectEqual(@as(u64, 20), countSetBits(&[_]u8{ 0xff, 0x0f, 0xff }, 24));
    try std.testing.expectEqual(@as(u64, 8), countSetBits(&[_]u8{ 0xff, 0xff }, 8));
}

test "ext2/3/4 kind, label and df space; swap, xfs, btrfs, exFAT, BitLocker" {
    var head: [head_bytes]u8 = @splat(0);
    const sb = head[1024..2048];
    std.mem.writeInt(u16, sb[56..58], 0xef53, .little);
    std.mem.writeInt(u32, sb[24..28], 2, .little); // 4096-byte blocks
    std.mem.writeInt(u32, sb[4..8], 262144, .little); // 1 GiB
    std.mem.writeInt(u32, sb[8..12], 13107, .little);
    std.mem.writeInt(u32, sb[12..16], 200000, .little);
    @memcpy(sb[120..127], "rootfs!");
    try std.testing.expectEqual(Fs.ext2, detect(&head));
    std.mem.writeInt(u32, sb[92..96], 0x4, .little);
    try std.testing.expectEqual(Fs.ext3, detect(&head));
    std.mem.writeInt(u32, sb[96..100], 0x2 | 0x40, .little); // extents
    const p = probeHead(&head);
    try std.testing.expectEqual(Fs.ext4, p.fs);
    try std.testing.expectEqualStrings("rootfs", p.labelText());
    try std.testing.expectEqual(@as(u64, 62144 * 4096), p.used.?);
    try std.testing.expectEqual(@as(u64, (200000 - 13107) * 4096), p.free.?);

    @memset(&head, 0);
    @memcpy(head[4086..4096], "SWAPSPACE2");
    @memcpy(head[1024 + 28 ..][0..4], "swap");
    const s = probeHead(&head);
    try std.testing.expectEqual(Fs.swap, s.fs);
    try std.testing.expectEqualStrings("swap", s.labelText());
    try std.testing.expectEqualStrings("swap", s.fs.name());

    @memset(&head, 0);
    @memcpy(head[0..4], "XFSB");
    @memcpy(head[108..112], "data");
    try std.testing.expectEqualStrings("data", probeHead(&head).labelText());
    @memset(&head, 0);
    @memcpy(head[0x10040..0x10048], "_BHRfS_M");
    try std.testing.expectEqual(Fs.btrfs, detect(&head));
    @memset(&head, 0);
    @memcpy(head[3..11], "-FVE-FS-");
    try std.testing.expectEqualStrings("BitLocker", detect(&head).name());
    try std.testing.expect(!Fs.bitlocker.mounted());

    @memset(&head, 0);
    @memcpy(head[3..11], "EXFAT   ");
    head[510] = 0x55;
    head[511] = 0xaa;
    std.mem.writeInt(u32, head[88..92], 2048, .little);
    std.mem.writeInt(u32, head[96..100], 5, .little);
    head[108] = 9;
    head[109] = 6;
    try std.testing.expectEqual(Fs.exfat, detect(&head));
    const ex = Exfat.parse(&head).?;
    try std.testing.expectEqual(@as(u64, 2048 * 512 + 3 * 32768), ex.clusterOffset(5));
    var dir: [64]u8 = @splat(0);
    dir[0] = 0x81;
    dir[32] = 0x83;
    dir[33] = 4;
    @memcpy(dir[34..42], std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("USB!")));
    var e: Probe = .{ .fs = .exfat };
    e.setLabelUtf16(exfatLabel(&dir).?);
    try std.testing.expectEqualStrings("USB", e.labelText());

    var long: Probe = .{};
    long.setLabel("a very long label that is cut");
    try std.testing.expectEqualStrings("a very long label", long.labelText()); // 18 chars, trailing space trimmed
    try std.testing.expectEqual(Fs.unknown, detect(&[_]u8{0} ** 100));
}
