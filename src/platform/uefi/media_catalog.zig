const usos = @import("usos");
const directory_scan = @import("directory_scan.zig");
const filesystem = @import("filesystem.zig");
const system_media_scan = @import("system_media_scan.zig");

pub fn scan() usos.catalog.MediaStatus {
    var status = usos.catalog.MediaStatus{};
    const root = filesystem.openBootVolume() orelse return status;
    defer root.close() catch {};

    const windows_11 = usos.catalog.systems.findById("windows-11") orelse return status;
    const images = system_media_scan.scan(root, windows_11);
    status.windows_11.iso_count = images.iso_count;
    status.windows_11.wim_count = images.wim_count;
    status.windows_11.img_count = images.img_count;
    status.windows_11.autounattend = directory_scan.exists(root, "\\Systems\\Windows\\Windows 11\\Unattended\\autounattend.xml");
    status.windows_11.unattend = directory_scan.exists(root, "\\Systems\\Windows\\Windows 11\\Unattended\\unattend.xml");
    status.program_files = directory_scan.countFiles(root, "\\Programs");

    return status;
}
