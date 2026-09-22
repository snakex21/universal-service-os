const uefi = @import("std").os.uefi;
const usos = @import("usos");
const catalog_ntfs_directory_source = @import("catalog_ntfs_directory_source.zig");
const data_volume = @import("data_volume.zig");
const filesystem = @import("filesystem.zig");
const serial = @import("serial.zig");

fn say(text: []const u8) void {
    serial.writeAscii(text);
}

pub fn main() uefi.Status {
    serial.init();
    say("USOS UEFI NTFS CATALOG PROBE\n");
    const esp_root = filesystem.openBootVolume() orelse {
        say("ESP OPEN FAIL\n");
        return .not_found;
    };
    defer esp_root.close() catch {};

    var data_catalog = data_volume.openCatalog() catch |err| {
        say("DATA OPEN FAIL: ");
        say(@errorName(err));
        say("\n");
        return .not_found;
    };
    say("DATA BLOCKIO NTFS PASS\n");

    var adapter = catalog_ntfs_directory_source.Adapter.init(data_catalog.fs, data_catalog.reader());
    var discovery = usos.catalog.media_discovery.Discovery.init(adapter.source());
    const xp = discovery.mediaStatus("\\Systems\\Windows\\Windows XP\\Images");
    const win11 = discovery.mediaStatus("\\Systems\\Windows\\Windows 11\\Images");
    if (xp.iso_count != 1) {
        say("XP DISCOVERY FAIL\n");
        return .not_found;
    }
    if (win11.iso_count != 1) {
        say("WIN11 DISCOVERY FAIL\n");
        return .not_found;
    }
    say("XP IMAGES=1\n");
    say("WIN11 IMAGES=1\n");
    say("UEFI NTFS CATALOG PASS\n");
    return .success;
}
