const random_reader = @import("random_reader.zig");

pub const Error = random_reader.Error || error{
    InvalidBPB,
    UnsupportedSectorSize,
    UnsupportedClusterSize,
    UnsupportedFatLayout,
    PartitionBounds,
    InvalidCluster,
    BadCluster,
    ReservedCluster,
    BrokenClusterChain,
    ClusterChainLoop,
    FileOutsidePartition,
    FileTooLarge,
    NotFound,
    NotDirectory,
    IsDirectory,
    InvalidLFN,
    DirectoryTooLarge,
    InvalidFileRange,
};

pub const Partition = struct {
    start_bytes: u64,
    size_bytes: u64,
};

pub const FileSystem = struct {
    partition: Partition,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_count: u8,
    sectors_per_fat: u32,
    total_sectors: u32,
    first_data_sector: u32,
    cluster_count: u32,
    root_cluster: u32,
    active_fat: u8,
    volume_label: [11]u8,

    pub fn copyVolumeLabel(self: FileSystem, output: []u8) usize {
        var end: usize = self.volume_label.len;
        while (end > 0 and self.volume_label[end - 1] == ' ') end -= 1;
        const count = if (end < output.len) end else output.len;
        var i: usize = 0;
        while (i < count) : (i += 1) output[i] = self.volume_label[i];
        return count;
    }
};

pub const FileInfo = struct {
    size: u32,
    first_cluster: u32,
};

pub const ReadProgress = struct {
    context: *anyopaque,
    update_fn: *const fn (context: *anyopaque, bytes_done: usize) void,

    pub fn update(self: ReadProgress, bytes_done: usize) void {
        self.update_fn(self.context, bytes_done);
    }
};

pub const DirectoryItem = struct {
    name: [260]u16 = [_]u16{0} ** 260,
    name_len: u16 = 0,
    attributes: u8 = 0,
    first_cluster: u32 = 0,
    size: u32 = 0,

    pub fn isDirectory(self: DirectoryItem) bool {
        return (self.attributes & 0x10) != 0;
    }

    pub fn copyNameAscii(self: DirectoryItem, output: []u8) usize {
        const wanted: usize = @intCast(self.name_len);
        const count = if (wanted < output.len) wanted else output.len;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const unit = self.name[i];
            output[i] = if (unit <= 0x7F) @intCast(unit) else '?';
        }
        return count;
    }
};

const sector_bytes: u64 = 512;
const fat_eoc_min: u32 = 0x0FFFFFF8;
const fat_bad: u32 = 0x0FFFFFF7;
const fat_reserved_min: u32 = 0x0FFFFFF0;

pub fn mount(reader: random_reader.Reader, partition: Partition) Error!FileSystem {
    if (partition.size_bytes < sector_bytes) return error.PartitionBounds;
    var boot: [512]u8 = undefined;
    try readPartition(reader, partition, 0, &boot);
    if (boot[510] != 0x55 or boot[511] != 0xAA) return error.InvalidBPB;
    const bytes_per_sector = le16(boot[11..13]);
    if (bytes_per_sector != sector_bytes) return error.UnsupportedSectorSize;
    const spc = boot[13];
    if (spc == 0 or spc > 128 or (spc & (spc - 1)) != 0) return error.UnsupportedClusterSize;
    const reserved = le16(boot[14..16]);
    const fats = boot[16];
    const root_entries = le16(boot[17..19]);
    const total16 = le16(boot[19..21]);
    const fat16_size = le16(boot[22..24]);
    const total = le32(boot[32..36]);
    const fat_size = le32(boot[36..40]);
    const ext_flags = le16(boot[40..42]);
    const fs_version = le16(boot[42..44]);
    const root_cluster = le32(boot[44..48]);
    if (reserved == 0 or fats == 0 or fats > 2 or root_entries != 0 or total16 != 0 or fat16_size != 0 or total == 0 or fat_size == 0 or fs_version != 0) return error.UnsupportedFatLayout;

    var active_fat: u8 = 0;
    if ((ext_flags & 0x0080) != 0) {
        active_fat = @intCast(ext_flags & 0x000F);
        if (active_fat >= fats) return error.UnsupportedFatLayout;
    }

    const fats_sectors = mulU64(fats, fat_size) orelse return error.PartitionBounds;
    const first_data_u64 = addU64(reserved, fats_sectors) orelse return error.PartitionBounds;
    if (first_data_u64 >= total) return error.InvalidBPB;
    const data_sectors = @as(u64, total) - first_data_u64;
    const cluster_count_u64 = data_sectors / spc;
    if (cluster_count_u64 < 65525 or cluster_count_u64 > 0x0FFFFFEF) return error.UnsupportedFatLayout;
    const fat_entries = (@as(u64, fat_size) * sector_bytes) / 4;
    if (fat_entries < cluster_count_u64 + 2) return error.UnsupportedFatLayout;
    const total_bytes = mulU64(total, sector_bytes) orelse return error.PartitionBounds;
    if (total_bytes > partition.size_bytes) return error.PartitionBounds;

    const cluster_count: u32 = @intCast(cluster_count_u64);
    if (root_cluster < 2 or root_cluster > cluster_count + 1) return error.InvalidCluster;

    var label: [11]u8 = undefined;
    var i: usize = 0;
    while (i < label.len) : (i += 1) label[i] = boot[71 + i];

    return .{
        .partition = partition,
        .sectors_per_cluster = spc,
        .reserved_sectors = reserved,
        .fat_count = fats,
        .sectors_per_fat = fat_size,
        .total_sectors = total,
        .first_data_sector = @intCast(first_data_u64),
        .cluster_count = cluster_count,
        .root_cluster = root_cluster,
        .active_fat = active_fat,
        .volume_label = label,
    };
}

pub fn fileInfo(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16) Error!FileInfo {
    const entry = try findFileEntry(fs, reader, components);
    return .{ .size = entry.size, .first_cluster = entry.first_cluster };
}

pub fn readFile(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16, output: []u8) Error!usize {
    const entry = try findFileEntry(fs, reader, components);
    return readEntryData(fs, reader, entry, output);
}

pub fn readFileRange(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16, file_offset: u32, output: []u8) Error!usize {
    const entry = try findFileEntry(fs, reader, components);
    return readEntryRange(fs, reader, entry, file_offset, output, null);
}

pub fn readFileRangeProgress(
    fs: FileSystem,
    reader: random_reader.Reader,
    components: []const []const u16,
    file_offset: u32,
    output: []u8,
    progress: ReadProgress,
) Error!usize {
    const entry = try findFileEntry(fs, reader, components);
    return readEntryRange(fs, reader, entry, file_offset, output, progress);
}

// Full-file boot loads can be large. Coalesce only FAT-verified contiguous
// clusters and cache one FAT sector for this call, without changing range reads.
pub fn readFileSequentialProgress(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16, output: []u8, progress: ReadProgress) Error!usize {
    return readEntrySequential(fs, reader, try findFileEntry(fs, reader, components), output, progress);
}

const FatSectorCache = struct {
    relative: ?u64 = null,
    bytes: [512]u8 = undefined,

    fn next(self: *FatSectorCache, fs: FileSystem, reader: random_reader.Reader, cluster: u32) Error!u32 {
        try validateDataCluster(fs, cluster);
        const fat_start = @as(u64, fs.reserved_sectors) + @as(u64, fs.active_fat) * fs.sectors_per_fat;
        const offset = @as(u64, cluster) * 4;
        if (offset / 512 >= fs.sectors_per_fat) return error.PartitionBounds;
        const relative = (fat_start + offset / 512) * 512;
        if (self.relative == null or self.relative.? != relative) {
            try readPartition(reader, fs.partition, relative, &self.bytes);
            self.relative = relative;
        }
        const within: usize = @intCast(offset % 512);
        return validateNextCluster(fs, le32(self.bytes[within..][0..4]) & 0x0FFFFFFF);
    }
};

fn readEntrySequential(fs: FileSystem, reader: random_reader.Reader, entry: DirectoryEntry, output: []u8, progress: ?ReadProgress) Error!usize {
    if (entry.size > output.len) return error.FileTooLarge;
    if (entry.size == 0) return 0;
    const cluster_bytes = @as(usize, fs.sectors_per_cluster) * 512;
    if (entry.size > @as(u64, fs.cluster_count) * cluster_bytes) return error.FileOutsidePartition;
    try validateDataCluster(fs, entry.first_cluster);
    var fat_cache = FatSectorCache{};
    var cluster = entry.first_cluster;
    var traversed: u32 = 0;
    var written: usize = 0;
    // At most 127 sectors per batch (one cluster for 64-KiB clusters).
    const max_run_clusters = @max(@as(usize, 1), 127 * 512 / cluster_bytes);
    while (written < entry.size) {
        if (traversed >= fs.cluster_count) return error.ClusterChainLoop;
        const first = cluster;
        var amount = @min(cluster_bytes, entry.size - written);
        var run_clusters: usize = 1;
        var following: ?u32 = null;
        while (written + amount < entry.size) {
            const next = try fat_cache.next(fs, reader, cluster);
            if (next >= fat_eoc_min) return error.BrokenClusterChain;
            if (next == cluster) return error.ClusterChainLoop;
            if (run_clusters >= max_run_clusters or next != cluster + 1) {
                following = next;
                break;
            }
            cluster = next;
            amount += @min(cluster_bytes, entry.size - written - amount);
            run_clusters += 1;
        }
        const relative = try clusterSectorOffset(fs, first, 0);
        // The short final sector is read through a bounce buffer, just like the
        // range reader; block-only backends need not support unaligned reads.
        const full = amount / 512 * 512;
        if (full != 0) try readPartition(reader, fs.partition, relative, output[written..][0..full]);
        if (full != amount) {
            var tail: [512]u8 = undefined;
            try readPartition(reader, fs.partition, relative + full, &tail);
            @memcpy(output[written + full ..][0 .. amount - full], tail[0 .. amount - full]);
        }
        written += amount;
        traversed += @intCast(run_clusters);
        if (progress) |sink| sink.update(written);
        if (following) |next| cluster = next;
    }
    return written;
}

fn findFileEntry(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16) Error!DirectoryEntry {
    if (components.len == 0) return error.NotFound;
    var directory_cluster = fs.root_cluster;
    var index: usize = 0;
    while (index < components.len) : (index += 1) {
        const entry = try findEntry(fs, reader, directory_cluster, components[index]);
        const final = index + 1 == components.len;
        if (!final) {
            if ((entry.attributes & 0x10) == 0) return error.NotDirectory;
            try validateDataCluster(fs, entry.first_cluster);
            directory_cluster = entry.first_cluster;
            continue;
        }
        if ((entry.attributes & 0x10) != 0) return error.IsDirectory;
        return entry;
    }
    return error.NotFound;
}

pub fn listDirectory(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16, output: []DirectoryItem) Error!usize {
    var directory_cluster = fs.root_cluster;
    for (components) |component| {
        const entry = try findEntry(fs, reader, directory_cluster, component);
        if ((entry.attributes & 0x10) == 0) return error.NotDirectory;
        try validateDataCluster(fs, entry.first_cluster);
        directory_cluster = entry.first_cluster;
    }
    return readDirectory(fs, reader, directory_cluster, output);
}

const DirectoryEntry = struct {
    attributes: u8,
    first_cluster: u32,
    size: u32,
};

const LfnState = struct {
    active: bool = false,
    complete_to_one: bool = false,
    expected_next: u8 = 0,
    checksum: u8 = 0,
    units: [260]u16 = [_]u16{0xFFFF} ** 260,

    fn reset(self: *LfnState) void {
        self.* = .{};
    }
};

fn readDirectory(fs: FileSystem, reader: random_reader.Reader, first_cluster: u32, output: []DirectoryItem) Error!usize {
    try validateDataCluster(fs, first_cluster);
    var cluster = first_cluster;
    var visited: u32 = 0;
    var lfn = LfnState{};
    var count: usize = 0;
    while (true) {
        if (visited >= fs.cluster_count) return error.ClusterChainLoop;
        visited += 1;
        var sector_in_cluster: u32 = 0;
        while (sector_in_cluster < fs.sectors_per_cluster) : (sector_in_cluster += 1) {
            var sector: [512]u8 = undefined;
            const relative = try clusterSectorOffset(fs, cluster, sector_in_cluster);
            try readPartition(reader, fs.partition, relative, &sector);
            var entry_index: usize = 0;
            while (entry_index < 16) : (entry_index += 1) {
                const raw = sector[entry_index * 32 .. entry_index * 32 + 32];
                if (raw[0] == 0x00) return count;
                if (raw[0] == 0xE5) {
                    lfn.reset();
                    continue;
                }
                const attr = raw[11];
                if (attr == 0x0F) {
                    try consumeLfn(&lfn, raw);
                    continue;
                }
                if ((attr & 0x08) != 0) {
                    lfn.reset();
                    continue;
                }
                if (isDotEntry(raw[0..11])) {
                    lfn.reset();
                    continue;
                }
                if (count >= output.len) return error.DirectoryTooLarge;
                var item = DirectoryItem{};
                item.attributes = attr;
                item.first_cluster = (@as(u32, le16(raw[20..22])) << 16) | le16(raw[26..28]);
                item.size = le32(raw[28..32]);
                if (lfn.active and lfn.complete_to_one and shortChecksum(raw[0..11]) == lfn.checksum) {
                    item.name_len = @intCast(copyLongName(&lfn, &item.name));
                } else {
                    item.name_len = @intCast(copyShortName(raw[0..11], &item.name));
                }
                lfn.reset();
                output[count] = item;
                count += 1;
            }
        }
        cluster = try nextCluster(fs, reader, cluster);
        if (cluster >= fat_eoc_min) return count;
    }
}

fn copyLongName(state: *const LfnState, output: []u16) usize {
    var length: usize = 0;
    while (length < state.units.len and state.units[length] != 0 and state.units[length] != 0xFFFF) : (length += 1) {}
    const count = if (length < output.len) length else output.len;
    var i: usize = 0;
    while (i < count) : (i += 1) output[i] = state.units[i];
    return count;
}

fn copyShortName(short: []const u8, output: []u16) usize {
    var stem_end: usize = 8;
    while (stem_end > 0 and short[stem_end - 1] == ' ') stem_end -= 1;
    var ext_end: usize = 11;
    while (ext_end > 8 and short[ext_end - 1] == ' ') ext_end -= 1;
    var count: usize = 0;
    var i: usize = 0;
    while (i < stem_end and count < output.len) : (i += 1) {
        output[count] = if (i == 0 and short[i] == 0x05) 0x00E5 else short[i];
        count += 1;
    }
    if (ext_end > 8 and count < output.len) {
        output[count] = '.';
        count += 1;
        i = 8;
        while (i < ext_end and count < output.len) : (i += 1) {
            output[count] = short[i];
            count += 1;
        }
    }
    return count;
}

fn isDotEntry(short: []const u8) bool {
    if (short.len < 11 or short[0] != '.') return false;
    if (short[1] == ' ') return true;
    return short[1] == '.' and short[2] == ' ';
}

fn findEntry(fs: FileSystem, reader: random_reader.Reader, first_cluster: u32, wanted: []const u16) Error!DirectoryEntry {
    try validateDataCluster(fs, first_cluster);
    var cluster = first_cluster;
    var visited: u32 = 0;
    var lfn = LfnState{};
    while (true) {
        if (visited >= fs.cluster_count) return error.ClusterChainLoop;
        visited += 1;
        var sector_in_cluster: u32 = 0;
        while (sector_in_cluster < fs.sectors_per_cluster) : (sector_in_cluster += 1) {
            var sector: [512]u8 = undefined;
            const relative = try clusterSectorOffset(fs, cluster, sector_in_cluster);
            try readPartition(reader, fs.partition, relative, &sector);
            var entry_index: usize = 0;
            while (entry_index < 16) : (entry_index += 1) {
                const raw = sector[entry_index * 32 .. entry_index * 32 + 32];
                if (raw[0] == 0x00) return error.NotFound;
                if (raw[0] == 0xE5) {
                    lfn.reset();
                    continue;
                }
                const attr = raw[11];
                if (attr == 0x0F) {
                    try consumeLfn(&lfn, raw);
                    continue;
                }
                if ((attr & 0x08) != 0) {
                    lfn.reset();
                    continue;
                }
                const matched = if (lfn.active and lfn.complete_to_one and shortChecksum(raw[0..11]) == lfn.checksum)
                    longNameMatches(&lfn, wanted)
                else
                    shortNameMatches(raw[0..11], wanted);
                lfn.reset();
                if (!matched) continue;
                const first = (@as(u32, le16(raw[20..22])) << 16) | le16(raw[26..28]);
                return .{ .attributes = attr, .first_cluster = first, .size = le32(raw[28..32]) };
            }
        }
        cluster = try nextCluster(fs, reader, cluster);
        if (cluster >= fat_eoc_min) return error.NotFound;
    }
}

fn consumeLfn(state: *LfnState, raw: []const u8) Error!void {
    if (raw[12] != 0 or le16(raw[26..28]) != 0) return error.InvalidLFN;
    const sequence = raw[0];
    const ordinal = sequence & 0x1F;
    const is_last = (sequence & 0x40) != 0;
    if (ordinal == 0 or ordinal > 20) return error.InvalidLFN;
    if (is_last) {
        state.reset();
        state.active = true;
        state.expected_next = ordinal;
        state.checksum = raw[13];
    } else {
        if (!state.active or state.expected_next <= 1 or ordinal != state.expected_next - 1 or raw[13] != state.checksum) return error.InvalidLFN;
        state.expected_next = ordinal;
    }
    const base = (@as(usize, ordinal) - 1) * 13;
    const positions = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    var i: usize = 0;
    while (i < positions.len) : (i += 1) state.units[base + i] = le16(raw[positions[i] .. positions[i] + 2]);
    if (ordinal == 1) state.complete_to_one = true;
}

fn longNameMatches(state: *const LfnState, wanted: []const u16) bool {
    var length: usize = 0;
    while (length < state.units.len and state.units[length] != 0 and state.units[length] != 0xFFFF) : (length += 1) {}
    if (length != wanted.len) return false;
    var i: usize = 0;
    while (i < length) : (i += 1) if (foldAsciiU16(state.units[i]) != foldAsciiU16(wanted[i])) return false;
    return true;
}

fn shortNameMatches(short: []const u8, wanted: []const u16) bool {
    var canonical: [11]u8 = [_]u8{' '} ** 11;
    var dot: ?usize = null;
    var i: usize = 0;
    while (i < wanted.len) : (i += 1) {
        if (wanted[i] > 0x7F) return false;
        if (wanted[i] == '.') {
            if (dot != null) return false;
            dot = i;
        }
    }
    const stem_len = dot orelse wanted.len;
    const ext_start = if (dot) |d| d + 1 else wanted.len;
    const ext_len = wanted.len - ext_start;
    if (stem_len == 0 or stem_len > 8 or ext_len > 3) return false;
    i = 0;
    while (i < stem_len) : (i += 1) canonical[i] = upperAscii(@intCast(wanted[i]));
    i = 0;
    while (i < ext_len) : (i += 1) canonical[8 + i] = upperAscii(@intCast(wanted[ext_start + i]));
    return bytesEqual(short, &canonical);
}

fn readEntryData(fs: FileSystem, reader: random_reader.Reader, entry: DirectoryEntry, output: []u8) Error!usize {
    if (entry.size > output.len) return error.FileTooLarge;
    return readEntryRange(fs, reader, entry, 0, output[0..entry.size], null);
}

fn readEntryRange(fs: FileSystem, reader: random_reader.Reader, entry: DirectoryEntry, file_offset: u32, output: []u8, progress: ?ReadProgress) Error!usize {
    if (file_offset > entry.size) return error.InvalidFileRange;
    if (output.len == 0 or file_offset == entry.size) return 0;

    const cluster_bytes_u32 = @as(u32, fs.sectors_per_cluster) * 512;
    const cluster_bytes = @as(u64, cluster_bytes_u32);
    const max_file_bytes = mulU64(fs.cluster_count, cluster_bytes) orelse return error.FileOutsidePartition;
    if (entry.size > max_file_bytes) return error.FileOutsidePartition;
    try validateDataCluster(fs, entry.first_cluster);

    const available = entry.size - file_offset;
    const wanted: usize = @min(output.len, @as(usize, available));
    if (wanted == 0) return 0;

    var cluster = entry.first_cluster;
    var traversed: u32 = 0;
    var skip_clusters: u32 = file_offset / cluster_bytes_u32;
    while (skip_clusters > 0) : (skip_clusters -= 1) {
        if (traversed >= fs.cluster_count) return error.ClusterChainLoop;
        const next = try nextCluster(fs, reader, cluster);
        if (next >= fat_eoc_min) return error.BrokenClusterChain;
        if (next == cluster) return error.ClusterChainLoop;
        cluster = next;
        traversed += 1;
    }

    var offset_in_cluster: u32 = file_offset % cluster_bytes_u32;
    var written: usize = 0;
    while (written < wanted) {
        if (traversed >= fs.cluster_count) return error.ClusterChainLoop;
        var sector_in_cluster: u32 = offset_in_cluster / 512;
        var within_sector: usize = @intCast(offset_in_cluster % 512);
        while (sector_in_cluster < fs.sectors_per_cluster and written < wanted) {
            const remaining = wanted - written;
            if (within_sector == 0 and remaining >= 512) {
                const sectors_left = @as(u32, fs.sectors_per_cluster) - sector_in_cluster;
                const full_sectors: u32 = @intCast(@min(@as(usize, sectors_left), remaining / 512));
                if (full_sectors > 0) {
                    const amount = @as(usize, full_sectors) * 512;
                    const relative = try clusterSectorOffset(fs, cluster, sector_in_cluster);
                    try readPartition(reader, fs.partition, relative, output[written .. written + amount]);
                    written += amount;
                    if (progress) |sink| sink.update(written);
                    sector_in_cluster += full_sectors;
                    continue;
                }
            }

            var sector: [512]u8 = undefined;
            const relative = try clusterSectorOffset(fs, cluster, sector_in_cluster);
            try readPartition(reader, fs.partition, relative, &sector);
            const sector_available = 512 - within_sector;
            const amount = @min(sector_available, remaining);
            var i: usize = 0;
            while (i < amount) : (i += 1) output[written + i] = sector[within_sector + i];
            written += amount;
            if (progress) |sink| sink.update(written);
            within_sector = 0;
            sector_in_cluster += 1;
        }
        if (written == wanted) break;
        const next = try nextCluster(fs, reader, cluster);
        if (next >= fat_eoc_min) return error.BrokenClusterChain;
        if (next == cluster) return error.ClusterChainLoop;
        cluster = next;
        traversed += 1;
        offset_in_cluster = 0;
    }
    return written;
}

fn nextCluster(fs: FileSystem, reader: random_reader.Reader, cluster: u32) Error!u32 {
    try validateDataCluster(fs, cluster);
    const fat_sector_start = @as(u64, fs.reserved_sectors) + @as(u64, fs.active_fat) * fs.sectors_per_fat;
    const entry_relative = addU64(fat_sector_start * sector_bytes, @as(u64, cluster) * 4) orelse return error.PartitionBounds;
    var raw: [4]u8 = undefined;
    try readPartition(reader, fs.partition, entry_relative, &raw);
    return validateNextCluster(fs, le32(&raw) & 0x0FFFFFFF);
}

fn validateNextCluster(fs: FileSystem, value: u32) Error!u32 {
    if (value >= fat_eoc_min) return value;
    if (value == fat_bad) return error.BadCluster;
    if (value >= fat_reserved_min) return error.ReservedCluster;
    if (value < 2) return error.BrokenClusterChain;
    try validateDataCluster(fs, value);
    return value;
}

const SequentialTestReader = struct {
    fat: [1024]u8 = [_]u8{0} ** 1024,
    spc: u8 = 8,
    reads: usize = 0,
    fat_reads: usize = 0,
    fail_after: ?usize = null,
    last_progress: usize = 0,
    progress_calls: usize = 0,

    fn filesystem(self: *const SequentialTestReader) FileSystem {
        return .{
            .partition = .{ .start_bytes = 0, .size_bytes = (5 + @as(u64, 160) * self.spc) * 512 },
            .sectors_per_cluster = self.spc, .reserved_sectors = 1,
            .fat_count = 2, .sectors_per_fat = 2, .total_sectors = 5 + @as(u32, 160) * self.spc,
            .first_data_sector = 5, .cluster_count = 160, .root_cluster = 2,
            .active_fat = 1, .volume_label = "TEST       ".*,
        };
    }
    fn link(self: *SequentialTestReader, cluster: u32, next: u32) void {
        const std = @import("std");
        std.mem.writeInt(u32, self.fat[cluster * 4 ..][0..4], next, .little);
    }
    fn reader(self: *SequentialTestReader) random_reader.Reader {
        return .{ .context = self, .read_fn = read };
    }
    fn read(context: *anyopaque, offset: u64, out: []u8) random_reader.Error!void {
        const self: *SequentialTestReader = @ptrCast(@alignCast(context));
        if (self.fail_after) |limit| if (self.reads >= limit) return error.Io;
        self.reads += 1;
        if (offset >= 3 * 512 and offset + out.len <= 5 * 512) {
            self.fat_reads += 1;
            const pos: usize = @intCast(offset - 3 * 512);
            @memcpy(out, self.fat[pos..][0..out.len]);
            return;
        }
        const fs = self.filesystem();
        if (offset < 5 * 512 or offset + out.len > fs.partition.size_bytes) return error.OutOfBounds;
        if (offset % 512 != 0 or out.len % 512 != 0 or out.len > 65536) return error.Io;
        for (out, 0..) |*byte, i| {
            const relative = offset + i - 5 * 512;
            // Both cluster identity and position matter, including the tail.
            byte.* = @truncate(relative / (@as(u64, self.spc) * 512) * 31 + relative % 251);
        }
    }
    fn progress(context: *anyopaque, done: usize) void {
        const self: *SequentialTestReader = @ptrCast(@alignCast(context));
        @import("std").debug.assert(done > self.last_progress);
        self.last_progress = done;
        self.progress_calls += 1;
    }
};

test "sequential boot read batches contiguous clusters across FAT sectors and preserves every byte" {
    const std = @import("std");
    var fixture = SequentialTestReader{};
    var cluster: u32 = 120;
    while (cluster < 154) : (cluster += 1) fixture.link(cluster, cluster + 1);
    fixture.link(154, fat_eoc_min);
    const entry = DirectoryEntry{ .attributes = 0x20, .first_cluster = 120, .size = 34 * 4096 + 13 };
    const expected = try std.testing.allocator.alloc(u8, entry.size);
    defer std.testing.allocator.free(expected);
    const actual = try std.testing.allocator.alloc(u8, entry.size);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqual(expected.len, try readEntryRange(fixture.filesystem(), fixture.reader(), entry, 0, expected, null));
    const old_reads = fixture.reads;
    fixture.reads = 0; fixture.fat_reads = 0;
    try std.testing.expectEqual(actual.len, try readEntrySequential(fixture.filesystem(), fixture.reader(), entry, actual, .{ .context = &fixture, .update_fn = SequentialTestReader.progress }));
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expect(fixture.reads * 4 < old_reads);
    try std.testing.expectEqual(@as(usize, 2), fixture.fat_reads);
    try std.testing.expectEqual(actual.len, fixture.last_progress);
    try std.testing.expect(fixture.progress_calls > 1);
}

test "sequential read follows fragmented chains and bounds the final partial sector" {
    const std = @import("std");
    var fixture = SequentialTestReader{};
    const clusters = [_]u32{ 3, 4, 19, 20, 9 };
    for (clusters, 0..) |cluster, i| fixture.link(cluster, if (i + 1 < clusters.len) clusters[i + 1] else fat_eoc_min);
    const entry = DirectoryEntry{ .attributes = 0x20, .first_cluster = 3, .size = 4 * 4096 + 537 };
    var expected: [4 * 4096 + 537]u8 = undefined;
    var actual = [_]u8{0xA5} ** (expected.len + 8);
    _ = try readEntryRange(fixture.filesystem(), fixture.reader(), entry, 0, &expected, null);
    try std.testing.expectEqual(expected.len, try readEntrySequential(fixture.filesystem(), fixture.reader(), entry, &actual, null));
    try std.testing.expectEqualSlices(u8, &expected, actual[0..expected.len]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xA5} ** 8), actual[expected.len..]);
}

test "sequential boot read rejects invalid FAT links and propagates read failures" {
    const std = @import("std");
    const cases = .{
        .{ @as(u32, 0), error.BrokenClusterChain }, .{ fat_eoc_min, error.BrokenClusterChain },
        .{ fat_bad, error.BadCluster }, .{ fat_reserved_min, error.ReservedCluster },
        .{ @as(u32, 162), error.InvalidCluster }, .{ @as(u32, 3), error.ClusterChainLoop },
    };
    inline for (cases) |case| {
        var fixture = SequentialTestReader{};
        fixture.link(3, case[0]);
        var output: [8192]u8 = undefined;
        try std.testing.expectError(case[1], readEntrySequential(fixture.filesystem(), fixture.reader(), .{ .attributes = 0x20, .first_cluster = 3, .size = output.len }, &output, null));
    }
    var fixture = SequentialTestReader{ .fail_after = 1 };
    fixture.link(3, 4);
    var output: [8192]u8 = undefined;
    try std.testing.expectError(error.Io, readEntrySequential(fixture.filesystem(), fixture.reader(), .{ .attributes = 0x20, .first_cluster = 3, .size = output.len }, &output, null));
}

test "sequential boot read handles 64 KiB clusters and validates output size" {
    const std = @import("std");
    var fixture = SequentialTestReader{ .spc = 128 };
    fixture.link(3, 4);
    var output: [65536 + 1]u8 = undefined;
    const entry = DirectoryEntry{ .attributes = 0x20, .first_cluster = 3, .size = output.len };
    try std.testing.expectEqual(output.len, try readEntrySequential(fixture.filesystem(), fixture.reader(), entry, &output, null));
    try std.testing.expectError(error.FileTooLarge, readEntrySequential(fixture.filesystem(), fixture.reader(), entry, output[0..1], null));
    try std.testing.expectEqual(@as(usize, 0), try readEntrySequential(fixture.filesystem(), fixture.reader(), .{ .attributes = 0x20, .first_cluster = 0, .size = 0 }, &output, null));
}

fn clusterSectorOffset(fs: FileSystem, cluster: u32, sector_in_cluster: u32) Error!u64 {
    try validateDataCluster(fs, cluster);
    if (sector_in_cluster >= fs.sectors_per_cluster) return error.InvalidCluster;
    const cluster_index = @as(u64, cluster - 2);
    const data_sector = addU64(fs.first_data_sector, cluster_index * fs.sectors_per_cluster + sector_in_cluster) orelse return error.PartitionBounds;
    if (data_sector >= fs.total_sectors) return error.FileOutsidePartition;
    return mulU64(data_sector, sector_bytes) orelse error.PartitionBounds;
}

fn validateDataCluster(fs: FileSystem, cluster: u32) Error!void {
    if (cluster < 2 or cluster > fs.cluster_count + 1) return error.InvalidCluster;
}

fn readPartition(reader: random_reader.Reader, partition: Partition, relative: u64, output: []u8) Error!void {
    const end = addU64(relative, output.len) orelse return error.PartitionBounds;
    if (end > partition.size_bytes) return error.PartitionBounds;
    const absolute = addU64(partition.start_bytes, relative) orelse return error.PartitionBounds;
    try reader.readAt(absolute, output);
}

fn shortChecksum(short: []const u8) u8 {
    var sum: u8 = 0;
    for (short[0..11]) |value| sum = @as(u8, @truncate((@as(u16, sum) >> 1) | (@as(u16, sum) << 7))) +% value;
    return sum;
}
fn foldAsciiU16(value: u16) u16 {
    if (value >= 'a' and value <= 'z') return value - ('a' - 'A');
    return value;
}
fn upperAscii(value: u8) u8 {
    if (value >= 'a' and value <= 'z') return value - ('a' - 'A');
    return value;
}
fn le16(data: []const u8) u16 {
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}
fn le32(data: []const u8) u32 {
    return @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 24);
}
fn mulU64(a: anytype, b: anytype) ?u64 {
    const result = @mulWithOverflow(@as(u64, @intCast(a)), @as(u64, @intCast(b)));
    return if (result[1] == 0) result[0] else null;
}
fn addU64(a: anytype, b: anytype) ?u64 {
    const result = @addWithOverflow(@as(u64, @intCast(a)), @as(u64, @intCast(b)));
    return if (result[1] == 0) result[0] else null;
}
fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| if (av != bv) return false;
    return true;
}

test "FAT32 volume label is trimmed only on the right" {
    const std = @import("std");
    const fs = FileSystem{
        .partition = .{ .start_bytes = 0, .size_bytes = 512 },
        .sectors_per_cluster = 1,
        .reserved_sectors = 1,
        .fat_count = 1,
        .sectors_per_fat = 1,
        .total_sectors = 1,
        .first_data_sector = 1,
        .cluster_count = 65525,
        .root_cluster = 2,
        .active_fat = 0,
        .volume_label = .{ 'U', 'S', 'O', 'S', '_', 'E', 'S', 'P', ' ', ' ', ' ' },
    };
    var out: [11]u8 = undefined;
    const length = fs.copyVolumeLabel(&out);
    try std.testing.expectEqualStrings("USOS_ESP", out[0..length]);
}

test "FAT32 short-name matching is ASCII case insensitive but exact" {
    const std = @import("std");
    const short = [_]u8{ 'U', 'S', 'O', 'S', ' ', ' ', ' ', ' ', 'I', 'N', 'I' };
    const good = [_]u16{ 'u', 's', 'o', 's', '.', 'i', 'n', 'i' };
    const bad = [_]u16{ 'u', 's', 'o', 's', '-', 'm', 'e', 'n', 'u', '.', 'i', 'n', 'i' };
    try std.testing.expect(shortNameMatches(&short, &good));
    try std.testing.expect(!shortNameMatches(&short, &bad));
}
