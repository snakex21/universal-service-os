const media_catalog = @import("media_catalog.zig");

pub fn isDetected() bool {
    const status = media_catalog.scan();
    return status.windows_11.iso_count == 1 and
        status.windows_11.wim_count == 1 and
        status.windows_11.img_count == 1 and
        status.windows_11.autounattend and
        !status.windows_11.unattend and
        status.program_files == 1;
}
