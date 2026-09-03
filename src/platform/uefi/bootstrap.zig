const std = @import("std");
const usos = @import("usos");
const collect_boot_info = @import("collect_boot_info.zig");
const console = @import("console.zig");
const log = @import("log.zig");
const media_catalog = @import("media_catalog.zig");

fn reportCheck(name: []const u8, ok: bool) void {
    log.writeAscii("[");
    log.writeAscii(if (ok) "PASS" else "FAIL");
    log.writeAscii("] ");
    log.writeAscii(name);
    log.writeAscii("\n");
}

fn writeUnsigned(value: u64) void {
    var buffer: [20]u8 = undefined;
    log.writeAscii(usos.decimal.u64ToAscii(&buffer, value));
}

fn writeArchitecture(architecture: usos.architecture.Architecture) void {
    log.writeAscii(switch (architecture) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .aarch64 => "ARM64",
        .unsupported => "unsupported",
    });
}

fn writeMediaStatus(status: usos.catalog.MediaStatus) void {
    log.writeAscii("Windows 11 images: ISO=");
    writeUnsigned(status.windows_11.iso_count);
    log.writeAscii(" WIM=");
    writeUnsigned(status.windows_11.wim_count);
    log.writeAscii(" IMG=");
    writeUnsigned(status.windows_11.img_count);
    log.writeAscii("\nWindows 11 autounattend.xml: ");
    log.writeAscii(if (status.windows_11.autounattend) "yes" else "no");
    log.writeAscii("\nWindows 11 unattend.xml: ");
    log.writeAscii(if (status.windows_11.unattend) "yes" else "no");
    log.writeAscii("\nProgram files: ");
    writeUnsigned(status.program_files);
    log.writeAscii("\n\n");
}

fn writeBootInfo(info: usos.boot_info.BootInfo) void {
    log.writeAscii("Architecture: ");
    writeArchitecture(info.architecture);
    log.writeAscii("\nMemory: ");
    writeUnsigned(info.memory.conventional_bytes / (1024 * 1024));
    log.writeAscii(" MiB conventional\nMemory descriptors: ");
    writeUnsigned(info.memory.descriptor_count);
    log.writeAscii("\nFramebuffer: ");

    if (info.framebuffer) |fb| {
        writeUnsigned(fb.width);
        log.writeAscii("x");
        writeUnsigned(fb.height);
    } else {
        log.writeAscii("unavailable");
    }
    log.writeAscii("\n\n");
}

pub fn run() std.os.uefi.Status {
    console.clear();
    log.writeAscii("Universal Service OS\n");
    log.writeAscii("UEFI bootstrap\n");

    const info = collect_boot_info.collect() catch {
        log.writeAscii("BOOT INFO FAIL\n");
        return .aborted;
    };
    writeBootInfo(info);
    writeMediaStatus(media_catalog.scan());

    const decision = usos.startup.validate(reportCheck);
    return switch (decision) {
        .continue_boot => blk: {
            log.writeAscii("\nBOOTSTRAP PASS\n");
            break :blk .success;
        },
        .halt => blk: {
            log.writeAscii("\nBOOTSTRAP FAIL\n");
            break :blk .aborted;
        },
    };
}
