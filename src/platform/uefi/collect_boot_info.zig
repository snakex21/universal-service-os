const usos = @import("usos");
const framebuffer = @import("framebuffer.zig");
const memory = @import("memory.zig");

pub fn collect() !usos.boot_info.BootInfo {
    return .{
        .architecture = usos.architecture.current(),
        .firmware = .uefi,
        .framebuffer = try framebuffer.locate(),
        .memory = try memory.collectSummary(),
    };
}
