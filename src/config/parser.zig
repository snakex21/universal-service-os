const std = @import("std");

pub const Config = struct {
    images_root: []const u8 = "Images",
    unattended_root: []const u8 = "Unattended",
    working_root: []const u8 = "Work",
    verify_images: bool = true,
};

pub const ParseError = error{
    InvalidLine,
    UnknownKey,
    InvalidBoolean,
    EmptyValue,
};

pub fn parse(text: []const u8) ParseError!Config {
    var config = Config{};
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLine;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.EmptyValue;

        if (std.mem.eql(u8, key, "images_root")) {
            config.images_root = value;
        } else if (std.mem.eql(u8, key, "unattended_root")) {
            config.unattended_root = value;
        } else if (std.mem.eql(u8, key, "working_root")) {
            config.working_root = value;
        } else if (std.mem.eql(u8, key, "verify_images")) {
            config.verify_images = try parseBool(value);
        } else {
            return error.UnknownKey;
        }
    }

    return config;
}

fn parseBool(value: []const u8) ParseError!bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "no")) return false;
    return error.InvalidBoolean;
}

test "config parser keeps defaults for empty input" {
    const config = try parse("");
    try std.testing.expectEqualStrings("Images", config.images_root);
    try std.testing.expectEqualStrings("Unattended", config.unattended_root);
    try std.testing.expectEqualStrings("Work", config.working_root);
    try std.testing.expect(config.verify_images);
}

test "config parser reads values and ignores comments" {
    const config = try parse(
        \\# Universal Service OS
        \\images_root = Systems
        \\unattended_root=Answers
        \\working_root = Scratch
        \\verify_images = no
    );

    try std.testing.expectEqualStrings("Systems", config.images_root);
    try std.testing.expectEqualStrings("Answers", config.unattended_root);
    try std.testing.expectEqualStrings("Scratch", config.working_root);
    try std.testing.expect(!config.verify_images);
}

test "config parser rejects unknown keys" {
    try std.testing.expectError(error.UnknownKey, parse("magic=true"));
}

test "config parser rejects malformed booleans" {
    try std.testing.expectError(error.InvalidBoolean, parse("verify_images=maybe"));
}
