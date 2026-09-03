const std = @import("std");

pub const Stage = enum {
    request_saved,
    return_boot_configured,
    loader_ready,
    transferring_control,

    pub fn label(self: Stage) []const u8 {
        return switch (self) {
            .request_saved => "Preparation request saved",
            .return_boot_configured => "Return boot configured",
            .loader_ready => "Micro-Linux loader ready",
            .transferring_control => "Starting micro-Linux kernel",
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
    for (stages) |stage| try std.testing.expect(stage.label().len > 0);
}
