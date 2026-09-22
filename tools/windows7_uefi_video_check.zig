// UefiSeven's continuation verifies its installed handler and returns to Core.
// No Windows boot manager, disk extraction or preparation reboot is involved.
const std = @import("std");
const video = @import("windows7_video");
pub fn main() std.os.uefi.Status {
    return if (video.handlerValid()) .success else .unsupported;
}
