//! Provisional routes remain available to host tests. The menu explains these
//! installation limits before questions, staging files or a preparation reboot.
const std = @import("std");

pub fn reason(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "windows-embedded-standard-7"))
        return "WES7 requires Image Builder Wizard (IBW) and DS/Packages; installing only Embedded Core is not supported.";
    if (std.mem.eql(u8, id, "windows-flp"))
        return "FLP needs its own WinPE and WinFLP.wim installer integration.";
    if (std.mem.eql(u8, id, "citrix-winframe-1-8"))
        return "WinFrame needs its own Setup and Citrix licensing integration.";
    if (std.mem.eql(u8, id, "windows-nashville"))
        return "Nashville 999 requires an existing Windows installation and a root-directory upgrade adapter.";
    if (std.mem.eql(u8, id, "windows-longhorn"))
        return "Longhorn needs a build-specific WIM and Setup integration.";
    for ([_][]const u8{ "windows-whistler", "windows-neptune", "windows-2000-beta" }) |known|
        if (std.mem.eql(u8, id, known)) return "Driver and loader compatibility patches are not validated for this NT5 beta build.";
    for ([_][]const u8{ "windows-chicago", "windows-memphis", "windows-nt-3-beta", "windows-nt-4-beta", "windows-cairo" }) |known|
        if (std.mem.eql(u8, id, known)) return "This beta needs build-specific Setup and compatibility validation.";
    return null;
}

pub fn requireSupported(id: []const u8) !void {
    if (reason(id) != null) return error.InstallationNotValidated;
}

test "provisional variants fail before preparation; working routes stay open" {
    for ([_][]const u8{ "windows-embedded-standard-7", "windows-flp", "citrix-winframe-1-8", "windows-nashville", "windows-longhorn", "windows-whistler", "windows-neptune", "windows-2000-beta", "windows-chicago", "windows-memphis", "windows-nt-3-beta", "windows-nt-4-beta", "windows-cairo" }) |id|
        try std.testing.expectError(error.InstallationNotValidated, requireSupported(id));
    for ([_][]const u8{ "windows-embedded-posready-7", "windows-7-beta", "windows-millennium", "windows-xp", "windows-2000", "windows-98-se", "windows-nt-4" }) |id|
        try requireSupported(id);
}
