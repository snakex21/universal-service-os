const std = @import("std");

pub const Stage = enum {
    request_saved,
    return_boot_configured,
    loader_ready,
    transferring_control,

    pub fn label(self: Stage) []const u8 {
        return switch (self) {
            .request_saved => "1/5 Starting environment - preparation request saved",
            .return_boot_configured => "1/5 Starting environment - return boot configured",
            .loader_ready => "1/5 Starting environment - preparation environment ready",
            .transferring_control => "1/5 Starting environment - starting preparation environment",
        };
    }

    pub fn detail(self: Stage) []const u8 {
        return switch (self) {
            .request_saved => "Preparation request saved",
            .return_boot_configured => "Return boot configured",
            .loader_ready => "Preparation environment ready",
            .transferring_control => "Starting preparation environment",
        };
    }
};

/// Stages of the micro-Linux preparation paths (extract, WIM/VHD boot,
/// chainload, XP staging). The UEFI handoff is stage 1 of these five.
pub const micro_linux_stage_count: u8 = 5;

/// Equal to boot.prep.stage.1..5 (the micro-Linux progress rows).
pub const micro_linux_labels = [_][]const u8{
    "Starting environment",
    "Verifying target device",
    "Preparing workspace",
    "Copying files",
    "Verification and finalization",
};

/// Direct Windows Vista/7 ISO start from UEFI: only these three steps run
/// before Windows PE takes over, so only these three are shown.
pub const DirectIsoStage = enum(u8) {
    validating = 1,
    loading = 2,
    starting = 3,

    pub const labels = [_][]const u8{
        "Validating installation ISO",
        "Loading Windows boot files",
        "Starting Windows Setup",
    };

    pub fn number(self: DirectIsoStage) u8 {
        return @intFromEnum(self);
    }
};

/// Windows XP from UEFI (xp_uefi_staging) and its micro-Linux staging share
/// one progress page and one stage list, from the UEFI handoff to the end
/// (tools/micro_linux_ui.sh declares the same labels). UEFI runs only stage
/// 1: it checks the XP package, loads the micro-Linux kernel and starts it;
/// the three steps are shown as the stage-1 detail.
pub const XpStage = enum(u8) {
    checking,
    loading,
    starting,

    /// Equal to boot.xp_prep.environment, boot.lx.detecting_disks,
    /// boot.xp_prep.choose_disk, boot.prep.stage.3 and boot.xp_prep.copy_verify.
    pub const labels = [_][]const u8{
        "Loading the preparation environment",
        "Detecting disks",
        "Choosing the target disk",
        "Preparing workspace",
        "Copying and verifying files",
    };

    /// All UEFI steps belong to stage 1.
    pub fn number(self: XpStage) u8 {
        _ = self;
        return 1;
    }

    /// Equal to the boot.xp_prep.checking/loading/starting catalog values.
    pub fn detail(self: XpStage) []const u8 {
        return switch (self) {
            .checking => "Checking the XP kernel, initramfs and USB drive identity",
            .loading => "Loading the micro-Linux kernel from the USB drive",
            .starting => "The kernel is loading the XP environment; the disk selection follows",
        };
    }
};

test "XP path declares its five stages and UEFI stays in stage 1" {
    try std.testing.expectEqual(@as(usize, 5), XpStage.labels.len);
    for ([_]XpStage{ .checking, .loading, .starting }) |stage| try std.testing.expectEqual(@as(u8, 1), stage.number());
}

test "direct ISO path declares exactly the stages it runs" {
    try std.testing.expectEqual(@as(usize, 3), DirectIsoStage.labels.len);
    try std.testing.expectEqual(@as(u8, 3), DirectIsoStage.starting.number());
    try std.testing.expectEqual(@as(usize, DirectIsoStage.labels.len), @typeInfo(DirectIsoStage).@"enum".fields.len);
}

test "preparation handoff stages always have a visible label" {
    const stages = [_]Stage{
        .request_saved,
        .return_boot_configured,
        .loader_ready,
        .transferring_control,
    };
    for (stages) |stage| {
        try std.testing.expect(stage.label().len > 0);
        try std.testing.expect(stage.detail().len > 0);
    }
}
