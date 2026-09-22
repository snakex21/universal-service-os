const random_reader = @import("random_reader.zig");

pub const Error = random_reader.Error || error{
    InvalidBPB,
    UnsupportedSectorSize,
    UnsupportedClusterSize,
    UnsupportedRecordSize,
    PartitionBounds,
    InvalidMftSignature,
    InvalidIndexSignature,
    InvalidFixup,
    InvalidAttribute,
    MissingMftData,
    MissingIndexRoot,
    MissingIndexAllocation,
    RunlistBounds,
    RunlistLoop,
    RunlistTooFragmented,
    SparseMetadata,
    InvalidIndex,
    IndexLoop,
    IndexTooDeep,
    NotFound,
    NotDirectory,
    DirectoryTooLarge,
    UnsupportedName,
    NotFile,
    UnsupportedFileData,
};

pub const Partition = struct {
    start_bytes: u64,
    size_bytes: u64,
};

pub const DirectoryItem = struct {
    name: [260]u16 = [_]u16{0} ** 260,
    name_len: u16 = 0,
    file_reference: u64 = 0,
    attributes: u32 = 0,
    size: u64 = 0,
    namespace: u8 = 0,

    pub fn isDirectory(self: DirectoryItem) bool {
        return (self.attributes & 0x10000000) != 0;
    }

    pub fn copyNameAscii(self: DirectoryItem, output: []u8) usize {
        const wanted: usize = @intCast(self.name_len);
        const count = @min(wanted, output.len);
        for (0..count) |index| {
            const unit = self.name[index];
            output[index] = if (unit <= 0x7f) @intCast(unit) else '?';
        }
        return count;
    }
};

pub const DirectoryInfo = struct {
    record_number: u64,
    uses_index_allocation: bool,
    index_run_count: usize = 0,
    first_index_lcn: ?u64 = null,
};

pub const BootSectorProbe = struct {
    oem_ntfs: bool,
    boot_signature_valid: bool,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    total_sectors: u64,
    mft_lcn: u64,
    mft_mirror_lcn: u64,
    file_record_code: i8,
    index_record_code: i8,
};

pub const DirectoryPage = struct {
    count: usize,
    has_more: bool,
};

const max_runs: usize = 128;
const max_file_record_bytes: usize = 4096;
const max_index_record_bytes: usize = 16384;
const max_index_children: usize = 256;

const Run = struct {
    vcn: u64,
    lcn: i64,
    clusters: u64,
    sparse: bool,
};

const Stream = struct {
    runs: [max_runs]Run = [_]Run{.{ .vcn = 0, .lcn = 0, .clusters = 0, .sparse = false }} ** max_runs,
    len: usize = 0,
    data_size: u64 = 0,

    fn append(self: *Stream, run: Run) Error!void {
        if (self.len >= self.runs.len) return error.RunlistTooFragmented;
        if (!run.sparse) {
            const new_start: u64 = @intCast(run.lcn);
            const new_end = addU64(new_start, run.clusters) orelse return error.RunlistBounds;
            for (self.runs[0..self.len]) |existing| {
                if (existing.sparse) continue;
                const old_start: u64 = @intCast(existing.lcn);
                const old_end = addU64(old_start, existing.clusters) orelse return error.RunlistBounds;
                if (new_start < old_end and old_start < new_end) return error.RunlistLoop;
            }
        }
        self.runs[self.len] = run;
        self.len += 1;
    }
};

pub const FileSystem = struct {
    partition: Partition,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    cluster_bytes: u32,
    cluster_shift: u8,
    total_sectors: u64,
    total_clusters: u64,
    mft_lcn: u64,
    mft_mirror_lcn: u64,
    file_record_bytes: u32,
    index_record_bytes: u32,
    mft_stream: Stream,

    pub fn mftRunCount(self: FileSystem) usize {
        return self.mft_stream.len;
    }
};

pub fn probeBootSector(reader: random_reader.Reader, partition: Partition) Error!BootSectorProbe {
    if (partition.size_bytes < 512) return error.PartitionBounds;
    var boot: [512]u8 = undefined;
    try readPartition(reader, partition, 0, &boot);
    return .{
        .oem_ntfs = bytesEqual(boot[3..11], "NTFS    "),
        .boot_signature_valid = boot[510] == 0x55 and boot[511] == 0xaa,
        .bytes_per_sector = le16(boot[11..13]),
        .sectors_per_cluster = boot[13],
        .total_sectors = le64(boot[40..48]),
        .mft_lcn = le64(boot[48..56]),
        .mft_mirror_lcn = le64(boot[56..64]),
        .file_record_code = @bitCast(boot[64]),
        .index_record_code = @bitCast(boot[68]),
    };
}

pub fn mount(reader: random_reader.Reader, partition: Partition) Error!FileSystem {
    const probe = try probeBootSector(reader, partition);
    if (!probe.oem_ntfs or !probe.boot_signature_valid) return error.InvalidBPB;

    const bytes_per_sector = probe.bytes_per_sector;
    if (bytes_per_sector < 512 or bytes_per_sector > 4096 or !isPowerOfTwo(bytes_per_sector)) return error.UnsupportedSectorSize;
    const sectors_per_cluster = probe.sectors_per_cluster;
    if (sectors_per_cluster == 0 or sectors_per_cluster > 128 or !isPowerOfTwo(sectors_per_cluster)) return error.UnsupportedClusterSize;
    const cluster_bytes_u64 = mulU64(bytes_per_sector, sectors_per_cluster) orelse return error.PartitionBounds;
    if (cluster_bytes_u64 > 65536) return error.UnsupportedClusterSize;
    const cluster_bytes: u32 = @intCast(cluster_bytes_u64);
    const cluster_shift = powerOfTwoShift(cluster_bytes) orelse return error.UnsupportedClusterSize;

    const total_sectors = probe.total_sectors;
    if (total_sectors == 0) return error.InvalidBPB;
    const total_bytes = mulU64(total_sectors, bytes_per_sector) orelse return error.PartitionBounds;
    if (total_bytes > partition.size_bytes) return error.PartitionBounds;
    const sectors_per_cluster_shift = powerOfTwoShift(sectors_per_cluster) orelse return error.UnsupportedClusterSize;
    const total_clusters = shiftRightU64(total_sectors, sectors_per_cluster_shift);
    if (total_clusters == 0) return error.InvalidBPB;

    const mft_lcn = probe.mft_lcn;
    const mft_mirror_lcn = probe.mft_mirror_lcn;
    if (mft_lcn >= total_clusters or mft_mirror_lcn >= total_clusters) return error.InvalidBPB;

    const file_record_bytes = try encodedRecordBytes(probe.file_record_code, cluster_bytes);
    const index_record_bytes = try encodedRecordBytes(probe.index_record_code, cluster_bytes);
    if (file_record_bytes > max_file_record_bytes or index_record_bytes > max_index_record_bytes) return error.UnsupportedRecordSize;
    if (file_record_bytes < bytes_per_sector or index_record_bytes < bytes_per_sector) return error.UnsupportedRecordSize;
    if (file_record_bytes % bytes_per_sector != 0 or index_record_bytes % bytes_per_sector != 0) return error.UnsupportedRecordSize;

    var record_storage: [max_file_record_bytes]u8 = undefined;
    const record = record_storage[0..file_record_bytes];
    const mft_byte = mulU64(mft_lcn, cluster_bytes) orelse return error.PartitionBounds;
    try readPartition(reader, partition, mft_byte, record);
    try validateAndFixRecord(record, bytes_per_sector, "FILE", error.InvalidMftSignature);

    const mft_stream = try collectStream(record, 0x80, null, cluster_bytes, total_clusters);
    if (mft_stream.len == 0 or mft_stream.data_size < file_record_bytes) return error.MissingMftData;
    if (mft_stream.runs[0].sparse or mft_stream.runs[0].vcn != 0 or mft_stream.runs[0].lcn != @as(i64, @intCast(mft_lcn))) return error.InvalidAttribute;

    return .{
        .partition = partition,
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .cluster_bytes = cluster_bytes,
        .cluster_shift = cluster_shift,
        .total_sectors = total_sectors,
        .total_clusters = total_clusters,
        .mft_lcn = mft_lcn,
        .mft_mirror_lcn = mft_mirror_lcn,
        .file_record_bytes = file_record_bytes,
        .index_record_bytes = index_record_bytes,
        .mft_stream = mft_stream,
    };
}

pub fn listDirectory(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16, output: []DirectoryItem) Error!usize {
    const page = try listDirectoryPage(fs, reader, components, 0, output);
    if (page.has_more) return error.DirectoryTooLarge;
    return page.count;
}

pub fn listDirectoryPage(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16, skip: usize, output: []DirectoryItem) Error!DirectoryPage {
    const record_number = try resolveDirectory(fs, reader, components);
    var scan = DirectoryScan{ .output = output, .skip = skip };
    try scanDirectory(fs, reader, record_number, &scan);
    return .{ .count = scan.count, .has_more = scan.truncated };
}

pub fn directoryInfo(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16) Error!DirectoryInfo {
    const record_number = try resolveDirectory(fs, reader, components);
    var record_storage: [max_file_record_bytes]u8 = undefined;
    const record = try readMftRecord(fs, reader, record_number, &record_storage);
    if ((le16(record[22..24]) & 0x0002) == 0) return error.NotDirectory;
    const root = try findIndexRoot(record);
    if (!root.large) return .{ .record_number = record_number, .uses_index_allocation = false };
    const allocation = try collectStream(record, 0xa0, "$I30", fs.cluster_bytes, fs.total_clusters);
    if (allocation.len == 0) return error.MissingIndexAllocation;
    const first = allocation.runs[0];
    return .{
        .record_number = record_number,
        .uses_index_allocation = true,
        .index_run_count = allocation.len,
        .first_index_lcn = if (first.sparse) null else @as(u64, @intCast(first.lcn)),
    };
}

/// A read-only unnamed DATA stream. Resolve the runlist once, then reuse it
/// for large ISO reads instead of rescanning the directory/MFT for each block.
pub const File = struct {
    stream: Stream = .{},
    resident: [max_file_record_bytes]u8 = undefined,
    resident_len: ?usize = null,

    pub fn size(self: *const File) u64 {
        return if (self.resident_len) |n| n else self.stream.data_size;
    }

    pub fn readAt(self: *const File, fs: FileSystem, reader: random_reader.Reader, offset: u64, output: []u8) Error!void {
        if (offset > self.size() or output.len > self.size() - offset) return error.OutOfBounds;
        if (self.resident_len != null) {
            const start: usize = @intCast(offset);
            @memcpy(output, self.resident[start..][0..output.len]);
        } else {
            try readStream(fs, reader, self.stream, offset, output);
        }
    }
};

pub fn openFile(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16, output: *File) Error!void {
    if (components.len == 0) return error.NotFile;
    const parent = try resolveDirectory(fs, reader, components[0 .. components.len - 1]);
    const name = components[components.len - 1];
    var scan = DirectoryScan{ .wanted = name };
    try scanDirectory(fs, reader, parent, &scan);
    var reference: ?u64 = if (scan.found) |found| found.file_reference else null;
    if (reference == null) {
        for (scan.alias_refs[0..scan.alias_len]) |candidate| {
            if (try recordHasMatchingFileName(fs, reader, candidate, name)) {
                reference = candidate;
                break;
            }
        }
    }
    var record_storage: [max_file_record_bytes]u8 = undefined;
    const record = try readMftRecord(fs, reader, reference orelse return error.NotFound, &record_storage);
    if ((le16(record[22..24]) & 3) != 1) return error.NotFile;
    try fileFromRecord(record, fs.cluster_bytes, fs.total_clusters, output);
}

fn fileFromRecord(record: []const u8, cluster_bytes: u32, total_clusters: u64, result: *File) Error!void {
    result.* = .{};
    var offset: usize = le16(record[20..22]);
    const used: usize = le32(record[24..28]);
    if (offset < 24 or used > record.len) return error.InvalidAttribute;
    var found = false;
    while (offset + 16 <= used) {
        const kind = le32(record[offset..][0..4]);
        if (kind == 0xffffffff) break;
        const length: usize = le32(record[offset + 4..][0..4]);
        if (length < 24 or length > used - offset) return error.InvalidAttribute;
        const attr = record[offset..][0..length];
        // Attribute-list extensions, encryption, compression and sparse files
        // need different readers. Reject them rather than booting partial data.
        if (kind == 0x20) return error.UnsupportedFileData;
        if (kind == 0x80 and attr[9] == 0) {
            if (found or le16(attr[12..14]) != 0) return error.UnsupportedFileData;
            found = true;
            if (attr[8] == 0) {
                const n: usize = le32(attr[16..20]);
                const at: usize = le16(attr[20..22]);
                if (at < 24 or at > length or n > length - at or n > result.resident.len) return error.InvalidAttribute;
                @memcpy(result.resident[0..n], attr[at..][0..n]);
                result.resident_len = n;
            } else {
                if (length < 64 or le16(attr[34..36]) != 0 or le64(attr[56..64]) < le64(attr[48..56])) return error.UnsupportedFileData;
            }
        }
        offset += length;
    }
    if (!found) return error.NotFile;
    if (result.resident_len == null) {
        result.stream = try collectStream(record, 0x80, null, cluster_bytes, total_clusters);
        var capacity: u64 = 0;
        for (result.stream.runs[0..result.stream.len]) |run| {
            if (run.sparse) return error.UnsupportedFileData;
            capacity = addU64(capacity, mulU64(run.clusters, cluster_bytes) orelse return error.RunlistBounds) orelse return error.RunlistBounds;
        }
        if (result.stream.data_size == 0 or result.stream.data_size > capacity) return error.RunlistBounds;
    }
}

test "file reader handles fragmented extents and bounds without reading gaps" {
    const std = @import("std");
    const Fixture = struct {
        bytes: [4096]u8 = [_]u8{0xcc} ** 4096,
        reads: usize = 0,
        fn read(ctx: *anyopaque, at: u64, out: []u8) random_reader.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (at > self.bytes.len or out.len > self.bytes.len - at) return error.OutOfBounds;
            self.reads += 1;
            @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
        }
    };
    var fixture = Fixture{};
    @memset(fixture.bytes[512..1024], 0x11);
    @memset(fixture.bytes[2048..2560], 0x22);
    const reader = random_reader.Reader{ .context = &fixture, .read_fn = Fixture.read };
    var fs: FileSystem = undefined;
    fs.partition = .{ .start_bytes = 0, .size_bytes = fixture.bytes.len };
    fs.cluster_bytes = 512;
    fs.cluster_shift = 9;
    var file = File{};
    file.stream.data_size = 1024;
    try file.stream.append(.{ .vcn = 0, .lcn = 1, .clusters = 1, .sparse = false });
    try file.stream.append(.{ .vcn = 1, .lcn = 4, .clusters = 1, .sparse = false });
    var bytes: [4]u8 = undefined;
    try file.readAt(fs, reader, 510, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x11, 0x22, 0x22 }, &bytes);
    try std.testing.expectEqual(@as(usize, 2), fixture.reads);
    try std.testing.expectError(error.OutOfBounds, file.readAt(fs, reader, 1022, &bytes));
    try std.testing.expectError(error.OutOfBounds, file.readAt(fs, reader, std.math.maxInt(u64), &bytes));
    try std.testing.expectEqual(@as(usize, 2), fixture.reads);
}

test "file record rejects compressed, sparse, encrypted, uninitialized and extended data" {
    const std = @import("std");
    var record = [_]u8{0} ** 128;
    std.mem.writeInt(u16, record[20..22], 24, .little);
    std.mem.writeInt(u32, record[24..28], 104, .little);
    // The attribute begins at 32, clear of the MFT used-size field.
    std.mem.writeInt(u16, record[20..22], 32, .little);
    const attr = record[32..104];
    std.mem.writeInt(u32, attr[0..4], 0x80, .little);
    std.mem.writeInt(u32, attr[4..8], 72, .little);
    attr[8] = 1;
    std.mem.writeInt(u64, attr[24..32], 1, .little);
    std.mem.writeInt(u16, attr[32..34], 64, .little);
    std.mem.writeInt(u64, attr[48..56], 1024, .little);
    std.mem.writeInt(u64, attr[56..64], 1024, .little);
    @memcpy(attr[64..68], &[_]u8{ 0x11, 2, 1, 0 });
    var file: File = undefined;
    try fileFromRecord(&record, 512, 16, &file);
    try std.testing.expectEqual(@as(u64, 1024), file.size());
    for ([_]u16{ 1, 0x4000, 0x8000 }) |flag| {
        std.mem.writeInt(u16, attr[12..14], flag, .little);
        try std.testing.expectError(error.UnsupportedFileData, fileFromRecord(&record, 512, 16, &file));
    }
    std.mem.writeInt(u16, attr[12..14], 0, .little);
    std.mem.writeInt(u64, attr[56..64], 1023, .little);
    try std.testing.expectError(error.UnsupportedFileData, fileFromRecord(&record, 512, 16, &file));
    std.mem.writeInt(u64, attr[56..64], 1024, .little);
    std.mem.writeInt(u32, attr[0..4], 0x20, .little);
    try std.testing.expectError(error.UnsupportedFileData, fileFromRecord(&record, 512, 16, &file));
}

test "resident answer files are copied and validated without disk I/O" {
    const std = @import("std");
    var record = [_]u8{0} ** 128;
    std.mem.writeInt(u16, record[20..22], 32, .little);
    std.mem.writeInt(u32, record[24..28], 64, .little);
    const attr = record[32..64];
    std.mem.writeInt(u32, attr[0..4], 0x80, .little);
    std.mem.writeInt(u32, attr[4..8], 32, .little);
    std.mem.writeInt(u32, attr[16..20], 6, .little);
    std.mem.writeInt(u16, attr[20..22], 24, .little);
    @memcpy(attr[24..30], "<xml/>");
    var file: File = undefined;
    try fileFromRecord(&record, 512, 16, &file);
    try std.testing.expectEqual(@as(u64, 6), file.size());
    try std.testing.expectEqualStrings("<xml/>", file.resident[0..6]);
    std.mem.writeInt(u16, attr[20..22], 31, .little);
    try std.testing.expectError(error.InvalidAttribute, fileFromRecord(&record, 512, 16, &file));
}

fn resolveDirectory(fs: FileSystem, reader: random_reader.Reader, components: []const []const u16) Error!u64 {
    var current: u64 = 5;
    for (components) |component| {
        var scan = DirectoryScan{ .wanted = component };
        try scanDirectory(fs, reader, current, &scan);
        if (scan.found) |found| {
            if (!found.isDirectory()) return error.NotDirectory;
            current = found.file_reference;
            continue;
        }

        // NTFS may keep a DOS 8.3 alias as a separate namespace-2 index key.
        // Normal menu listings suppress those aliases to avoid duplicate rows,
        // but path lookup must still be able to recover the long Win32 name
        // from the referenced MFT record when an index exposes only the alias.
        var alias_index: usize = 0;
        var recovered: ?u64 = null;
        while (alias_index < scan.alias_len) : (alias_index += 1) {
            const reference = scan.alias_refs[alias_index];
            if (try recordHasMatchingFileName(fs, reader, reference, component)) {
                recovered = reference;
                break;
            }
        }
        const reference = recovered orelse return error.NotFound;
        var record_storage: [max_file_record_bytes]u8 = undefined;
        const record = try readMftRecord(fs, reader, reference, &record_storage);
        if ((le16(record[22..24]) & 0x0002) == 0) return error.NotDirectory;
        current = reference;
    }
    return current;
}

const DirectoryScan = struct {
    wanted: ?[]const u16 = null,
    output: ?[]DirectoryItem = null,
    found: ?DirectoryItem = null,
    count: usize = 0,
    skip: usize = 0,
    logical_count: usize = 0,
    truncated: bool = false,
    stop: bool = false,
    emitted_refs: [512]u64 = [_]u64{0} ** 512,
    emitted_len: usize = 0,
    children: [max_index_children]u64 = [_]u64{0} ** max_index_children,
    child_len: usize = 0,
    child_cursor: usize = 0,
    visited_children: [max_index_children]u64 = [_]u64{0} ** max_index_children,
    visited_len: usize = 0,
    alias_refs: [64]u64 = [_]u64{0} ** 64,
    alias_len: usize = 0,

    fn accept(self: *DirectoryScan, item: DirectoryItem) Error!void {
        if (self.wanted) |wanted| {
            if (nameEqualsAsciiIgnoreCase(item.name[0..item.name_len], wanted)) {
                self.found = item;
                return;
            }
            if (item.namespace == 2) try self.rememberAlias(item.file_reference);
            return;
        }
        // Namespace 2 is the DOS 8.3 alias of a Win32 name. It is valid for
        // lookup but must not appear as a second menu entry for the same file.
        if (item.namespace == 2) return;
        for (self.emitted_refs[0..self.emitted_len]) |reference| {
            if (reference == item.file_reference) return;
        }
        if (self.emitted_len >= self.emitted_refs.len) return error.DirectoryTooLarge;
        self.emitted_refs[self.emitted_len] = item.file_reference;
        self.emitted_len += 1;
        if (self.logical_count < self.skip) {
            self.logical_count += 1;
            return;
        }
        const output = self.output orelse return error.DirectoryTooLarge;
        if (self.count >= output.len) {
            self.truncated = true;
            self.stop = true;
            return;
        }
        output[self.count] = item;
        self.count += 1;
        self.logical_count += 1;
    }

    fn rememberAlias(self: *DirectoryScan, reference: u64) Error!void {
        for (self.alias_refs[0..self.alias_len]) |existing| if (existing == reference) return;
        if (self.alias_len >= self.alias_refs.len) return error.DirectoryTooLarge;
        self.alias_refs[self.alias_len] = reference;
        self.alias_len += 1;
    }

    fn addChild(self: *DirectoryScan, vcn: u64) Error!void {
        for (self.children[0..self.child_len]) |existing| if (existing == vcn) return error.IndexLoop;
        for (self.visited_children[0..self.visited_len]) |existing| if (existing == vcn) return error.IndexLoop;
        if (self.child_len >= self.children.len) return error.IndexTooDeep;
        self.children[self.child_len] = vcn;
        self.child_len += 1;
    }
};

fn scanDirectory(fs: FileSystem, reader: random_reader.Reader, record_number: u64, scan: *DirectoryScan) Error!void {
    var record_storage: [max_file_record_bytes]u8 = undefined;
    const record = try readMftRecord(fs, reader, record_number, &record_storage);
    if ((le16(record[22..24]) & 0x0002) == 0) return error.NotDirectory;

    const root = try findIndexRoot(record);
    try consumeIndexEntries(root.value, 16, scan);
    if (scan.found != null or scan.stop) return;
    if (!root.large) return;

    const allocation = try collectStream(record, 0xa0, "$I30", fs.cluster_bytes, fs.total_clusters);
    if (allocation.len == 0) return error.MissingIndexAllocation;

    while (scan.child_cursor < scan.child_len) {
        const vcn = scan.children[scan.child_cursor];
        scan.child_cursor += 1;
        for (scan.visited_children[0..scan.visited_len]) |existing| if (existing == vcn) return error.IndexLoop;
        if (scan.visited_len >= scan.visited_children.len) return error.IndexTooDeep;
        scan.visited_children[scan.visited_len] = vcn;
        scan.visited_len += 1;

        var index_storage: [max_index_record_bytes]u8 = undefined;
        const index_bytes: usize = @intCast(root.index_record_bytes);
        const index = index_storage[0..index_bytes];
        const stream_offset = mulU64(vcn, fs.cluster_bytes) orelse return error.InvalidIndex;
        try readStream(fs, reader, allocation, stream_offset, index);
        try validateAndFixRecord(index, fs.bytes_per_sector, "INDX", error.InvalidIndexSignature);
        if (le64(index[16..24]) != vcn) return error.InvalidIndex;
        try consumeIndexEntries(index, 24, scan);
        if (scan.found != null or scan.stop) return;
    }
}

const IndexRoot = struct {
    value: []const u8,
    index_record_bytes: u32,
    large: bool,
};

fn findIndexRoot(record: []const u8) Error!IndexRoot {
    var offset: usize = le16(record[20..22]);
    const used: usize = le32(record[24..28]);
    if (offset < 24 or used > record.len) return error.InvalidAttribute;
    while (offset + 16 <= used) {
        const attr_type = le32(record[offset .. offset + 4]);
        if (attr_type == 0xffffffff) break;
        const length: usize = le32(record[offset + 4 .. offset + 8]);
        if (length < 24 or offset + length > used) return error.InvalidAttribute;
        if (attr_type == 0x90 and attributeNameEquals(record[offset .. offset + length], "$I30")) {
            if (record[offset + 8] != 0) return error.InvalidAttribute;
            const value_length: usize = le32(record[offset + 16 .. offset + 20]);
            const value_offset: usize = le16(record[offset + 20 .. offset + 22]);
            if (value_offset + value_length > length or value_length < 32) return error.InvalidIndex;
            const value = record[offset + value_offset .. offset + value_offset + value_length];
            const index_record_bytes = le32(value[8..12]);
            if (index_record_bytes == 0 or index_record_bytes > max_index_record_bytes) return error.UnsupportedRecordSize;
            const entries_offset: usize = le32(value[16..20]);
            const total_size: usize = le32(value[20..24]);
            if (entries_offset < 16 or total_size < entries_offset or 16 + total_size > value.len) return error.InvalidIndex;
            return .{
                .value = value,
                .index_record_bytes = index_record_bytes,
                .large = (value[28] & 1) != 0,
            };
        }
        offset += length;
    }
    return error.MissingIndexRoot;
}

fn consumeIndexEntries(buffer: []const u8, header_offset: usize, scan: *DirectoryScan) Error!void {
    if (header_offset + 16 > buffer.len) return error.InvalidIndex;
    const entries_rel: usize = le32(buffer[header_offset .. header_offset + 4]);
    const total_size: usize = le32(buffer[header_offset + 4 .. header_offset + 8]);
    const allocated_size: usize = le32(buffer[header_offset + 8 .. header_offset + 12]);
    if (entries_rel < 16 or total_size < entries_rel or total_size > allocated_size) return error.InvalidIndex;
    const start = addUsize(header_offset, entries_rel) orelse return error.InvalidIndex;
    const end = addUsize(header_offset, total_size) orelse return error.InvalidIndex;
    if (start > end or end > buffer.len) return error.InvalidIndex;

    var offset = start;
    while (offset + 16 <= end) {
        const entry_length: usize = le16(buffer[offset + 8 .. offset + 10]);
        const key_length: usize = le16(buffer[offset + 10 .. offset + 12]);
        const flags = le16(buffer[offset + 12 .. offset + 14]);
        if (entry_length < 16 or offset + entry_length > end) return error.InvalidIndex;
        const has_child = (flags & 0x0001) != 0;
        const is_last = (flags & 0x0002) != 0;
        const child_bytes: usize = if (has_child) 8 else 0;
        if (entry_length < 16 + child_bytes) return error.InvalidIndex;

        if (!is_last) {
            if (key_length < 66 or 16 + key_length + child_bytes > entry_length) return error.InvalidIndex;
            const key = buffer[offset + 16 .. offset + 16 + key_length];
            const name_units: usize = key[64];
            const namespace = key[65];
            const name_bytes = mulUsize(name_units, 2) orelse return error.InvalidIndex;
            if (66 + name_bytes > key.len or name_units > 260) return error.InvalidIndex;
            var item = DirectoryItem{};
            item.file_reference = le64(buffer[offset .. offset + 8]) & 0x0000ffffffffffff;
            item.attributes = le32(key[56..60]);
            item.size = le64(key[48..56]);
            item.name_len = @intCast(name_units);
            item.namespace = namespace;
            for (0..name_units) |index| item.name[index] = le16(key[66 + index * 2 .. 68 + index * 2]);
            try scan.accept(item);
            if (scan.found != null or scan.stop) return;
        }

        if (has_child) {
            const child_offset = offset + entry_length - 8;
            try scan.addChild(le64(buffer[child_offset .. child_offset + 8]));
        }
        offset += entry_length;
        if (is_last) return;
    }
    return error.InvalidIndex;
}

fn recordHasMatchingFileName(fs: FileSystem, reader: random_reader.Reader, record_number: u64, wanted: []const u16) Error!bool {
    var record_storage: [max_file_record_bytes]u8 = undefined;
    const record = try readMftRecord(fs, reader, record_number, &record_storage);
    var offset: usize = le16(record[20..22]);
    const used: usize = le32(record[24..28]);
    if (offset < 24 or used > record.len) return error.InvalidAttribute;

    while (offset + 16 <= used) {
        const attr_type = le32(record[offset .. offset + 4]);
        if (attr_type == 0xffffffff) return false;
        const length: usize = le32(record[offset + 4 .. offset + 8]);
        if (length < 24 or offset + length > used) return error.InvalidAttribute;
        if (attr_type == 0x30) {
            if (record[offset + 8] != 0) return error.InvalidAttribute;
            const value_length: usize = le32(record[offset + 16 .. offset + 20]);
            const value_offset: usize = le16(record[offset + 20 .. offset + 22]);
            if (value_offset + value_length > length or value_length < 66) return error.InvalidAttribute;
            const value = record[offset + value_offset .. offset + value_offset + value_length];
            const name_units: usize = value[64];
            const name_bytes = mulUsize(name_units, 2) orelse return error.InvalidAttribute;
            if (66 + name_bytes > value.len or name_units > 260) return error.InvalidAttribute;
            if (name_units == wanted.len) {
                var matches = true;
                for (0..name_units) |index| {
                    const unit = le16(value[66 + index * 2 .. 68 + index * 2]);
                    if (unit > 0x7f or wanted[index] > 0x7f or asciiLower(@intCast(unit)) != asciiLower(@intCast(wanted[index]))) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return true;
            }
        }
        offset += length;
    }
    return false;
}

fn readMftRecord(fs: FileSystem, reader: random_reader.Reader, record_number: u64, storage: *[max_file_record_bytes]u8) Error![]u8 {
    const record_offset = mulU64(record_number, fs.file_record_bytes) orelse return error.RunlistBounds;
    const record = storage[0..fs.file_record_bytes];
    try readStream(fs, reader, fs.mft_stream, record_offset, record);
    try validateAndFixRecord(record, fs.bytes_per_sector, "FILE", error.InvalidMftSignature);
    return record;
}

fn collectStream(record: []const u8, wanted_type: u32, wanted_name: ?[]const u8, cluster_bytes: u32, total_clusters: u64) Error!Stream {
    var result = Stream{};
    var offset: usize = le16(record[20..22]);
    const used: usize = le32(record[24..28]);
    if (offset < 24 or used > record.len) return error.InvalidAttribute;
    var expected_vcn: u64 = 0;
    var saw_extent = false;

    while (offset + 16 <= used) {
        const attr_type = le32(record[offset .. offset + 4]);
        if (attr_type == 0xffffffff) break;
        const length: usize = le32(record[offset + 4 .. offset + 8]);
        if (length < 24 or offset + length > used) return error.InvalidAttribute;
        const attr = record[offset .. offset + length];
        if (attr_type == wanted_type and attributeNameMatches(attr, wanted_name)) {
            if (attr[8] == 0) return error.InvalidAttribute;
            if (length < 64) return error.InvalidAttribute;
            const low_vcn = le64(attr[16..24]);
            const high_vcn = le64(attr[24..32]);
            const mapping_offset: usize = le16(attr[32..34]);
            if (high_vcn < low_vcn or mapping_offset >= attr.len) return error.InvalidAttribute;
            if (!saw_extent) {
                if (low_vcn != 0) return error.InvalidAttribute;
                result.data_size = le64(attr[48..56]);
                expected_vcn = 0;
            }
            if (low_vcn != expected_vcn) return error.InvalidAttribute;
            const before = result.len;
            const next_vcn = try decodeRunlist(attr[mapping_offset..], low_vcn, cluster_bytes, total_clusters, &result);
            if (result.len == before or next_vcn != high_vcn + 1) return error.InvalidAttribute;
            expected_vcn = next_vcn;
            saw_extent = true;
        }
        offset += length;
    }
    return result;
}

fn decodeRunlist(bytes: []const u8, base_vcn: u64, cluster_bytes: u32, total_clusters: u64, stream: *Stream) Error!u64 {
    _ = cluster_bytes;
    var pos: usize = 0;
    var vcn = base_vcn;
    var current_lcn: i64 = 0;
    while (true) {
        if (pos >= bytes.len) return error.InvalidAttribute;
        const header = bytes[pos];
        pos += 1;
        if (header == 0) return vcn;
        const length_bytes: usize = header & 0x0f;
        const offset_bytes: usize = header >> 4;
        if (length_bytes == 0 or length_bytes > 8 or offset_bytes > 8) return error.InvalidAttribute;
        if (pos + length_bytes + offset_bytes > bytes.len) return error.InvalidAttribute;
        const clusters = readUnsigned(bytes[pos .. pos + length_bytes]);
        pos += length_bytes;
        if (clusters == 0) return error.RunlistLoop;
        const sparse = offset_bytes == 0;
        var lcn: i64 = 0;
        if (!sparse) {
            const delta = readSigned(bytes[pos .. pos + offset_bytes]);
            pos += offset_bytes;
            current_lcn = addI64(current_lcn, delta) orelse return error.RunlistBounds;
            if (current_lcn < 0) return error.RunlistBounds;
            const start: u64 = @intCast(current_lcn);
            const end = addU64(start, clusters) orelse return error.RunlistBounds;
            if (end > total_clusters) return error.RunlistBounds;
            lcn = current_lcn;
        }
        try stream.append(.{ .vcn = vcn, .lcn = lcn, .clusters = clusters, .sparse = sparse });
        vcn = addU64(vcn, clusters) orelse return error.RunlistBounds;
    }
}

fn readStream(fs: FileSystem, reader: random_reader.Reader, stream: Stream, file_offset: u64, output: []u8) Error!void {
    const end = addU64(file_offset, output.len) orelse return error.RunlistBounds;
    if (end > stream.data_size) return error.RunlistBounds;
    var remaining = output;
    var logical = file_offset;
    while (remaining.len > 0) {
        const vcn = shiftRightU64(logical, fs.cluster_shift);
        const within_cluster = logical & (@as(u64, fs.cluster_bytes) - 1);
        const run = findRun(stream, vcn) orelse return error.RunlistBounds;
        if (run.sparse) return error.SparseMetadata;
        const run_cluster_offset = vcn - run.vcn;
        const physical_cluster = addU64(@as(u64, @intCast(run.lcn)), run_cluster_offset) orelse return error.RunlistBounds;
        const physical_base = mulU64(physical_cluster, fs.cluster_bytes) orelse return error.RunlistBounds;
        const physical = addU64(physical_base, within_cluster) orelse return error.RunlistBounds;
        const run_remaining_clusters = run.clusters - run_cluster_offset;
        const run_remaining_bytes = mulU64(run_remaining_clusters, fs.cluster_bytes) orelse return error.RunlistBounds;
        const available = run_remaining_bytes - within_cluster;
        const chunk: usize = @intCast(@min(@as(u64, remaining.len), available));
        try readPartition(reader, fs.partition, physical, remaining[0..chunk]);
        remaining = remaining[chunk..];
        logical += chunk;
    }
}

fn findRun(stream: Stream, vcn: u64) ?Run {
    for (stream.runs[0..stream.len]) |run| {
        const end = addU64(run.vcn, run.clusters) orelse continue;
        if (vcn >= run.vcn and vcn < end) return run;
    }
    return null;
}

fn validateAndFixRecord(record: []u8, bytes_per_sector: u16, signature: []const u8, signature_error: Error) Error!void {
    if (record.len < 24 or signature.len != 4 or !bytesEqual(record[0..4], signature)) return signature_error;
    if (record.len % bytes_per_sector != 0) return error.InvalidFixup;
    const usa_offset: usize = le16(record[4..6]);
    const usa_count: usize = le16(record[6..8]);
    const sectors = record.len / bytes_per_sector;
    if (usa_count != sectors + 1 or usa_offset < 8 or usa_offset + usa_count * 2 > record.len) return error.InvalidFixup;
    const update_sequence = le16(record[usa_offset .. usa_offset + 2]);
    for (0..sectors) |index| {
        const trailer = (index + 1) * bytes_per_sector - 2;
        if (le16(record[trailer .. trailer + 2]) != update_sequence) return error.InvalidFixup;
        const replacement = le16(record[usa_offset + 2 + index * 2 .. usa_offset + 4 + index * 2]);
        writeLe16(record[trailer .. trailer + 2], replacement);
    }
}

fn attributeNameMatches(attr: []const u8, wanted: ?[]const u8) bool {
    const name_length: usize = attr[9];
    if (wanted == null) return name_length == 0;
    return attributeNameEquals(attr, wanted.?);
}

fn attributeNameEquals(attr: []const u8, wanted: []const u8) bool {
    const name_length: usize = attr[9];
    const name_offset: usize = le16(attr[10..12]);
    if (name_length != wanted.len or name_offset + name_length * 2 > attr.len) return false;
    for (wanted, 0..) |byte, index| {
        if (le16(attr[name_offset + index * 2 .. name_offset + index * 2 + 2]) != byte) return false;
    }
    return true;
}

fn readPartition(reader: random_reader.Reader, partition: Partition, relative: u64, output: []u8) Error!void {
    const end = addU64(relative, output.len) orelse return error.PartitionBounds;
    if (end > partition.size_bytes) return error.PartitionBounds;
    const absolute = addU64(partition.start_bytes, relative) orelse return error.PartitionBounds;
    try reader.readAt(absolute, output);
}

fn encodedRecordBytes(code: i8, cluster_bytes: u32) Error!u32 {
    if (code == 0) return error.UnsupportedRecordSize;
    if (code > 0) {
        const bytes = mulU64(@as(u64, @intCast(code)), cluster_bytes) orelse return error.UnsupportedRecordSize;
        if (bytes == 0 or bytes > 0xffffffff) return error.UnsupportedRecordSize;
        return @intCast(bytes);
    }
    const exponent: u8 = @intCast(-@as(i16, code));
    if (exponent > 31) return error.UnsupportedRecordSize;
    return @as(u32, 1) << @intCast(exponent);
}

fn nameEqualsAsciiIgnoreCase(actual: []const u16, wanted: []const u16) bool {
    if (actual.len != wanted.len) return false;
    for (actual, wanted) |a, b| {
        if (a > 0x7f or b > 0x7f) return false;
        if (asciiLower(@intCast(a)) != asciiLower(@intCast(b))) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn readUnsigned(bytes: []const u8) u64 {
    var value: u64 = 0;
    if (bytes.len > 0) value |= @as(u64, bytes[0]);
    if (bytes.len > 1) value |= @as(u64, bytes[1]) << 8;
    if (bytes.len > 2) value |= @as(u64, bytes[2]) << 16;
    if (bytes.len > 3) value |= @as(u64, bytes[3]) << 24;
    if (bytes.len > 4) value |= @as(u64, bytes[4]) << 32;
    if (bytes.len > 5) value |= @as(u64, bytes[5]) << 40;
    if (bytes.len > 6) value |= @as(u64, bytes[6]) << 48;
    if (bytes.len > 7) value |= @as(u64, bytes[7]) << 56;
    return value;
}

fn readSigned(bytes: []const u8) i64 {
    var value = readUnsigned(bytes);
    if ((bytes[bytes.len - 1] & 0x80) != 0) {
        value |= switch (bytes.len) {
            1 => 0xffffffffffffff00,
            2 => 0xffffffffffff0000,
            3 => 0xffffffffff000000,
            4 => 0xffffffff00000000,
            5 => 0xffffff0000000000,
            6 => 0xffff000000000000,
            7 => 0xff00000000000000,
            8 => 0,
            else => 0,
        };
    }
    return @bitCast(value);
}

fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn le32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn le64(bytes: []const u8) u64 {
    return @as(u64, le32(bytes[0..4])) | (@as(u64, le32(bytes[4..8])) << 32);
}

fn writeLe16(bytes: []u8, value: u16) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast(value >> 8);
}

fn bytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn powerOfTwoShift(value: anytype) ?u8 {
    if (!isPowerOfTwo(value)) return null;
    var current = value;
    var shift: u8 = 0;
    while (current > 1) : (shift += 1) current >>= 1;
    return shift;
}

fn shiftRightU64(value: u64, shift: u8) u64 {
    return switch (shift) {
        0 => value,
        1 => value >> 1,
        2 => value >> 2,
        3 => value >> 3,
        4 => value >> 4,
        5 => value >> 5,
        6 => value >> 6,
        7 => value >> 7,
        8 => value >> 8,
        9 => value >> 9,
        10 => value >> 10,
        11 => value >> 11,
        12 => value >> 12,
        13 => value >> 13,
        14 => value >> 14,
        15 => value >> 15,
        16 => value >> 16,
        else => 0,
    };
}

fn isPowerOfTwo(value: anytype) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

fn addU64(a: anytype, b: anytype) ?u64 {
    const aa: u64 = @intCast(a);
    const bb: u64 = @intCast(b);
    const result = @addWithOverflow(aa, bb);
    return if (result[1] == 0) result[0] else null;
}

fn mulU64(a: anytype, b: anytype) ?u64 {
    const aa: u64 = @intCast(a);
    const bb: u64 = @intCast(b);
    const result = @mulWithOverflow(aa, bb);
    return if (result[1] == 0) result[0] else null;
}

fn addI64(a: i64, b: i64) ?i64 {
    const result = @addWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

fn addUsize(a: usize, b: usize) ?usize {
    const result = @addWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

fn mulUsize(a: usize, b: usize) ?usize {
    const result = @mulWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

test "runlist decoder accepts fragmentation and rejects overlapping physical runs" {
    var stream = Stream{};
    const fragmented = [_]u8{
        0x11, 0x02, 0x10,
        0x11, 0x02, 0x10,
        0x00,
    };
    const next = try decodeRunlist(&fragmented, 0, 4096, 128, &stream);
    try @import("std").testing.expectEqual(@as(u64, 4), next);
    try @import("std").testing.expectEqual(@as(usize, 2), stream.len);
    try @import("std").testing.expectEqual(@as(i64, 16), stream.runs[0].lcn);
    try @import("std").testing.expectEqual(@as(i64, 32), stream.runs[1].lcn);

    var looped = Stream{};
    const overlapping = [_]u8{
        0x11, 0x02, 0x10,
        0x11, 0x02, 0xff,
        0x00,
    };
    try @import("std").testing.expectError(error.RunlistLoop, decodeRunlist(&overlapping, 0, 4096, 128, &looped));
}

test "signed mapping-pair deltas sign extend" {
    try @import("std").testing.expectEqual(@as(i64, -1), readSigned(&[_]u8{0xff}));
    try @import("std").testing.expectEqual(@as(i64, -256), readSigned(&[_]u8{ 0x00, 0xff }));
    try @import("std").testing.expectEqual(@as(i64, 0x1234), readSigned(&[_]u8{ 0x34, 0x12 }));
}
