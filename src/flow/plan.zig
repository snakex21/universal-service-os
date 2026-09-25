//! The plan: what a selection will run, derived from its OS profile
//! (refactor M2, docs/design/refactor-os-pipeline.md 2.4 and 2.6).
//!
//!   Plan              profile, progress rows and the `plan_*` keys written
//!                     to install-state.ini for the micro-Linux preparation
//!   WimbootPlan       ordered list of the files the UEFI menu puts in the
//!                     wimboot RAM disk for the native Windows starts
//!                     (src/platform/uefi/windows_native_iso.zig executes it)
//!
//! Pure data, no UEFI calls: tested on the host and pinned by
//! src/flow/testdata/routing_golden.tsv. The micro-Linux side does not read
//! the plan keys yet (M3); they are additive, `ini_value` in
//! tools/micro_linux_init.sh matches exact keys only.
const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;
const Firmware = @import("../core/firmware.zig").Firmware;
const os_profiles = @import("../catalog/os_profiles.zig");
const Backend = @import("preparation_capability.zig").Backend;
const boot_progress = @import("preparation_boot_progress.zig");

/// Progress rows of a profile's progress page.
pub fn stageLabels(progress: os_profiles.Progress) []const []const u8 {
    return switch (progress) {
        .none, .core, .efi_image => &.{},
        .micro_linux => &boot_progress.micro_linux_labels,
        .direct_iso => &boot_progress.DirectIsoStage.labels,
        .xp_uefi => &boot_progress.XpStage.labels,
    };
}

pub const version = 1;

pub const Plan = struct {
    profile: *const os_profiles.Profile,
    system_id: []const u8,

    pub fn backend(self: Plan) Backend {
        return self.profile.backend.?;
    }

    pub fn labels(self: Plan) []const []const u8 {
        return stageLabels(self.profile.progress);
    }

    /// Lines appended to install-state.ini (CRLF, like the rest of the file).
    pub fn stateKeys(self: Plan, buffer: []u8) ![]const u8 {
        var used: usize = 0;
        used += (try std.fmt.bufPrint(buffer[used..], "plan_version={d}\r\nplan_profile={s}\r\nplan_progress={s}\r\nplan_stages=", .{ version, self.profile.id, @tagName(self.profile.progress) })).len;
        for (self.labels(), 0..) |label, index| {
            used += (try std.fmt.bufPrint(buffer[used..], "{s}{s}", .{ if (index == 0) "" else "|", label })).len;
        }
        used += (try std.fmt.bufPrint(buffer[used..], "\r\n", .{})).len;
        return buffer[0..used];
    }
};

/// Plan for a selection, or null when the profile table refuses it.
pub fn make(system: *const SystemEntry, image: ImageKind, method: BootMethod, firmware: ?Firmware) ?Plan {
    const profile = os_profiles.select(system, image, method, firmware) orelse return null;
    if (profile.backend == null) return null;
    return .{ .profile = profile, .system_id = system.id };
}

// ------------------------------------------------------------ wimboot plan

pub const flag_content = "1\r\n";
pub const support_path = "\\EFI\\USOS\\windows-native\\support.cpio";

pub const WimbootKind = enum {
    /// Windows 10/11 Setup from the ISO's own WinPE.
    modern_setup,
    /// A WinPE / rescue ISO booted as it is (no USOS helper).
    winpe,
    win7,
    vista,
};

pub const Injection = union(enum) {
    /// A USOS support archive from the ESP, unpacked into the RAM disk.
    support: struct { path: []const u8, limit_mib: usize },
    /// A marker file with `flag_content`.
    flag: []const u8,
    /// usos-drivers.bin: bundled Drivers/x64 packages plus DATA\Drivers (Win7).
    bundled_drivers,
    /// usos-drivers.bin from DATA\Drivers\<folder>, only when there is one.
    user_drivers: []const u8,
    /// usos-source.ini binding the DATA partition, size and ISO path.
    source_ini: []const u8,
    /// usos-unattend.xml from Systems\Windows\<folder>\Unattended.
    answer: []const u8,
    /// BCD, boot.sdi and boot.wim from the boot ISO.
    boot_files,
};

pub const WimbootOptions = struct {
    kind: WimbootKind,
    /// Windows 10/11: the DATA system folder (Windows 10, Windows 11).
    folder: []const u8 = "",
    answer: bool = false,
    /// Windows 7/Vista inspection results.
    external_pe10: bool = false,
    nvme_packages: bool = false,
};

pub const WimbootPlan = struct {
    items: [12]Injection = undefined,
    len: usize = 0,

    fn add(self: *WimbootPlan, item: Injection) void {
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn slice(self: *const WimbootPlan) []const Injection {
        return self.items[0..self.len];
    }
};

/// The RAM-disk contents in the order the menu adds them. The order is the
/// one the hardware-tested builds used; changing it is a behaviour change.
pub fn wimbootPlan(options: WimbootOptions) WimbootPlan {
    var plan = WimbootPlan{};
    switch (options.kind) {
        .winpe => plan.add(.boot_files),
        .modern_setup => {
            plan.add(.{ .support = .{ .path = support_path, .limit_mib = 8 } });
            plan.add(.{ .support = .{ .path = "\\EFI\\USOS\\windows-native\\modern-support.cpio", .limit_mib = 8 } });
            plan.add(.{ .flag = "usos-modern-uefi.flag" });
            plan.add(.{ .user_drivers = options.folder });
            plan.add(.{ .source_ini = options.folder });
            if (options.answer) plan.add(.{ .answer = options.folder });
            plan.add(.boot_files);
        },
        .win7, .vista => {
            const vista = options.kind == .vista;
            plan.add(.{ .support = .{ .path = support_path, .limit_mib = 8 } });
            plan.add(.{ .support = .{ .path = if (vista) "\\EFI\\USOS\\windows-native\\vista-support.cpio" else "\\EFI\\USOS\\windows-native\\win7-support.cpio", .limit_mib = 64 } });
            plan.add(.{ .flag = if (vista) "usos-modern-vista.flag" else "usos-modern-win7.flag" });
            if (options.external_pe10) plan.add(.{ .flag = "usos-external-pe10.flag" });
            if (options.nvme_packages) plan.add(.{ .flag = "usos-nvme-packages.flag" });
            if (!vista) plan.add(.bundled_drivers);
            plan.add(.boot_files);
            plan.add(.{ .source_ini = if (vista) "Windows Vista" else "Windows 7" });
            // The answer file folder is "Windows 7" for both (Vista refuses one first).
            if (options.answer) plan.add(.{ .answer = "Windows 7" });
        },
    }
    return plan;
}

/// One line per injection, for golden files and serial logs.
pub fn describe(item: Injection, buffer: []u8) ![]const u8 {
    return switch (item) {
        .support => |s| std.fmt.bufPrint(buffer, "support {s} limit={d}MiB", .{ s.path, s.limit_mib }),
        .flag => |name| std.fmt.bufPrint(buffer, "flag {s}", .{name}),
        .bundled_drivers => std.fmt.bufPrint(buffer, "drivers usos-drivers.bin bundled+user", .{}),
        .user_drivers => |folder| std.fmt.bufPrint(buffer, "drivers usos-drivers.bin user Drivers\\{s} (if any)", .{folder}),
        .source_ini => |folder| std.fmt.bufPrint(buffer, "file usos-source.ini folder={s}", .{folder}),
        .answer => |folder| std.fmt.bufPrint(buffer, "file usos-unattend.xml from Systems\\Windows\\{s}\\Unattended", .{folder}),
        .boot_files => std.fmt.bufPrint(buffer, "boot BCD boot.sdi boot.wim", .{}),
    };
}

test "Windows 10/11 plan: helpers, drivers, source, answer, then the boot files" {
    const plan = wimbootPlan(.{ .kind = .modern_setup, .folder = "Windows 10", .answer = true });
    const items = plan.slice();
    try std.testing.expectEqual(@as(usize, 7), items.len);
    try std.testing.expectEqualStrings("usos-modern-uefi.flag", items[2].flag);
    try std.testing.expectEqualStrings("Windows 10", items[5].answer);
    try std.testing.expect(items[6] == .boot_files);
    try std.testing.expectEqual(@as(usize, 6), wimbootPlan(.{ .kind = .modern_setup, .folder = "Windows 11" }).len);
}

test "WinPE ISOs get only their own boot files" {
    const plan = wimbootPlan(.{ .kind = .winpe });
    try std.testing.expectEqual(@as(usize, 1), plan.len);
    try std.testing.expect(plan.items[0] == .boot_files);
}

test "Vista never gets the Windows 7 driver archive" {
    for (wimbootPlan(.{ .kind = .vista, .external_pe10 = true }).slice()) |item| try std.testing.expect(item != .bundled_drivers);
    const win7 = wimbootPlan(.{ .kind = .win7, .nvme_packages = true, .answer = true });
    try std.testing.expectEqualStrings("usos-nvme-packages.flag", win7.items[3].flag);
    try std.testing.expect(win7.items[4] == .bundled_drivers);
    try std.testing.expectEqualStrings("Windows 7", win7.items[win7.len - 1].answer);
}

test "plan keys for the WORK preparation name the profile and its stages" {
    const systems = @import("../catalog/systems.zig");
    const plan = make(systems.findById("windows-10").?, .iso, .chainload, .uefi).?;
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "plan_version=1\r\nplan_profile=iso-work-chainload\r\nplan_progress=micro_linux\r\nplan_stages=Starting environment|Verifying target device|Preparing workspace|Copying files|Verification and finalization\r\n",
        try plan.stateKeys(&buffer),
    );
    try std.testing.expect(make(systems.findById("windows-xp").?, .iso, .chainload, .uefi) == null);
}
