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
