const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    addHostTests(b, target, optimize);
    addHostSelftest(b, target, optimize);
    addHostImageProbe(b, target, optimize);
    const ntfs_driver = addFetchNtfsDriver(b);

    _ = addUefiApp(b, optimize, .x86_64, "usos-x86_64", "usb/EFI/BOOT/BOOTX64.EFI");
    _ = addUefiApp(b, optimize, .aarch64, "usos-aarch64", "usb/EFI/BOOT/BOOTAA64.EFI");
    addReleaseMediaLayout(b);
    const manual_image = addQemuX86ManualImage(b, optimize);
    const micro_linux = addMicroLinux(b);
    const handoff_app = addNtfsHandoffTestApp(b, optimize);
    addBootNextCompileCheck(b, optimize);
    const handoff_base = addPrepareNtfsHandoffImage(b, ntfs_driver, handoff_app);
    const handoff_overlay = addPrepareNtfsHandoffOverlay(b, handoff_base);
    addRunNtfsHandoffQemu(b, handoff_overlay);
    const e2e_base = addPrepareE2eBase(b, ntfs_driver, manual_image, micro_linux);
    _ = addPrepareE2eOverlay(b, e2e_base);
    addQemuX86TestImage(b, optimize);
    addQemuAarch64TestImage(b, optimize);
}

fn addFetchNtfsDriver(b: *std.Build) *std.Build.Step {
    const fetch = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/fetch_ntfs_driver.ps1",
        "-OutputPath",
        "zig-out/test-assets/ntfs_x64.efi",
    });
    const step = b.step("fetch-ntfs-driver", "Fetch and verify the x64 read-only NTFS UEFI driver used by the QEMU test");
    step.dependOn(&fetch.step);
    return step;
}

fn addReleaseMediaLayout(b: *std.Build) void {
    const install_media = b.addInstallDirectory(.{
        .source_dir = b.path("media"),
        .install_dir = .prefix,
        .install_subdir = "usb",
    });
    b.getInstallStep().dependOn(&install_media.step);
}

fn addHostTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const root_module = createUsosModule(b, target, optimize);
    const unit_tests = b.addTest(.{ .root_module = root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    b.default_step.dependOn(&run_unit_tests.step);
}

fn addHostImageProbe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const root_module = createUsosModule(b, target, optimize);
    const tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/image_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_module.addImport("usos", root_module);

    const exe = b.addExecutable(.{
        .name = "usos-image-probe",
        .root_module = tool_module,
    });
    b.installArtifact(exe);

    const step = b.step("image-probe-tool", "Build the host optical image inspection tool");
    step.dependOn(&exe.step);
}

fn addHostSelftest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const root_module = createUsosModule(b, target, optimize);
    const selftest_module = b.createModule(.{
        .root_source_file = b.path("src/tools/selftest_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    selftest_module.addImport("usos", root_module);

    const selftest_exe = b.addExecutable(.{
        .name = "usos-selftest",
        .root_module = selftest_module,
    });
    const run_selftest = b.addRunArtifact(selftest_exe);

    const selftest_step = b.step("selftest", "Run the same startup checks used by the OS");
    selftest_step.dependOn(&run_selftest.step);
}

fn addUefiApp(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    arch: std.Target.Cpu.Arch,
    name: []const u8,
    boot_path: []const u8,
) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .uefi,
    });
    const usos_module = createUsosModule(b, target, optimize);
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("usos", usos_module);

    const app = b.addExecutable(.{
        .name = name,
        .root_module = app_module,
    });
    b.installArtifact(app);

    const install_boot = b.addInstallFile(app.getEmittedBin(), boot_path);
    b.getInstallStep().dependOn(&install_boot.step);

    const step = b.step(name, b.fmt("Build {s} UEFI bootstrap", .{name}));
    step.dependOn(&app.step);
    return app;
}

fn addRunNtfsHandoffQemu(b: *std.Build, overlay_step: *std.Build.Step) void {
    const run = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/run_ntfs_handoff_qemu.ps1",
        "-QemuPath",
        "tools/qemu/qemu-system-x86_64.exe",
        "-ImagePath",
        "test-images/usos-handoff.qcow2",
        "-FirmwareCode",
        "tools/qemu/share/edk2-x86_64-code.fd",
        "-FirmwareVars",
        "tools/qemu/share/edk2-i386-vars.fd",
        "-OutputDir",
        "zig-out/ntfs-handoff-test/run",
        "-CaptureUntilSeconds",
        "220",
    });
    run.step.dependOn(overlay_step);
    const step = b.step("run-ntfs-handoff-qemu", "Boot the qcow2 handoff overlay and capture NTFS Windows handoff serial/screenshot evidence");
    step.dependOn(&run.step);
}

fn addPrepareNtfsHandoffImage(b: *std.Build, ntfs_driver_step: *std.Build.Step, app_step: *std.Build.Step) *std.Build.Step {
    const prepare = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/prepare_ntfs_handoff_image.ps1",
        "-IsoPath",
        "Win11_25H2_Polish_x64_v2.iso",
        "-VhdPath",
        "test-images/.staging-usos-handoff.vhd",
        "-BaseQcow2Path",
        "test-images/usos-handoff-base.qcow2",
        "-QemuImgPath",
        "tools/qemu/qemu-img.exe",
        "-BootEfiPath",
        "zig-out/bin/usos-ntfs-handoff-x86_64.efi",
        "-NtfsDriverPath",
        "zig-out/test-assets/ntfs_x64.efi",
    });
    prepare.step.dependOn(ntfs_driver_step);
    prepare.step.dependOn(app_step);
    const step = b.step("prepare-ntfs-handoff-image", "Create the qcow2 base for the GPT/ESP/DATA/WORK NTFS handoff test");
    step.dependOn(&prepare.step);
    return step;
}

fn addPrepareNtfsHandoffOverlay(b: *std.Build, base_step: *std.Build.Step) *std.Build.Step {
    const create = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/create_qcow2_overlay.ps1",
        "-QemuImgPath",
        "tools/qemu/qemu-img.exe",
        "-BasePath",
        "test-images/usos-handoff-base.qcow2",
        "-OverlayPath",
        "test-images/usos-handoff.qcow2",
    });
    create.step.dependOn(base_step);
    const step = b.step("prepare-ntfs-handoff-overlay", "Create a fresh differential qcow2 overlay for the handoff test");
    step.dependOn(&create.step);
    return step;
}

fn addMicroLinux(b: *std.Build) *std.Build.Step {
    const build_micro = b.addSystemCommand(&.{
        "python",
        "tools/build_micro_linux.py",
        "--project-root",
        ".",
        "--seven-zip",
        "C:/Program Files/7-Zip/7z.exe",
        "--output-dir",
        "zig-out/micro-linux",
    });
    const step = b.step("micro-linux", "Build the pinned Alpine kernel/initramfs and EFI loader for WORK preparation");
    step.dependOn(&build_micro.step);
    return step;
}

fn addPrepareE2eBase(b: *std.Build, ntfs_driver_step: *std.Build.Step, manual_image_step: *std.Build.Step, micro_linux_step: *std.Build.Step) *std.Build.Step {
    const prepare = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/prepare_e2e_base.ps1",
        "-IsoPath",
        "Win11_25H2_Polish_x64_v2.iso",
        "-VhdPath",
        "test-images/.staging-usos-e2e.vhd",
        "-BaseQcow2Path",
        "test-images/usos-e2e-base.qcow2",
        "-QemuImgPath",
        "tools/qemu/qemu-img.exe",
        "-BootEfiPath",
        "zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI",
        "-NtfsDriverPath",
        "zig-out/test-assets/ntfs_x64.efi",
        "-MicroLinuxKernelPath",
        "zig-out/micro-linux/vmlinuz-virt",
        "-MicroLinuxInitramfsPath",
        "zig-out/micro-linux/initramfs-usos",
        "-MicroLinuxLoaderPath",
        "zig-out/micro-linux/systemd-bootx64.efi",
        "-UnattendPath",
        "win10-11 best-ustawienia.xml",
    });
    prepare.step.dependOn(ntfs_driver_step);
    prepare.step.dependOn(manual_image_step);
    prepare.step.dependOn(micro_linux_step);
    const step = b.step("prepare-e2e-base", "Create the full-flow qcow2 base with ISO on DATA and empty identified WORK");
    step.dependOn(&prepare.step);
    return step;
}

fn addPrepareE2eOverlay(b: *std.Build, base_step: *std.Build.Step) *std.Build.Step {
    const create = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/create_qcow2_overlay.ps1",
        "-QemuImgPath",
        "tools/qemu/qemu-img.exe",
        "-BasePath",
        "test-images/usos-e2e-base.qcow2",
        "-OverlayPath",
        "test-images/usos-e2e.qcow2",
    });
    create.step.dependOn(base_step);
    const step = b.step("prepare-e2e-overlay", "Create a fresh differential qcow2 overlay for the full installation-flow test");
    step.dependOn(&create.step);
    return step;
}

fn addBootNextCompileCheck(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/boot_next_compile_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app = b.addExecutable(.{
        .name = "usos-boot-next-compile-check",
        .root_module = app_module,
    });
    const step = b.step("boot-next-compile-check", "Compile-check the UEFI BootOrder backup and BootNext implementation");
    step.dependOn(&app.step);
    b.default_step.dependOn(&app.step);
}

fn addNtfsHandoffTestApp(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/ntfs_handoff_test_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app = b.addExecutable(.{
        .name = "usos-ntfs-handoff-x86_64",
        .root_module = app_module,
    });
    const install_app = b.addInstallArtifact(app, .{});
    b.getInstallStep().dependOn(&install_app.step);

    const step = b.step("ntfs-handoff-test-app", "Build the x86_64 UEFI NTFS Windows handoff test app");
    step.dependOn(&install_app.step);
    return step;
}

fn addQemuX86ManualImage(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const usos_module = createUsosModule(b, target, optimize);
    const ps2_mouse_module = b.createModule(.{
        .root_source_file = b.path("src/arch/x86/ps2_mouse.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/manual_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("usos", usos_module);
    app_module.addImport("ps2_mouse", ps2_mouse_module);

    const app = b.addExecutable(.{
        .name = "usos-manual-x86_64",
        .root_module = app_module,
    });
    const install_boot = b.addInstallFile(app.getEmittedBin(), "manual-usb/EFI/BOOT/BOOTX64.EFI");
    const install_layout = b.addInstallDirectory(.{
        .source_dir = b.path("media"),
        .install_dir = .prefix,
        .install_subdir = "manual-usb",
    });
    const install_fixture = b.addInstallDirectory(.{
        .source_dir = b.path("testdata/media"),
        .install_dir = .prefix,
        .install_subdir = "manual-usb",
    });

    const step = b.step("qemu-x86_64-manual-image", "Build the interactive x86_64 QEMU preview image");
    step.dependOn(&install_boot.step);
    step.dependOn(&install_layout.step);
    step.dependOn(&install_fixture.step);
    return step;
}

fn addQemuX86TestImage(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const usos_module = createUsosModule(b, target, optimize);
    const qemu_exit_module = b.createModule(.{
        .root_source_file = b.path("src/arch/x86/qemu_exit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/qemu_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("usos", usos_module);
    app_module.addImport("qemu_exit", qemu_exit_module);

    const app = b.addExecutable(.{
        .name = "usos-qemu-x86_64",
        .root_module = app_module,
    });
    const install_boot = b.addInstallFile(app.getEmittedBin(), "qemu-usb/EFI/BOOT/BOOTX64.EFI");
    const install_media = b.addInstallDirectory(.{
        .source_dir = b.path("testdata/media"),
        .install_dir = .prefix,
        .install_subdir = "qemu-usb",
    });

    const step = b.step("qemu-x86_64-image", "Build the automated x86_64 QEMU test image");
    step.dependOn(&install_boot.step);
    step.dependOn(&install_media.step);
}

fn addQemuAarch64TestImage(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .uefi,
    });
    const usos_module = createUsosModule(b, target, optimize);
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/qemu_shutdown_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("usos", usos_module);

    const app = b.addExecutable(.{
        .name = "usos-qemu-aarch64",
        .root_module = app_module,
    });
    const install_boot = b.addInstallFile(app.getEmittedBin(), "qemu-arm64-usb/EFI/BOOT/BOOTAA64.EFI");
    const install_media = b.addInstallDirectory(.{
        .source_dir = b.path("testdata/media"),
        .install_dir = .prefix,
        .install_subdir = "qemu-arm64-usb",
    });

    const step = b.step("qemu-aarch64-image", "Build the automated ARM64 QEMU test image");
    step.dependOn(&install_boot.step);
    step.dependOn(&install_media.step);
}

fn createUsosModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
