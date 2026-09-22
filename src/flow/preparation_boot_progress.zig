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
            .request_saved => "PREPARATION REQUEST SAVED",
            .return_boot_configured => "RETURN BOOT CONFIGURED",
            .loader_ready => "PREPARATION ENVIRONMENT READY",
            .transferring_control => "STARTING PREPARATION ENVIRONMENT",
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
        "VALIDATING INSTALLATION ISO",
        "LOADING WINDOWS BOOT FILES",
        "STARTING WINDOWS SETUP",
    };

    pub fn number(self: DirectIsoStage) u8 {
        return @intFromEnum(self);
    }
};

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
