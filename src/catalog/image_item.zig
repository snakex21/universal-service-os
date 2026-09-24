const FixedText = @import("../core/fixed_text.zig").FixedText;
const ImageKind = @import("image_kind.zig").ImageKind;
const windows_media = @import("../image_probe/windows_media.zig");

pub const ImageItem = struct {
    name: FixedText,
    kind: ImageKind,
    /// What a Windows ISO contains (architecture, Setup or WinPE); filled by
    /// the UEFI image list (platform/uefi/windows_media_probe.zig), null when
    /// the image was not probed.
    media: ?windows_media.Info = null,
};
