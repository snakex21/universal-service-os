const std = @import("std");
const uefi = std.os.uefi;
const builtin = @import("builtin");
const case_path = @import("case_path.zig");
const work_boot_path = @import("work_boot_path.zig");

const marker = std.unicode.utf8ToUtf16LeStringLiteral("\\.usos-work");
const usos = @import("usos");

pub const Found = struct {
    handle: uefi.Handle,
    /// sources/install.wim, install.esd or install.swm (the formats Windows
    /// Setup and tools/extract.sh accept); null when none is present.
    install_image: ?[]const u8,
    /// A UEFI boot entry exists (EFI/USOS-WORK, or the legacy EFI/BOOT).
    has_windows_boot: bool,
    /// The entry was found only at the legacy EFI/BOOT path.
    legacy_boot_path: bool,
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

        const install_image = usos.image_probe.windows_detect.firstInstallImage(root, existsCaseInsensitive);
        const boot = work_boot_path.select(work_boot_path.candidates, root, existsCaseInsensitive);
        return .{
            .handle = handle,
            .install_image = install_image,
            .has_windows_boot = boot != null,
            .legacy_boot_path = if (boot) |selected| selected.legacy else false,
        };
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
