const std = @import("std");
const DiscoveredImage = @import("../catalog/discovered_image.zig").DiscoveredImage;
const SystemFamily = @import("../catalog/system_family.zig").SystemFamily;
const DetectedSystem = @import("../catalog/detected_system.zig").DetectedSystem;

pub const Step = enum {
    verify_image,
    extract_installer_to_working_area,
    prepare_boot_files,
    handoff_to_installer,
};

pub const Plan = struct {
    steps: [4]Step = undefined,
    len: usize = 0,

    pub fn append(self: *Plan, step: Step) void {
        self.steps[self.len] = step;
        self.len += 1;
    }

    pub fn slice(self: *const Plan) []const Step {
        return self.steps[0..self.len];
    }
};

pub const PlanError = error{
    UnverifiedImage,
    UnrecognizedSystem,
    UnsupportedFlow,
};

pub fn build(family: SystemFamily, image: DiscoveredImage) PlanError!Plan {
    if (!image.verified) return error.UnverifiedImage;

    var plan = Plan{};
    plan.append(.verify_image);

    switch (family) {
        .windows, .windows_legacy, .windows_beta => {
            if (image.kind != .iso and image.kind != .wim) return error.UnsupportedFlow;
            if (image.kind == .iso and !isWindows(image.detected_system)) return error.UnrecognizedSystem;
            plan.append(.extract_installer_to_working_area);
            plan.append(.prepare_boot_files);
            plan.append(.handoff_to_installer);
        },
        else => return error.UnsupportedFlow,
    }

    return plan;
}

fn isWindows(system: DetectedSystem) bool {
    return switch (system) {
        .windows_modern, .windows_legacy => true,
        .unknown => false,
    };
}

test "Windows ISO flow is extraction based and contains no block-device action" {
    const image = DiscoveredImage{ .path = "Windows.iso", .kind = .iso, .verified = true, .detected_system = .windows_modern };
    const plan = try build(.windows, image);

    try std.testing.expectEqualSlices(Step, &.{
        .verify_image,
        .extract_installer_to_working_area,
        .prepare_boot_files,
        .handoff_to_installer,
    }, plan.slice());
}

test "flow refuses unverified image" {
    const image = DiscoveredImage{ .path = "bad.iso", .kind = .iso, .verified = false };
    try std.testing.expectError(error.UnverifiedImage, build(.windows, image));
}

test "valid ISO with unknown contents cannot enter Windows flow" {
    const image = DiscoveredImage{ .path = "ubuntu.iso", .kind = .iso, .verified = true, .detected_system = .unknown };
    try std.testing.expectError(error.UnrecognizedSystem, build(.windows, image));
}

test "stage one does not invent unsupported Linux installation flow" {
    const image = DiscoveredImage{ .path = "linux.iso", .kind = .iso, .verified = true };
    try std.testing.expectError(error.UnsupportedFlow, build(.linux, image));
}
