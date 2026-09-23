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

/// Windows XP from UEFI (xp_uefi_staging): USOS checks the XP package, loads
/// the micro-Linux kernel and starts it; the kernel's EFI stub then loads the
/// initramfs and usos-fb-ui replaces this screen with the disk selection.
/// Only these three steps run before Linux takes over.
pub const XpStage = enum(u8) {
    checking = 1,
    loading = 2,
    starting = 3,

    /// Equal to the boot.xp_prep.stage.* catalog values.
    pub const labels = [_][]const u8{
        "Checking the Windows XP package",
        "Loading the preparation environment",
        "Starting the disk selection",
    };

    pub fn number(self: XpStage) u8 {
        return @intFromEnum(self);
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

test "XP path declares exactly the stages it runs" {
    try std.testing.expectEqual(@as(usize, 3), XpStage.labels.len);
    try std.testing.expectEqual(@as(usize, XpStage.labels.len), @typeInfo(XpStage).@"enum".fields.len);
    try std.testing.expectEqual(@as(u8, 3), XpStage.starting.number());
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
