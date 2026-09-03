const std = @import("std");
const usos = @import("usos");
const directory_scan = @import("directory_scan.zig");

pub fn scan(root: *std.os.uefi.protocol.File, entry: *const usos.catalog.SystemEntry) usos.catalog.SystemMediaStatus {
    var status = usos.catalog.SystemMediaStatus{};
    status.iso_count = directory_scan.countFilesWithExtension(root, entry.image_directory, ".iso");
    status.wim_count = directory_scan.countFilesWithExtension(root, entry.image_directory, ".wim");
    status.img_count = directory_scan.countFilesWithExtension(root, entry.image_directory, ".img");
    status.vhd_count = directory_scan.countFilesWithExtension(root, entry.image_directory, ".vhd");
    status.vhdx_count = directory_scan.countFilesWithExtension(root, entry.image_directory, ".vhdx");
    status.efi_count = directory_scan.countFilesWithExtension(root, entry.image_directory, ".efi");

    if (entry.unattended_directory) |directory| {
        status.unattended_files = directory_scan.countFiles(root, directory);
    }

    return status;
}
