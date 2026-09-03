const ImageKind = @import("image_kind.zig").ImageKind;
const DetectedSystem = @import("detected_system.zig").DetectedSystem;

pub const DiscoveredImage = struct {
    path: []const u8,
    kind: ImageKind,
    verified: bool,
    detected_system: DetectedSystem = .unknown,
};
