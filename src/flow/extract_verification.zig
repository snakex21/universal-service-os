const std = @import("std");

pub const Stats = struct {
    files: u64,
    bytes: u64,
};

pub const Error = error{
    FileCountMismatch,
    ByteCountMismatch,
    UnattendMissing,
};

pub fn verify(source: Stats, destination: Stats) Error!void {
    if (source.files != destination.files) return error.FileCountMismatch;
    if (source.bytes != destination.bytes) return error.ByteCountMismatch;
}

pub fn readyForPrepared(source: Stats, destination: Stats, unattended_requested: bool, unattended_present: bool) Error!void {
    try verify(source, destination);
    if (unattended_requested and !unattended_present) return error.UnattendMissing;
}

test "matching extraction statistics can become prepared" {
    try readyForPrepared(.{ .files = 123, .bytes = 7_437_390_947 }, .{ .files = 123, .bytes = 7_437_390_947 }, false, false);
}

test "file count mismatch blocks prepared" {
    try std.testing.expectError(error.FileCountMismatch, readyForPrepared(.{ .files = 12, .bytes = 100 }, .{ .files = 11, .bytes = 100 }, false, false));
}

test "byte count mismatch blocks prepared" {
    try std.testing.expectError(error.ByteCountMismatch, readyForPrepared(.{ .files = 12, .bytes = 100 }, .{ .files = 12, .bytes = 99 }, false, false));
}

test "requested unattended must exist before prepared" {
    try std.testing.expectError(error.UnattendMissing, readyForPrepared(.{ .files = 1, .bytes = 1 }, .{ .files = 1, .bytes = 1 }, true, false));
}
