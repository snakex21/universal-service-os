const std = @import("std");
const uefi = std.os.uefi;
const builtin = @import("builtin");
const case_path = @import("case_path.zig");

const marker = std.unicode.utf8ToUtf16LeStringLiteral("\\.usos-work");
const install_wim = "sources/install.wim";
fn bootPath() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "EFI/BOOT/BOOTX64.EFI",
        .aarch64 => "EFI/BOOT/BOOTAA64.EFI",
        .x86 => "EFI/BOOT/BOOTIA32.EFI",
        else => "EFI/BOOT/BOOTX64.EFI",
    };
}

pub const Found = struct {
    handle: uefi.Handle,
    has_install_wim: bool,
    has_windows_boot: bool,
};

pub fn find() ?Found {
    const boot_services = uefi.system_table.boot_services orelse return null;
    const handles = (boot_services.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.SimpleFileSystem.guid }) catch return null) orelse return null;

    for (handles) |handle| {
        const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, handle) catch continue) orelse continue;
        const root = fs.openVolume() catch continue;
        defer root.close() catch {};

        const tag = root.open(marker, .read, .{}) catch continue;
        tag.close() catch {};

        const has_install_wim = existsCaseInsensitive(root, install_wim);
        const has_windows_boot = existsCaseInsensitive(root, bootPath());
        return .{ .handle = handle, .has_install_wim = has_install_wim, .has_windows_boot = has_windows_boot };
    }
    return null;
}

fn existsCaseInsensitive(root: *uefi.protocol.File, requested_path: []const u8) bool {
    var resolved_storage: [case_path.max_path_units + 1:0]u16 = undefined;
    const resolved = case_path.resolve(root, requested_path, &resolved_storage) catch return false;
    const file = root.open(resolved.ptr, .read, .{}) catch return false;
    file.close() catch {};
    return true;
}
