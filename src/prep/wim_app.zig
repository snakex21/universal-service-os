//! Apply one explicitly selected WIM image onto a freshly formatted target.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const identity = @import("identity.zig");
const ntfs = @import("ntfs.zig");
const app = @import("app.zig");
const wim = @import("wim.zig");
const meta = @import("wim_metadata.zig");
const xml = @import("wim_xml.zig");
const reparse = @import("wim_reparse.zig");
const ea = @import("ea.zig");
const progress = @import("progress.zig");
const ApplyProgress = struct {
    reporter: progress.Reporter,
    items: u64 = 0,
    total: u64,
    bytes: u64 = 0,
    resources: u64 = 0,
    fn chunk(ctx: *anyopaque, update: platform.ProgressUpdate) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.reporter.report(.{ .current = self.items, .total = self.total, .bytes = self.bytes + update.bytes, .resources = self.resources });
    }
    fn emit(self: *@This()) void {
        self.reporter.report(.{ .current = self.items, .total = self.total, .bytes = self.bytes, .resources = self.resources });
    }
};
// Windows7 WIMs can reuse a groupID for unrelated files. Public wimlib
// v1.14.5 inode_fixup.c resolves identity using ID + unnamed DATA hash.
const LinkKey = struct { group: u64, data_sha1: [20]u8 };
const Hardlink = struct { record: u64, fingerprint: [20]u8 };
const TagCount = struct { tag: u32, entries: u64 = 0, applied: u64 = 0 };
const Context = struct {
    archive: *wim.Archive,
    metadata: *meta.Metadata,
    allocator: std.mem.Allocator,
    log: app.Logger,
    fs: ?*ntfs.Ntfs = null,
    security_ids: []u32,
    links: std.AutoHashMap(LinkKey, Hardlink),
    files: u64 = 0,
    directories: u64 = 0,
    short_names: u64 = 0,
    secondary_short_names_normalized: u64 = 0,
    hardlink_names: u64 = 0,
    reparse_points: u64 = 0,
    ads: u64 = 0,
    tagged_items: u64 = 0,
    target_drive: u8 = 'C',
    reparse_fixed: u64 = 0,
    rpfix_eligible_unmatched: u64 = 0,
    strict_rpfix: bool = true,
    path: std.ArrayList(u16) = .empty,
    path_len: usize = 0,
    path_starts: [130]usize = undefined,
    path_depth: usize = 0,
    tag_counts: std.ArrayList(TagCount) = .empty,
    preflight_progress: ?*progress.Reporter = null,
    apply_progress: ?*ApplyProgress = null,
    fn trackResource(self: *Context, resource: *wim.Resource) void {
        if (self.apply_progress) |state| resource.progress = .{ .context = state, .report_fn = ApplyProgress.chunk };
    }
    fn resourceDone(self: *Context, resource: *const wim.Resource) !void {
        if (!resource.verified) return error.IncompleteWimRead;
        if (self.apply_progress) |state| {
            state.bytes += resource.descriptor.size;
            state.resources += 1;
            state.emit();
        }
    }
    fn tagged(self: *Context, item: *const meta.Entry, record: ?u64) !void {
        var cursor = item.tagged_offset;
        while (cursor < item.extra_offset) {
            const tag = try self.metadata.readTagged(cursor, item.extra_offset);
            cursor = tag.next;
            if (tag.tag == 0 and tag.bytes == 0) continue;
            var count: ?*TagCount = null;
            for (self.tag_counts.items) |*current| if (current.tag == tag.tag) {
                count = current;
                break;
            };
            if (count == null) {
                if (self.tag_counts.items.len >= 256) return error.TaggedTypeBudgetExceeded;
                try self.tag_counts.append(self.allocator, .{ .tag = tag.tag });
                count = &self.tag_counts.items[self.tag_counts.items.len - 1];
            }
            if (record == null) count.?.entries += 1;
            if (tag.tag == 1) {
                var raw: [64]u8 = @splat(0);
                if (tag.bytes < 16 or tag.bytes > 64 or tag.bytes % 16 != 0) return error.UnsupportedObjectId;
                try self.metadata.resource.read(tag.data_offset, raw[0..tag.bytes]);
                if (std.mem.allEqual(u8, raw[0..16], 0)) return error.InvalidObjectId;
                if (record) |number| {
                    try self.fs.?.setObjectId(number, raw[0..tag.bytes]);
                    count.?.applied += 1;
                }
            } else if (tag.tag == 2) {
                if (tag.bytes == 0 or tag.bytes > 65535) return error.UnsupportedExtendedAttributes;
                const raw = try self.allocator.alloc(u8, tag.bytes);
                defer self.allocator.free(raw);
                try self.metadata.resource.read(tag.data_offset, raw);
                const native = try ea.fromWim(self.allocator, raw);
                defer self.allocator.free(native);
                if (record) |number| {
                    try self.fs.?.setExtendedAttributes(number, native);
                    count.?.applied += 1;
                }
            }
        }
    }
    fn readReparse(self: *Context, item: *const meta.Entry, hash: [20]u8) ![]u8 {
        var resource = try self.archive.openEntry(try self.archive.find(hash));
        defer resource.deinit();
        self.trackResource(&resource);
        if (resource.descriptor.size > 16376) return error.UnsupportedReparseSize;
        const raw = try self.allocator.alloc(u8, @intCast(8 + resource.descriptor.size));
        errdefer self.allocator.free(raw);
        std.mem.writeInt(u32, raw[0..4], item.reparse_tag, .little);
        std.mem.writeInt(u16, raw[4..6], @intCast(resource.descriptor.size), .little);
        std.mem.writeInt(u16, raw[6..8], item.reparse_reserved, .little);
        try resource.readSequential(0, raw[8..]);
        try self.resourceDone(&resource);
        switch (try reparse.fixDetailed(raw, self.archive.header.flags, item.reparse_flags, self.target_drive)) {
            .fixed => self.reparse_fixed += 1,
            .ignored => {},
            .eligible_unmatched => {
                // Count/report the preflight inventory exactly once. A lax
                // apply visits the same entry again, but does not double it.
                if (self.fs == null) {
                    self.rpfix_eligible_unmatched += 1;
                    const path_text = try self.allocator.alloc(u8, self.path_len * 3);
                    defer self.allocator.free(path_text);
                    const path_len = try std.unicode.utf16LeToUtf8(path_text, self.path.items);
                    const target_text = try self.allocator.alloc(u8, raw.len * 3);
                    defer self.allocator.free(target_text);
                    const target = try reparse.substituteUtf8(raw, target_text);
                    // Logger.say has a 1024-byte formatting buffer; paths may
                    // be much longer. Stream these already bounded strings
                    // directly, keeping the full offending path and target.
                    self.log.write_fn(self.log.context, "WIM_RPFIX_ELIGIBLE_UNMATCHED path=\"");
                    self.log.write_fn(self.log.context, path_text[0..path_len]);
                    self.log.write_fn(self.log.context, "\" target=\"");
                    self.log.write_fn(self.log.context, target);
                    self.log.say("\" strict={any}\n", .{self.strict_rpfix});
                }
            },
        }
        return raw;
    }
    fn linkKey(self: *Context, item: *const meta.Entry) !?LinkKey {
        if (item.isDirectory() or item.isReparse() or item.link_group == 0) return null;
        var streams = meta.StreamIterator.init(self.metadata, item.*);
        while (try streams.next()) |stream| if (stream.kind == .data)
            return .{ .group = item.link_group, .data_sha1 = stream.hash };
        return .{ .group = item.link_group, .data_sha1 = @splat(0) };
    }
    fn options(self: *Context, item: *const meta.Entry) ntfs.FileOptions {
        return .{ .attributes = item.attributes, .security_id = if (item.security == 0xffffffff) null else self.security_ids[item.security], .times = .{ .created = item.times.created, .modified = item.times.modified, .changed = item.times.modified, .accessed = item.times.accessed }, .sparse = item.attributes & 0x200 != 0 };
    }
    fn fingerprint(self: *Context, item: *const meta.Entry) ![20]u8 {
        var sha = std.crypto.hash.Sha1.init(.{});
        var fixed: [32]u8 = undefined;
        std.mem.writeInt(u32, fixed[0..4], item.attributes, .little);
        std.mem.writeInt(u32, fixed[4..8], item.security, .little);
        std.mem.writeInt(u64, fixed[8..16], item.times.created, .little);
        std.mem.writeInt(u64, fixed[16..24], item.times.modified, .little);
        std.mem.writeInt(u64, fixed[24..32], item.times.accessed, .little);
        sha.update(&fixed);
        var streams = meta.StreamIterator.init(self.metadata, item.*);
        while (try streams.next()) |stream| {
            fixed[0] = @intFromEnum(stream.kind);
            sha.update(fixed[0..1]);
            sha.update(&stream.hash);
            std.mem.writeInt(u16, fixed[0..2], @intCast(stream.name_len), .little);
            sha.update(fixed[0..2]);
            for (stream.name[0..stream.name_len]) |c| {
                std.mem.writeInt(u16, fixed[0..2], c, .little);
                sha.update(fixed[0..2]);
            }
        }
        // Tagged metadata belongs to the inode too; a hardlink must not
        // silently choose one alias's object ID or extended attributes.
        var extra = item.tagged_offset;
        var block: [256]u8 = undefined;
        while (extra < item.extra_offset) {
            const tag = try self.metadata.readTagged(extra, item.extra_offset);
            extra = tag.next;
            if (tag.tag != 1 and tag.tag != 2) continue;
            std.mem.writeInt(u32, block[0..4], tag.tag, .little);
            std.mem.writeInt(u32, block[4..8], tag.bytes, .little);
            sha.update(block[0..8]);
            var done: u64 = 0;
            while (done < tag.bytes) {
                const count: usize = @intCast(@min(block.len, tag.bytes - done));
                try self.metadata.resource.read(tag.data_offset + done, block[0..count]);
                sha.update(block[0..count]);
                done += count;
            }
        }
        return sha.finalResult();
    }
    fn enter(ctx: *anyopaque, parent: u64, item: *const meta.Entry) anyerror!u64 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.path_depth == self.path_starts.len) return error.WimDepthExceeded;
        self.path_starts[self.path_depth] = self.path_len;
        self.path_depth += 1;
        if (item.name_len != 0) {
            if (self.path_len + 1 + item.name_len > 32768) return error.WimPathBudget;
            if (self.path_len != 0) try self.path.append(self.allocator, '\\');
            try self.path.appendSlice(self.allocator, item.name[0..item.name_len]);
            self.path_len = self.path.items.len;
        }
        if (item.isDirectory()) self.directories += 1 else self.files += 1;
        if (self.preflight_progress) |reporter| reporter.report(.{ .current = self.files + self.directories, .total = 0, .bytes = 0, .resources = self.files + self.directories });
        if (item.short_name_bytes != 0) self.short_names += 1;
        if (item.short_name_len != 0) try ntfs.validateShortName(item.short_name[0..item.short_name_len]);
        if (item.tagged_metadata) self.tagged_items += 1;
        if (item.isReparse()) self.reparse_points += 1;
        const key = try self.linkKey(item);
        var prior: ?Hardlink = null;
        var fingerprint_: [20]u8 = undefined;
        if (key) |group| {
            fingerprint_ = try self.fingerprint(item);
            prior = self.links.get(group);
            if (prior) |p| {
                if (!std.mem.eql(u8, &p.fingerprint, &fingerprint_)) {
                    self.log.say("WIM_HARDLINK_MISMATCH group={d} offset={d} prior={d} attrs={x} security={d} times={d}/{d}/{d} main_sha1={x}\n", .{ group.group, item.offset, p.record, item.attributes, item.security, item.times.created, item.times.modified, item.times.accessed, item.main_hash });
                    if (self.fs == null) {
                        if (try self.metadata.readEntry(p.record, false)) |first| self.log.say("WIM_HARDLINK_PRIOR attrs={x} security={d} times={d}/{d}/{d} main_sha1={x} extras={d}/{d}\n", .{ first.attributes, first.security, first.times.created, first.times.modified, first.times.accessed, first.main_hash, first.extra_count, item.extra_count });
                    }
                    return error.InconsistentHardlinkMetadata;
                }
                self.hardlink_names += 1;
            } else if (self.links.count() >= 65536) return error.HardlinkBudgetExceeded;
        }
        // Preflight resolves every stream and unsupported feature before
        // partitions.create or Ntfs.format can write a target byte.
        if (self.fs == null) {
            try self.tagged(item, null);
            var streams = meta.StreamIterator.init(self.metadata, item.*);
            while (try streams.next()) |stream| {
                if (stream.kind == .named_data) self.ads += 1;
                if (!std.mem.allEqual(u8, &stream.hash, 0)) {
                    // NTFS directory unnamed DATA is outside this writer's
                    // supported WIM mapping. Never silently skip a referenced
                    // blob and later claim selected-stream integrity passed.
                    if (item.isDirectory() and stream.kind == .data) return error.UnsupportedDirectoryData;
                    const blob = try self.archive.find(stream.hash);
                    if (stream.kind == .reparse and blob.descriptor.size > 16376) return error.UnsupportedReparseSize;
                    if (stream.kind == .reparse) {
                        const raw = try self.readReparse(item, stream.hash);
                        self.allocator.free(raw);
                    }
                } else if (stream.kind == .reparse) return error.CorruptReparseData;
            }
            if (key) |group| {
                if (prior == null) try self.links.put(group, .{ .record = item.offset, .fingerprint = fingerprint_ });
            }
            return 5;
        }
        const fs = self.fs.?;
        if (prior) |p| {
            try fs.linkFile(parent, item.name[0..item.name_len], p.record);
            if (item.short_name_len != 0 and !try fs.setShortName(parent, item.name[0..item.name_len], item.short_name[0..item.short_name_len], p.record)) self.secondary_short_names_normalized += 1;
            return p.record;
        }
        const opts = self.options(item);
        const record = if (item.name_len == 0) 5 else if (item.isDirectory())
            try fs.mkdir(parent, item.name[0..item.name_len], opts)
        else blk: {
            var streams = meta.StreamIterator.init(self.metadata, item.*);
            while (try streams.next()) |stream| if (stream.kind == .data) {
                if (std.mem.allEqual(u8, &stream.hash, 0)) break :blk try fs.writeFile(parent, item.name[0..item.name_len], empty(), opts);
                var resource = try self.archive.openEntry(try self.archive.find(stream.hash));
                defer resource.deinit();
                self.trackResource(&resource);
                const created = fs.writeFile(parent, item.name[0..item.name_len], .{ .context = &resource, .size = resource.descriptor.size, .read_fn = wim.Resource.fileRead }, opts) catch |err| {
                    if (resource.hash_mismatch) return error.WimHashMismatch;
                    return err;
                };
                try self.resourceDone(&resource);
                break :blk created;
            };
            break :blk try fs.writeFile(parent, item.name[0..item.name_len], empty(), opts);
        };
        if (item.short_name_len != 0 and !try fs.setShortName(parent, item.name[0..item.name_len], item.short_name[0..item.short_name_len], record)) self.secondary_short_names_normalized += 1;
        try self.tagged(item, record);
        var streams = meta.StreamIterator.init(self.metadata, item.*);
        while (try streams.next()) |stream| {
            if (stream.kind == .data) continue;
            if (stream.kind == .named_data) {
                if (std.mem.allEqual(u8, &stream.hash, 0)) {
                    try fs.writeStream(record, stream.name[0..stream.name_len], empty(), .{});
                } else {
                    var resource = try self.archive.openEntry(try self.archive.find(stream.hash));
                    defer resource.deinit();
                    self.trackResource(&resource);
                    fs.writeStream(record, stream.name[0..stream.name_len], .{ .context = &resource, .size = resource.descriptor.size, .read_fn = wim.Resource.fileRead }, .{}) catch |err| {
                        if (resource.hash_mismatch) return error.WimHashMismatch;
                        return err;
                    };
                    try self.resourceDone(&resource);
                }
            } else {
                const raw = try self.readReparse(item, stream.hash);
                defer self.allocator.free(raw);
                try fs.setReparse(record, raw);
            }
        }
        if (key) |group| try self.links.put(group, .{ .record = record, .fingerprint = fingerprint_ });
        return record;
    }
    fn leave(ctx: *anyopaque, record: u64, item: *const meta.Entry) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.fs) |fs| try fs.setMetadata(record, self.options(item));
        if (self.fs != null and !item.isDirectory()) if (self.log.profiler) |profile| profile.filesDone(1);
        if (self.apply_progress) |state| { state.items += 1; state.emit(); }
        if (self.path_depth == 0) return error.WimDepthExceeded;
        self.path_depth -= 1;
        self.path_len = self.path_starts[self.path_depth];
        self.path.shrinkRetainingCapacity(self.path_len);
    }
};
fn emptyRead(_: *anyopaque, _: u64, out: []u8) platform.Error!void {
    if (out.len != 0) return error.Bounds;
}
var empty_context: u8 = 0;
fn empty() ntfs.Source {
    return .{ .context = &empty_context, .size = 0, .read_fn = emptyRead };
}

pub fn run(disk: platform.Disk, kind: partitions.Kind, ids: identity.Identifiers, tracker: *platform.TrackedAllocator, input: wim.Input, selected: u32, log: app.Logger) !void {
    return runToDrive(disk, kind, ids, tracker, input, selected, 'C', log);
}
pub fn runToDrive(disk: platform.Disk, kind: partitions.Kind, ids: identity.Identifiers, tracker: *platform.TrackedAllocator, input: wim.Input, selected: u32, target_drive: u8, log: app.Logger) !void {
    return runWithOptions(disk, kind, ids, tracker, input, selected, .{ .target_drive = target_drive }, log);
}
pub const PreparePartition = *const fn (*anyopaque, platform.Disk, identity.Identifiers, std.mem.Allocator, app.Logger) anyerror!partitions.Partition;
pub const Options = struct {
    target_drive: u8 = 'C',
    strict_rpfix: bool = true,
    verify_scope: VerifyScope = .selected,
    /// Invoked after verified selected metadata and structural preflight.
    /// In selected mode DATA is verified while being written; NTFS remains
    /// dirty/incomplete until every selected stream has passed its SHA-1.
    /// Used by the Windows ESP/MSR/system layout; it must authorize the disk,
    /// verify emptiness and return a new Windows partition for fresh format.
    prepare_context: ?*anyopaque = null,
    prepare_partition: ?PreparePartition = null,
};
pub const VerifyScope = enum { selected, all };
pub fn runWithOptions(disk: platform.Disk, kind: partitions.Kind, ids: identity.Identifiers, tracker: *platform.TrackedAllocator, input_: wim.Input, selected: u32, options_: Options, log: app.Logger) !void {
    var input = input_;
    input.profiler = log.profiler orelse input.profiler;
    const target_drive = options_.target_drive;
    if (target_drive < 'A' or target_drive > 'Z') return error.InvalidTargetDrive;
    try ids.validate();
    const start = log.now();
    const allocator = tracker.allocator();
    var archive = try wim.Archive.open(allocator, input, selected);
    defer archive.deinit();
    log.say("WIM_DUPLICATES identical_verified={d} policy=accept_verified_same_sha1_and_size\n", .{archive.identical_duplicates_verified});
    if (options_.verify_scope == .all) {
        var integrity_progress = progress.Reporter.init(log, "verify-archive-integrity");
        log.say("WIM_INTEGRITY present_and_verified={any}\n", .{try archive.verifyIntegrityWithProgress(integrity_progress.sink())});
    } else
        log.say("WIM_INTEGRITY archive_table_present={any} policy=selected_blob_sha1_during_streaming\n", .{archive.header.integrity.size != 0});
    const inventory = try xml.read(&archive);
    log.say("WIM_XML selected={d} files={d} directories={d} bytes={d} name_utf16_units={d}\n", .{ inventory.index, inventory.files, inventory.directories, inventory.bytes, inventory.name_len });
    var resource = try archive.openMetadata();
    defer resource.deinit();
    var metadata_progress = progress.Reporter.init(log, "verify-metadata");
    resource.progress = metadata_progress.sink();
    try resource.verify();
    resource.progress = null;
    var metadata = try meta.Metadata.open(allocator, &resource);
    defer metadata.deinit();
    const security_ids = try allocator.alloc(u32, metadata.securityCount());
    defer allocator.free(security_ids);
    var context: Context = .{ .archive = &archive, .metadata = &metadata, .allocator = allocator, .log = log, .security_ids = security_ids, .links = std.AutoHashMap(LinkKey, Hardlink).init(allocator), .target_drive = target_drive, .strict_rpfix = options_.strict_rpfix };
    defer context.links.deinit();
    defer context.path.deinit(allocator);
    defer context.tag_counts.deinit(allocator);
    var preflight_progress = progress.Reporter.init(log, "preflight-selected");
    context.preflight_progress = &preflight_progress;
    try metadata.walk(&context, Context.enter, Context.leave);
    context.preflight_progress = null;
    preflight_progress.finish(.{ .current = context.files + context.directories, .total = context.files + context.directories, .bytes = resource.descriptor.size, .resources = context.files + context.directories });
    for (context.tag_counts.items) |tag|
        log.say("WIM_TAGGED type=0x{x} entries={d} policy={s}\n", .{ tag.tag, tag.entries, if (tag.tag == 1) "object_id" else if (tag.tag == 2) "extended_attributes" else "ignored_unknown" });
    log.say("WIM_RP_FIX header={any} target_drive={c} fixed={d} rpfix_eligible_unmatched={d} strict={any}\n", .{ archive.header.flags & 0x80 != 0, target_drive, context.reparse_fixed, context.rpfix_eligible_unmatched, context.strict_rpfix });
    if (context.strict_rpfix and context.rpfix_eligible_unmatched != 0) {
        // Complete the inventory so the log reports every eligible mismatch,
        // then refuse before partition creation/formatting or any target IO.
        log.say("WIM_RP_FIX refused_before_target_write=true rpfix_eligible_unmatched={d}\n", .{context.rpfix_eligible_unmatched});
        return error.UnmatchedRpFixTarget;
    }
    log.say("WIM_PREFLIGHT images={d} selected={d} compression={s} chunk={d} files={d} dirs={d} hardlink_aliases={d} reparse={d} ADS={d} short_8_3={d} entries_with_tagged_space={d}\n", .{ archive.header.images, selected, if (archive.header.compression) |k| @tagName(k) else "none", archive.header.chunk_size, context.files, context.directories, context.hardlink_names, context.reparse_points, context.ads, context.short_names, context.tagged_items });
    if (options_.verify_scope == .all) {
        var all_progress = progress.Reporter.init(log, "verify-all");
        try archive.verifyAllWithProgress(all_progress.sink());
        log.say("WIM_SHA1 ALL_BLOBS PASS count={d} before_target_write=true alloc_peak={d}\n", .{ archive.hashes_verified, tracker.peak });
    } else {
        log.say("WIM_SHA1 scope=selected metadata=verified data=streaming first_mismatch=refuse target_until_success=incomplete\n", .{});
    }
    // Fresh formatting is the only supported entry to the NTFS writer.
    const partition = if (options_.prepare_partition) |prepare|
        try prepare(options_.prepare_context orelse return error.InvalidArgument, disk, ids, allocator, log)
    else
        try partitions.create(disk, kind, ids);
    if (partition.start_bytes % disk.sector_bytes != 0 or partition.size_bytes % disk.sector_bytes != 0 or
        partition.size_bytes == 0 or partition.start_bytes > try disk.bytes() or
        partition.size_bytes > (try disk.bytes()) - partition.start_bytes) return error.InvalidArgument;
    var fs = try ntfs.Ntfs.init(disk, partition, allocator, ids.ntfs_serial);
    defer fs.deinit();
    try fs.format();
    errdefer {
        fs.markIncomplete() catch |mark_error| log.say("TARGET_INCOMPLETE mark_error={s}\n", .{@errorName(mark_error)});
        log.say("TARGET_INCOMPLETE selected={d} clean=false bootable=false reason=apply_failed\n", .{selected});
    }
    const sd_buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(sd_buffer);
    for (security_ids, 0..) |*id, i| id.* = try fs.registerSecurity(try metadata.readSecurity(@intCast(i), sd_buffer));
    context.fs = &fs;
    var apply_progress: ApplyProgress = .{ .reporter = progress.Reporter.init(log, "apply-selected"), .total = context.files + context.directories };
    context.apply_progress = &apply_progress;
    apply_progress.emit();
    context.links.clearRetainingCapacity();
    context.files = 0;
    context.directories = 0;
    context.reparse_fixed = 0;
    try metadata.walk(&context, Context.enter, Context.leave);
    for (context.tag_counts.items) |tag|
        log.say("WIM_TAGGED_APPLIED type=0x{x} inode_count={d}\n", .{ tag.tag, tag.applied });
    try fs.finish();
    try disk.flush();
    var durable_progress = progress.Reporter.init(log, "apply-durable");
    durable_progress.started = start;
    durable_progress.files_start = 0;
    durable_progress.finish(.{ .current = context.files + context.directories, .total = context.files + context.directories, .bytes = apply_progress.bytes, .resources = apply_progress.resources });
    log.say("WIM_SHA1 SELECTED_STREAMS PASS selected={d} metadata=verified all_applied_streams=verified\n", .{selected});
    log.say("WIM_SHORT_NAMES secondary_hardlink_aliases_normalized={d} policy=single_DOS_pair_per_inode\n", .{context.secondary_short_names_normalized});
    log.say("USOSPREP WIM PASS selected={d} compression={s} fresh_format=true files={d} directories={d} seconds={d} alloc_peak={d} short_8_3=true changed_time=modified_time\n", .{ selected, if (archive.header.compression) |k| @tagName(k) else "none", context.files, context.directories, log.now() -| start, tracker.peak });
}

// These are self-authored format fixtures, not captured operating-system data.
const RpFixProbe = struct {
    source: []const u8,
    reads: usize = 0,
    writes: usize = 0,
    flushes: usize = 0,
    log_bytes: [16384]u8 = undefined,
    log_len: usize = 0,
    fn inputRead(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (at > self.source.len or out.len > self.source.len - at) return error.Bounds;
        @memcpy(out, self.source[@intCast(at)..][0..out.len]);
    }
    fn diskRead(ctx: *anyopaque, _: u64, _: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        return error.Io;
    }
    fn diskWrite(ctx: *anyopaque, _: u64, _: []const u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        return error.Io;
    }
    fn diskFlush(ctx: *anyopaque) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.flushes += 1;
        return error.Io;
    }
    fn logWrite(ctx: *anyopaque, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        std.debug.assert(text.len <= self.log_bytes.len - self.log_len);
        @memcpy(self.log_bytes[self.log_len..][0..text.len], text);
        self.log_len += text.len;
    }
    fn clock(_: *anyopaque) u64 {
        return 0;
    }
    fn disk(self: *@This()) platform.Disk {
        return .{ .context = self, .sectors = 128 * 1024 * 1024 / 512, .read_fn = diskRead, .write_fn = diskWrite, .flush_fn = diskFlush };
    }
    fn logger(self: *@This()) app.Logger {
        return .{ .context = self, .write_fn = logWrite, .clock_fn = clock };
    }
};
fn fixturePut(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn fixtureDescriptor(bytes: []u8, at: usize, offset: u64, size: u64, flags: u8) void {
    fixturePut(u64, bytes, at, size | (@as(u64, flags) << 56));
    fixturePut(u64, bytes, at + 8, offset);
    fixturePut(u64, bytes, at + 16, size);
}
fn rpFixFixture(bytes: []u8) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "MSWIM\x00\x00\x00");
    fixturePut(u32, bytes, 8, 208);
    fixturePut(u32, bytes, 12, 0x10d00);
    fixturePut(u32, bytes, 16, 0x80);
    fixturePut(u16, bytes, 40, 1);
    fixturePut(u16, bytes, 42, 1);
    fixturePut(u32, bytes, 44, 1);
    fixtureDescriptor(bytes, 48, 208, 150, 2);
    const inventory = std.unicode.utf8ToUtf16LeStringLiteral("<WIM><IMAGE INDEX=\"1\"><NAME>Own RP_FIX fixture</NAME></IMAGE></WIM>");
    fixtureDescriptor(bytes, 72, 2048, 2 + inventory.len * 2, 2);
    fixturePut(u16, bytes, 2048, 0xfeff);
    for (inventory, 0..) |c, i| fixturePut(u16, bytes, 2050 + i * 2, c);
    const metadata = bytes[512..1024];
    fixturePut(u32, metadata, 0, 8);
    fixturePut(u64, metadata, 8, 104);
    fixturePut(u32, metadata, 16, 0x10);
    fixturePut(u32, metadata, 20, 0xffffffff);
    fixturePut(u64, metadata, 24, 120);
    const names = [_][]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("Volume"),
        std.unicode.utf8ToUtf16LeStringLiteral("Rootless"),
    };
    const targets = [_][]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("\\??\\Volume{12345678-1234-1234-1234-123456789abc}\\Users"),
        std.unicode.utf8ToUtf16LeStringLiteral("\\Users"),
    };
    for (names, targets, 0..) |name, target, i| {
        const at = 120 + i * 120;
        fixturePut(u64, metadata, at, 120);
        fixturePut(u32, metadata, at + 8, 0x410);
        fixturePut(u32, metadata, at + 12, 0xffffffff);
        fixturePut(u32, metadata, at + 88, 0xa0000003);
        fixturePut(u16, metadata, at + 100, @intCast(name.len * 2));
        for (name, 0..) |c, j| fixturePut(u16, metadata, at + 102 + j * 2, c);
        const payload_at = 1200 + i * 200;
        const payload_size = 8 + target.len * 2;
        fixturePut(u16, bytes, payload_at + 2, @intCast(target.len * 2));
        for (target, 0..) |c, j| fixturePut(u16, bytes, payload_at + 8 + j * 2, c);
        const entry_at = 258 + i * 50;
        fixtureDescriptor(bytes, entry_at, payload_at, payload_size, 0);
        fixturePut(u16, bytes, entry_at + 24, 1);
        fixturePut(u32, bytes, entry_at + 26, 1);
        std.crypto.hash.Sha1.hash(bytes[payload_at..][0..payload_size], bytes[entry_at + 30 ..][0..20], .{});
        @memcpy(metadata[at + 64 ..][0..20], bytes[entry_at + 30 ..][0..20]);
    }
    fixtureDescriptor(bytes, 208, 512, 512, 2);
    fixturePut(u16, bytes, 232, 1);
    fixturePut(u32, bytes, 234, 1);
    std.crypto.hash.Sha1.hash(metadata, bytes[238..258], .{});
}
test "strict RP_FIX inventories all unmatched paths and refuses before any target IO" {
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    var before: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &before, .{});
    var entropy_bytes: [64]u8 = undefined;
    for (&entropy_bytes, 0..) |*c, i| c.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(entropy_bytes);
    var probe: RpFixProbe = .{ .source = &bytes };
    var tracker: platform.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    try std.testing.expectError(error.UnmatchedRpFixTarget, runWithOptions(probe.disk(), .mbr, ids, &tracker, .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1, .{}, probe.logger()));
    try std.testing.expectEqual(@as(usize, 0), probe.reads + probe.writes + probe.flushes);
    try std.testing.expectEqual(@as(usize, 0), tracker.current);
    const log = probe.log_bytes[0..probe.log_len];
    try std.testing.expect(std.mem.indexOf(u8, log, "path=\"Volume\" target=\"\\??\\Volume{") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "path=\"Rootless\" target=\"\\Users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "refused_before_target_write=true rpfix_eligible_unmatched=2") != null);
    var after: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &after, .{});
    try std.testing.expectEqualSlices(u8, &before, &after);
}
test "lax RP_FIX reports both unmatched targets and reaches the guarded writer" {
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    var entropy_bytes: [64]u8 = undefined;
    for (&entropy_bytes, 0..) |*c, i| c.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(entropy_bytes);
    var probe: RpFixProbe = .{ .source = &bytes };
    var tracker: platform.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    try std.testing.expectError(error.Io, runWithOptions(probe.disk(), .mbr, ids, &tracker, .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1, .{ .strict_rpfix = false, .verify_scope = .all }, probe.logger()));
    try std.testing.expect(probe.writes != 0);
    try std.testing.expectEqual(@as(usize, 0), tracker.current);
    const log = probe.log_bytes[0..probe.log_len];
    try std.testing.expect(std.mem.indexOf(u8, log, "rpfix_eligible_unmatched=2 strict=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "WIM_SHA1 ALL_BLOBS PASS") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "refused_before_target_write") == null);
}
test "unmatched diagnostics retain long paths and lax apply does not double the inventory" {
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    var probe: RpFixProbe = .{ .source = &bytes };
    const allocator = std.testing.allocator;
    var archive = try wim.Archive.open(allocator, .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1);
    defer archive.deinit();
    var resource = try archive.openMetadata();
    defer resource.deinit();
    try resource.verify();
    var metadata = try meta.Metadata.open(allocator, &resource);
    defer metadata.deinit();
    const item = (try metadata.readEntry(120, false)).?;
    var context: Context = .{ .archive = &archive, .metadata = &metadata, .allocator = allocator, .log = probe.logger(), .security_ids = &.{}, .links = std.AutoHashMap(LinkKey, Hardlink).init(allocator), .strict_rpfix = false };
    defer context.links.deinit();
    defer context.path.deinit(allocator);
    const path: [2048]u16 = @splat('x');
    try context.path.appendSlice(allocator, &path);
    context.path_len = path.len;
    const first = try context.readReparse(&item, item.main_hash);
    allocator.free(first);
    const log_len = probe.log_len;
    const expected: [2048]u8 = @splat('x');
    try std.testing.expect(std.mem.indexOf(u8, probe.log_bytes[0..log_len], &expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, probe.log_bytes[0..log_len], "LOG LINE TOO LONG") == null);
    try std.testing.expectEqual(@as(u64, 1), context.rpfix_eligible_unmatched);
    // readReparse only checks whether apply owns an FS; it never dereferences
    // this placeholder. The same mismatch must not add another count or line.
    var fs: ntfs.Ntfs = undefined;
    context.fs = &fs;
    const second = try context.readReparse(&item, item.main_hash);
    allocator.free(second);
    try std.testing.expectEqual(@as(u64, 1), context.rpfix_eligible_unmatched);
    try std.testing.expectEqual(log_len, probe.log_len);
}

const PrepareProbe = struct {
    calls: usize = 0,
    fn prepare(ctx: *anyopaque, _: platform.Disk, _: identity.Identifiers, _: std.mem.Allocator, _: app.Logger) anyerror!partitions.Partition {
        const self: *PrepareProbe = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return error.Io;
    }
};
test "custom layout callback only runs after source metadata and blob preflight" {
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(seed);
    for ([_]bool{ true, false }) |strict| {
        var probe: RpFixProbe = .{ .source = &bytes };
        var callback: PrepareProbe = .{};
        var tracker: platform.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
        try std.testing.expectError(if (strict) error.UnmatchedRpFixTarget else error.Io, runWithOptions(probe.disk(), .gpt, ids, &tracker, .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1, .{ .strict_rpfix = strict, .prepare_context = &callback, .prepare_partition = PrepareProbe.prepare }, probe.logger()));
        try std.testing.expectEqual(@as(usize, if (strict) 0 else 1), callback.calls);
        try std.testing.expectEqual(@as(usize, 0), probe.reads + probe.writes + probe.flushes);
        try std.testing.expectEqual(@as(usize, 0), tracker.current);
    }
}

test "selected default skips unused bad blob while all refuses before target preparation" {
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    fixtureDescriptor(&bytes, 48, 208, 200, 2);
    fixtureDescriptor(&bytes, 358, 1800, 32, 0);
    fixturePut(u16, &bytes, 382, 1);
    fixturePut(u32, &bytes, 384, 1);
    @memset(bytes[1800..1832], 0x57);
    std.crypto.hash.Sha1.hash(bytes[1800..1832], bytes[388..408], .{});
    bytes[1800] ^= 1;
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(seed);
    try std.testing.expectEqual(VerifyScope.selected, (Options{}).verify_scope);
    for ([_]VerifyScope{ .selected, .all }) |scope| {
        var probe: RpFixProbe = .{ .source = &bytes };
        var callback: PrepareProbe = .{};
        var tracker: platform.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
        try std.testing.expectError(if (scope == .all) error.WimHashMismatch else error.Io,
            runWithOptions(probe.disk(), .gpt, ids, &tracker, .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1,
                .{ .strict_rpfix = false, .verify_scope = scope, .prepare_context = &callback, .prepare_partition = PrepareProbe.prepare }, probe.logger()));
        try std.testing.expectEqual(@as(usize, if (scope == .all) 0 else 1), callback.calls);
        try std.testing.expectEqual(@as(usize, 0), probe.reads + probe.writes + probe.flushes);
        try std.testing.expectEqual(@as(usize, 0), tracker.current);
    }
    bytes[512 + 400] ^= 1;
    var probe: RpFixProbe = .{ .source = &bytes };
    var callback: PrepareProbe = .{};
    var tracker: platform.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    try std.testing.expectError(error.WimHashMismatch, runWithOptions(probe.disk(), .gpt, ids, &tracker,
        .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1,
        .{ .strict_rpfix = false, .prepare_context = &callback, .prepare_partition = PrepareProbe.prepare }, probe.logger()));
    try std.testing.expectEqual(@as(usize, 0), callback.calls);
    try std.testing.expectEqual(@as(usize, 0), tracker.current);
}
test "selected stream hash mismatch leaves NTFS dirty and cannot report apply success" {
    const Memory = struct {
        bytes: []u8,
        fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
            @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
        }
        fn write(ctx: *anyopaque, at: u64, input: []const u8) platform.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (at > self.bytes.len or input.len > self.bytes.len - at) return error.Bounds;
            @memcpy(self.bytes[@intCast(at)..][0..input.len], input);
        }
        fn flush(_: *anyopaque) platform.Error!void {}
    };
    const allocator = std.testing.allocator;
    const storage = try allocator.alloc(u8, 80 * 1024 * 1024);
    defer allocator.free(storage);
    @memset(storage, 0);
    var memory: Memory = .{ .bytes = storage };
    const disk: platform.Disk = .{ .context = &memory, .sectors = storage.len / 512, .read_fn = Memory.read, .write_fn = Memory.write, .flush_fn = Memory.flush };
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    // Turn the first junction into a normal file. Its DATA hash remains the
    // original hash, but one data byte changes; preflight must not read DATA.
    fixturePut(u32, &bytes, 512 + 120 + 8, 0x20);
    fixturePut(u32, &bytes, 512 + 120 + 88, 0);
    std.crypto.hash.Sha1.hash(bytes[512..1024], bytes[238..258], .{});
    bytes[1200] ^= 1;
    var probe: RpFixProbe = .{ .source = &bytes };
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(seed);
    var tracker: platform.TrackedAllocator = .{ .backing = allocator, .limit = 16 * 1024 * 1024 };
    try std.testing.expectError(error.WimHashMismatch, runWithOptions(disk, .gpt, ids, &tracker,
        .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1,
        .{ .strict_rpfix = false }, probe.logger()));
    const text = probe.log_bytes[0..probe.log_len];
    try std.testing.expect(std.mem.indexOf(u8, text, "TARGET_INCOMPLETE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "USOSPREP WIM PASS") == null);
    try std.testing.expectEqual(@as(usize, 0), tracker.current);
    const rec = @import("record.zig");
    const boot = storage[1024 * 1024..][0..512];
    const mft = std.mem.readInt(u64, boot[48..56], .little);
    var record: [1024]u8 = undefined;
    try disk.read(1024 * 1024 + mft * 4096 + 3 * 1024, &record);
    try rec.unprotect(&record);
    const attr = (try rec.find(&record, 0x70, &.{})).?;
    const info = try rec.value(attr.bytes);
    try std.testing.expect(std.mem.readInt(u16, info[10..12], .little) & 1 != 0);
}

test "directory unnamed DATA is refused before preparation instead of silently skipping SHA" {
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    @memcpy(bytes[512 + 8 + 64..][0..20], bytes[258 + 30..][0..20]);
    std.crypto.hash.Sha1.hash(bytes[512..1024], bytes[238..258], .{});
    // Metadata SHA is valid but its directory DATA blob is damaged. Both
    // scopes must refuse the unsupported mapping before target preparation.
    bytes[1200] ^= 1;
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(seed);
    for ([_]VerifyScope{ .selected, .all }) |scope| {
        var probe: RpFixProbe = .{ .source = &bytes };
        var callback: PrepareProbe = .{};
        var tracker: platform.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
        try std.testing.expectError(error.UnsupportedDirectoryData, runWithOptions(probe.disk(), .gpt, ids, &tracker,
            .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1,
            .{ .verify_scope = scope, .strict_rpfix = false, .prepare_context = &callback, .prepare_partition = PrepareProbe.prepare }, probe.logger()));
        try std.testing.expectEqual(@as(usize, 0), callback.calls);
        try std.testing.expectEqual(@as(usize, 0), probe.reads + probe.writes + probe.flushes);
        try std.testing.expectEqual(@as(usize, 0), tracker.current);
    }
}

test "combined MFT final durability failure redirties both volume records and suppresses PASS" {
    const Memory = @import("mft_cache_tests.zig").Memory;
    const combine = @import("writecombine.zig");
    const rec = @import("record.zig");
    const storage = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    var memory: Memory = .{ .bytes = storage };
    defer memory.deinit();
    var bytes: [4096]u8 = undefined;
    rpFixFixture(&bytes);
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(seed);
    var final_flush: u64 = 0;
    for ([_]bool{ false, true }) |fail| {
        @memset(storage, 0);
        memory.flushes = 0;
        memory.fail_flush_at = if (fail) final_flush else 0;
        var tracker: platform.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
        var combined = try combine.Cache.init(tracker.allocator(), memory.disk(), .raw_file);
        defer combined.deinit();
        var probe: RpFixProbe = .{ .source = &bytes };
        const result = runWithOptions(combined.disk(), .gpt, ids, &tracker,
            .{ .context = &probe, .size = bytes.len, .read_fn = RpFixProbe.inputRead }, 1,
            .{ .strict_rpfix = false }, probe.logger());
        if (fail) {
            try std.testing.expectError(error.Io, result);
            try std.testing.expect(std.mem.indexOf(u8, probe.log_bytes[0..probe.log_len], "TARGET_INCOMPLETE") != null);
            try std.testing.expect(std.mem.indexOf(u8, probe.log_bytes[0..probe.log_len], "USOSPREP WIM PASS") == null);
            try std.testing.expect(combined.first_error != null);
        } else {
            try result;
            final_flush = memory.flushes;
            try std.testing.expect(final_flush >= 3);
            try std.testing.expectEqual(@as(usize, 0), combined.pending);
        }
        const boot = storage[1024 * 1024..][0..512];
        for ([_]usize{ 48, 56 }) |field| {
            const lcn = std.mem.readInt(u64, boot[field..][0..8], .little);
            var record: [1024]u8 = storage[@intCast(1024 * 1024 + lcn * 4096 + 3 * 1024)..][0..1024].*;
            try rec.unprotect(&record);
            const info = try rec.value((try rec.find(&record, 0x70, &.{})).?.bytes);
            try std.testing.expectEqual(fail, std.mem.readInt(u16, info[10..12], .little) & 1 != 0);
        }
        try std.testing.expectEqual(@as(usize, combine.capacity), tracker.current);
    }
}
