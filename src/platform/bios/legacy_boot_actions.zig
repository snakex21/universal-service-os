const std = @import("std");
const storage = @import("storage");
const catalog = @import("catalog");
const boot_method_model = catalog.boot_method_model;
const linux_load_probe = @import("linux_load_probe.zig");
const windows_native_iso = @import("windows_native_iso.zig");
const dos_native_iso = @import("dos_native_iso.zig");
const dos6_native_iso = @import("dos6_native_iso.zig");
const vbe_probe = @import("vbe_probe.zig");

const fat32 = storage.fat32;
const random_reader = storage.random_reader;

pub const Context = struct {
    esp_fs: fat32.FileSystem,
    reader: random_reader.Reader,
    bulk_reader: random_reader.Reader,
    esp_part_guid_disk: [16]u8,
    bios_boot_drive: u8,
};

pub const Error = linux_load_probe.Error || windows_native_iso.Error || error{
    BackendUnavailable,
};

pub fn execute(
    context: Context,
    backend: boot_method_model.Backend,
    system_id: []const u8,
    image_name: []const u8,
    unattended_name: ?[]const u8,
    graphics: ?vbe_probe.Session,
) !void {
    switch (backend) {
        .linux_live_iso => try @import("linux_live_iso.zig").run(context.reader, context.bulk_reader, image_name, graphics),
        .dos_bios_iso => try dos6_native_iso.run(context.esp_fs, context.reader, context.bulk_reader, context.bios_boot_drive, graphics, system_id, image_name),
        .win9x_dos => try dos_native_iso.run(context.esp_fs, context.reader, context.bulk_reader, context.bios_boot_drive, graphics, image_name),
        .windows_bios_iso => {
            // Read the selected ISO while the BIOS is still intact.
            const is_windows10 = std.mem.eql(u8, system_id, "windows-10");
            if (is_windows10 or std.mem.eql(u8, system_id, "windows-vista")) {
                try windows_native_iso.run(context.esp_fs, context.reader, context.bulk_reader, context.bios_boot_drive, graphics, if (is_windows10) .windows10 else .vista, image_name, unattended_name);
            }
            try linux_load_probe.runWindowsIso(context.esp_fs, context.reader, context.bulk_reader, context.esp_part_guid_disk, context.bios_boot_drive, graphics, system_id, image_name, unattended_name);
        },
        .xp_staging => try linux_load_probe.runXpStaging(
            context.esp_fs,
            context.reader,
            context.bulk_reader,
            context.esp_part_guid_disk,
            context.bios_boot_drive,
            graphics,
            system_id,
            image_name,
            unattended_name,
        ),
        else => return error.BackendUnavailable,
    }
}
