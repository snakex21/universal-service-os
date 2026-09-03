const std = @import("std");

pub const basic_data_gpt_type = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7";
pub const work_gpt_type = basic_data_gpt_type;
pub const esp_gpt_type = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
pub const data_gpt_type = basic_data_gpt_type;
pub const work_volume_label = "USOS_WORK";
pub const marker_filename = ".usos-work";
pub const partuuid_prefix = "/dev/disk/by-partuuid/";

pub const Partition = struct {
    partuuid: []const u8,
    path: []const u8,
    gpt_type: []const u8,
    parent_disk: []const u8,
    size_bytes: u64,
    volume_label: ?[]const u8,
    is_gpt: bool,
    is_mounted: bool,
    is_rootfs: bool,
};

pub const FreshConfirmation = struct {
    partuuid: []const u8,
    size_bytes: u64,
    observed_label: ?[]const u8,
    planned_label: []const u8,
};

pub const WorkIdentity = struct {
    device_nonce: []const u8,
    marker_nonce: ?[]const u8,
    fresh_confirmation: ?FreshConfirmation = null,
};

pub const Facts = struct {
    work: Partition,
    esp: Partition,
    data: Partition,
    expected_parent_disk: []const u8,
    identity: WorkIdentity,
};

pub const Error = error{
    MissingPartuuidPath,
    NotGpt,
    WrongPartitionType,
    WrongParentDisk,
    DuplicatePartition,
    TargetMounted,
    TargetIsRootfs,
    EmptyDeviceNonce,
    MarkerNonceMismatch,
    MarkerMissingNeedsConfirmation,
    FreshConfirmationMismatch,
    WrongVolumeLabel,
};

/// Checks every fact required before a destructive WORK format.
/// Existing media must prove identity with .usos-work + USOS_WORK.
/// A fresh media exception is accepted only when the caller supplies an exact
/// confirmation of PARTUUID, size, current label and planned USOS_WORK label.
pub fn verifyBeforeFormat(facts: Facts) Error!void {
    try verifyTopology(facts);
    if (facts.identity.device_nonce.len == 0) return error.EmptyDeviceNonce;

    if (facts.identity.marker_nonce) |marker_nonce| {
        if (!std.mem.eql(u8, marker_nonce, facts.identity.device_nonce)) return error.MarkerNonceMismatch;
        if (!labelEquals(facts.work.volume_label, work_volume_label)) return error.WrongVolumeLabel;
        return;
    }

    const confirmation = facts.identity.fresh_confirmation orelse return error.MarkerMissingNeedsConfirmation;
    if (!sameUuid(confirmation.partuuid, facts.work.partuuid) or
        confirmation.size_bytes != facts.work.size_bytes or
        !optionalStringEqual(confirmation.observed_label, facts.work.volume_label) or
        !std.mem.eql(u8, confirmation.planned_label, work_volume_label))
    {
        return error.FreshConfirmationMismatch;
    }
}

/// Checks the identity that must exist immediately after formatting WORK and
/// writing .usos-work as the first file.
pub fn verifyAfterFormat(work: Partition, device_nonce: []const u8, marker_nonce: ?[]const u8) Error!void {
    if (device_nonce.len == 0) return error.EmptyDeviceNonce;
    if (!work.is_gpt) return error.NotGpt;
    if (!std.ascii.eqlIgnoreCase(work.gpt_type, work_gpt_type)) return error.WrongPartitionType;
    if (!labelEquals(work.volume_label, work_volume_label)) return error.WrongVolumeLabel;
    const actual_marker = marker_nonce orelse return error.MarkerMissingNeedsConfirmation;
    if (!std.mem.eql(u8, actual_marker, device_nonce)) return error.MarkerNonceMismatch;
}

fn verifyTopology(facts: Facts) Error!void {
    try verifyPartuuidPath(facts.work);
    try verifyPartuuidPath(facts.esp);
    try verifyPartuuidPath(facts.data);

    if (!facts.work.is_gpt or !facts.esp.is_gpt or !facts.data.is_gpt) return error.NotGpt;

    if (!std.ascii.eqlIgnoreCase(facts.work.gpt_type, work_gpt_type)) return error.WrongPartitionType;
    if (!std.ascii.eqlIgnoreCase(facts.esp.gpt_type, esp_gpt_type)) return error.WrongPartitionType;
    if (!std.ascii.eqlIgnoreCase(facts.data.gpt_type, data_gpt_type)) return error.WrongPartitionType;

    if (!std.mem.eql(u8, facts.work.parent_disk, facts.expected_parent_disk) or
        !std.mem.eql(u8, facts.esp.parent_disk, facts.expected_parent_disk) or
        !std.mem.eql(u8, facts.data.parent_disk, facts.expected_parent_disk))
    {
        return error.WrongParentDisk;
    }

    if (sameUuid(facts.work.partuuid, facts.esp.partuuid) or
        sameUuid(facts.work.partuuid, facts.data.partuuid) or
        sameUuid(facts.esp.partuuid, facts.data.partuuid))
    {
        return error.DuplicatePartition;
    }

    if (facts.work.is_mounted) return error.TargetMounted;
    if (facts.work.is_rootfs) return error.TargetIsRootfs;
}

fn verifyPartuuidPath(partition: Partition) Error!void {
    if (!std.mem.startsWith(u8, partition.path, partuuid_prefix)) return error.MissingPartuuidPath;
    const path_uuid = partition.path[partuuid_prefix.len..];
    if (path_uuid.len == 0 or !sameUuid(path_uuid, partition.partuuid)) return error.MissingPartuuidPath;
}

fn labelEquals(actual: ?[]const u8, expected: []const u8) bool {
    return if (actual) |label| std.mem.eql(u8, label, expected) else false;
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn sameUuid(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn validFacts() Facts {
    return .{
        .work = .{
            .partuuid = "11111111-1111-1111-1111-111111111111",
            .path = "/dev/disk/by-partuuid/11111111-1111-1111-1111-111111111111",
            .gpt_type = work_gpt_type,
            .parent_disk = "disk-file-usos.img",
            .size_bytes = 10 * 1024 * 1024 * 1024,
            .volume_label = work_volume_label,
            .is_gpt = true,
            .is_mounted = false,
            .is_rootfs = false,
        },
        .esp = .{
            .partuuid = "22222222-2222-2222-2222-222222222222",
            .path = "/dev/disk/by-partuuid/22222222-2222-2222-2222-222222222222",
            .gpt_type = esp_gpt_type,
            .parent_disk = "disk-file-usos.img",
            .size_bytes = 260 * 1024 * 1024,
            .volume_label = "USOS_ESP",
            .is_gpt = true,
            .is_mounted = false,
            .is_rootfs = false,
        },
        .data = .{
            .partuuid = "33333333-3333-3333-3333-333333333333",
            .path = "/dev/disk/by-partuuid/33333333-3333-3333-3333-333333333333",
            .gpt_type = data_gpt_type,
            .parent_disk = "disk-file-usos.img",
            .size_bytes = 1024 * 1024 * 1024,
            .volume_label = "USOS_DATA",
            .is_gpt = true,
            .is_mounted = false,
            .is_rootfs = false,
        },
        .expected_parent_disk = "disk-file-usos.img",
        .identity = .{
            .device_nonce = "nonce-0123456789abcdef",
            .marker_nonce = "nonce-0123456789abcdef",
        },
    };
}

test "existing WORK requires matching marker nonce and label" {
    try verifyBeforeFormat(validFacts());
}

test "WORK and DATA both use Microsoft Basic Data" {
    try std.testing.expectEqualStrings(basic_data_gpt_type, work_gpt_type);
    try std.testing.expectEqualStrings(basic_data_gpt_type, data_gpt_type);
}

test "device guard requires by-partuuid path" {
    var facts = validFacts();
    facts.work.path = "/dev/sda3";
    try std.testing.expectError(error.MissingPartuuidPath, verifyBeforeFormat(facts));
}

test "device guard rejects non GPT target" {
    var facts = validFacts();
    facts.work.is_gpt = false;
    try std.testing.expectError(error.NotGpt, verifyBeforeFormat(facts));
}

test "device guard verifies ESP type even though WORK and DATA share Basic Data" {
    var facts = validFacts();
    facts.esp.gpt_type = basic_data_gpt_type;
    try std.testing.expectError(error.WrongPartitionType, verifyBeforeFormat(facts));
}

test "device guard verifies common parent disk" {
    var facts = validFacts();
    facts.work.parent_disk = "other-disk";
    try std.testing.expectError(error.WrongParentDisk, verifyBeforeFormat(facts));
}

test "device guard requires WORK ESP DATA to be distinct" {
    var facts = validFacts();
    facts.work.partuuid = facts.data.partuuid;
    facts.work.path = facts.data.path;
    try std.testing.expectError(error.DuplicatePartition, verifyBeforeFormat(facts));
}

test "device guard refuses mounted WORK" {
    var facts = validFacts();
    facts.work.is_mounted = true;
    try std.testing.expectError(error.TargetMounted, verifyBeforeFormat(facts));
}

test "device guard refuses rootfs WORK" {
    var facts = validFacts();
    facts.work.is_rootfs = true;
    try std.testing.expectError(error.TargetIsRootfs, verifyBeforeFormat(facts));
}

test "existing WORK rejects missing marker without first-run confirmation" {
    var facts = validFacts();
    facts.identity.marker_nonce = null;
    try std.testing.expectError(error.MarkerMissingNeedsConfirmation, verifyBeforeFormat(facts));
}

test "existing WORK rejects mismatching marker nonce" {
    var facts = validFacts();
    facts.identity.marker_nonce = "other-nonce";
    try std.testing.expectError(error.MarkerNonceMismatch, verifyBeforeFormat(facts));
}

test "existing WORK rejects wrong volume label" {
    var facts = validFacts();
    facts.work.volume_label = "Windows";
    try std.testing.expectError(error.WrongVolumeLabel, verifyBeforeFormat(facts));
}

test "fresh WORK requires exact explicit confirmation" {
    var facts = validFacts();
    facts.work.volume_label = null;
    facts.identity.marker_nonce = null;
    facts.identity.fresh_confirmation = .{
        .partuuid = facts.work.partuuid,
        .size_bytes = facts.work.size_bytes,
        .observed_label = null,
        .planned_label = work_volume_label,
    };
    try verifyBeforeFormat(facts);
}

test "fresh WORK confirmation rejects size mismatch" {
    var facts = validFacts();
    facts.work.volume_label = null;
    facts.identity.marker_nonce = null;
    facts.identity.fresh_confirmation = .{
        .partuuid = facts.work.partuuid,
        .size_bytes = facts.work.size_bytes - 1,
        .observed_label = null,
        .planned_label = work_volume_label,
    };
    try std.testing.expectError(error.FreshConfirmationMismatch, verifyBeforeFormat(facts));
}

test "post-format identity requires USOS_WORK and restored nonce marker" {
    const facts = validFacts();
    try verifyAfterFormat(facts.work, facts.identity.device_nonce, facts.identity.marker_nonce);
}

test "post-format identity rejects absent restored marker" {
    const facts = validFacts();
    try std.testing.expectError(error.MarkerMissingNeedsConfirmation, verifyAfterFormat(facts.work, facts.identity.device_nonce, null));
}
