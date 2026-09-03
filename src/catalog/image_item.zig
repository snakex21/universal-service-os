const FixedText = @import("../core/fixed_text.zig").FixedText;
const ImageKind = @import("image_kind.zig").ImageKind;

pub const ImageItem = struct {
    name: FixedText,
    kind: ImageKind,
};
