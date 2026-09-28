const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    addHostTests(b, target, optimize);
    addHostSelftest(b, target, optimize);
    addHostImageProbe(b, target, optimize);
    addHostUiPreview(b, target, optimize);
    addHostAnswerTool(b, target, optimize);
    addHostLegacyFat32Probe(b, target, optimize);
    addHostLegacyNtfsProbe(b, target, optimize);
    const ntfs_driver = addFetchNtfsDriver(b);

    const x86_64_app = addInteractiveX86UefiApp(b, optimize);
    _ = addBootstrapUefiApp(b, optimize, .aarch64, "usos-aarch64", "usb/EFI/BOOT/BOOTAA64.EFI");
    addReleaseMediaLayout(b);
    addLinuxIsoHelper(b);
    const manual_image = addQemuX86ManualImage(b, x86_64_app);
    const framebuffer_ui = addFramebufferUi(b, optimize);
    const micro_linux = addMicroLinux(b, framebuffer_ui);
    const handoff_app = addNtfsHandoffTestApp(b, optimize);
    _ = addGptNoBlockIoProbeApp(b, optimize);
    _ = addSecureBootProbeApp(b, optimize);
    _ = addUefiNtfsCatalogProbeApp(b, optimize);
    addBootNextCompileCheck(b, optimize);
    const handoff_base = addPrepareNtfsHandoffImage(b, ntfs_driver, handoff_app);
    const handoff_overlay = addPrepareNtfsHandoffOverlay(b, handoff_base);
    addRunNtfsHandoffQemu(b, handoff_overlay);
    const e2e_base = addPrepareE2eBase(b, ntfs_driver, manual_image, micro_linux);
    _ = addPrepareE2eOverlay(b, e2e_base);
    addDirectEfiValidationFixture(b, optimize);
    addUefiDriverFixtures(b, optimize);
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

/// /usos/init (docs/design/linux-iso-boot.md): static x86_64 Linux helper
/// packed into EFI/USOS/linux/usos-linux.cpio, appended by the menu/Core to a
/// distro initramfs when a Linux ISO boots from DATA.
fn addLinuxIsoHelper(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none });
    const map_module = b.createModule(.{
        .root_source_file = b.path("src/flow/linux_iso/iso_map.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/platform/linux/iso_init_main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    module.addImport("iso_map", map_module);
    const exe = b.addExecutable(.{ .name = "usos-init", .root_module = module, .linkage = .static });
    const install_exe = b.addInstallFile(exe.getEmittedBin(), "linux-iso/usos-init");
    const pack = b.addSystemCommand(&.{ "python", "tools/build_linux_iso_helper.py", "--init" });
    pack.addFileArg(exe.getEmittedBin());
    pack.addArgs(&.{ "--out", "zig-out/usb/EFI/USOS/linux/usos-linux.cpio", "--out", "zig-out/manual-usb/EFI/USOS/linux/usos-linux.cpio" });
    pack.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&pack.step);
    const step = b.step("linux-iso-helper", "Build /usos/init and EFI/USOS/linux/usos-linux.cpio");
    step.dependOn(&pack.step);
}

fn addHostTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const root_module = createUsosModule(b, target, optimize);
    const unit_tests = b.addTest(.{ .root_module = root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const framebuffer_test_module = b.createModule(.{
        .root_source_file = b.path("src/platform/linux/fb_ui_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    framebuffer_test_module.addImport("usos", createUsosModule(b, target, optimize));
    const framebuffer_tests = b.addTest(.{ .root_module = framebuffer_test_module });
    const run_framebuffer_tests = b.addRunArtifact(framebuffer_tests);

    // UEFI-side policy modules that belong to the UEFI executables' root
    // module (so they cannot be imported from src/root.zig as well).
    const work_boot_path_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/work_boot_path.zig"),
        .target = target,
        .optimize = optimize,
    });
    const work_boot_path_tests = b.addTest(.{ .root_module = work_boot_path_module });
    const run_work_boot_path_tests = b.addRunArtifact(work_boot_path_tests);

    // Legacy BIOS menu rows (named "catalog"/"graphics" imports like the Core).
    const bios_image_rows_module = b.createModule(.{
        .root_source_file = b.path("src/platform/bios/image_rows.zig"),
        .target = target,
        .optimize = optimize,
    });
    bios_image_rows_module.addImport("catalog", b.createModule(.{ .root_source_file = b.path("src/catalog_module.zig"), .target = target, .optimize = optimize }));
    bios_image_rows_module.addImport("graphics", b.createModule(.{ .root_source_file = b.path("src/legacy_graphics_module.zig"), .target = target, .optimize = optimize }));
    const run_bios_image_rows_tests = b.addRunArtifact(b.addTest(.{ .root_module = bios_image_rows_module }));

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_bios_image_rows_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_framebuffer_tests.step);
    test_step.dependOn(&run_work_boot_path_tests.step);

    // Tests inside UEFI-application files (these belong to the UEFI root
    // module, so src/root.zig cannot import them). Only their pure parts are
    // analysed on the host; nothing here calls UEFI services.
    const uefi_test_files = [_][]const u8{
        "src/platform/uefi/case_path.zig",
        "src/platform/uefi/path.zig",
        "src/platform/uefi/wimboot_files.zig",
        "src/platform/uefi/windows_native_iso.zig",
        "src/platform/uefi/windows_user_drivers.zig",
        "src/platform/uefi/theme_editor.zig",
        "src/platform/uefi/xp_preparation.zig",
        "src/platform/uefi/vista_preparation.zig",
        "src/platform/uefi/uefi_shell.zig",
        "tools/windows7_uefi_trace.zig",
        "tools/windows7_vga_routing.zig",
        "tools/windows7_gop_retry.zig",
    };
    for (uefi_test_files) |file| {
        const module = b.createModule(.{ .root_source_file = b.path(file), .target = target, .optimize = optimize });
        module.addImport("usos", createUsosModule(b, target, optimize));
        const run = b.addRunArtifact(b.addTest(.{ .root_module = module }));
        test_step.dependOn(&run.step);
    }
    b.default_step.dependOn(&run_unit_tests.step);
    b.default_step.dependOn(&run_framebuffer_tests.step);
    b.default_step.dependOn(&run_work_boot_path_tests.step);
}

fn addHostUiPreview(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/ui_preview_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_module.addImport("usos", createUsosModule(b, target, optimize));
    const exe = b.addExecutable(.{ .name = "usos-ui-preview", .root_module = tool_module });
    const install = b.addInstallArtifact(exe, .{});
    const step = b.step("ui-preview", "Build the host boot menu preview renderer (writes BMP screens)");
    step.dependOn(&install.step);
}

fn addHostAnswerTool(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/answer_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_module.addImport("usos", createUsosModule(b, target, optimize));
    const exe = b.addExecutable(.{ .name = "usos-answer", .root_module = tool_module });
    const install = b.addInstallArtifact(exe, .{});
    const step = b.step("answer-tool", "Build the host answer renderer (usos-answer: profile -> WINNT.SIF settings / autounattend.xml)");
    step.dependOn(&install.step);
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

fn addHostLegacyFat32Probe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const root_module = createUsosModule(b, target, optimize);
    const tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/legacy_fat32_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_module.addImport("usos", root_module);
    const exe = b.addExecutable(.{
        .name = "usos-legacy-fat32-probe",
        .root_module = tool_module,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    const step = b.step("legacy-fat32-probe", "Build the host probe for the Legacy BIOS GPT/FAT32 reader");
    step.dependOn(&install_exe.step);
}

fn addHostLegacyNtfsProbe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const storage_module = b.createModule(.{
        .root_source_file = b.path("src/storage/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const catalog_module = b.createModule(.{
        .root_source_file = b.path("src/catalog_module.zig"),
        .target = target,
        .optimize = optimize,
    });
    const adapter_module = b.createModule(.{
        .root_source_file = b.path("src/platform/bios/catalog_ntfs_directory_source.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter_module.addImport("storage", storage_module);
    adapter_module.addImport("catalog", catalog_module);

    const tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/legacy_ntfs_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_module.addImport("storage", storage_module);
    tool_module.addImport("catalog", catalog_module);
    tool_module.addImport("ntfs_directory_source", adapter_module);
    const exe = b.addExecutable(.{
        .name = "usos-legacy-ntfs-probe",
        .root_module = tool_module,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    const step = b.step("legacy-ntfs-probe", "Build the host probe for the Legacy BIOS NTFS reader");
    step.dependOn(&install_exe.step);

    const physical_tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/physical_ntfs_catalog_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    physical_tool_module.addImport("storage", storage_module);
    physical_tool_module.addImport("catalog", catalog_module);
    physical_tool_module.addImport("ntfs_directory_source", adapter_module);
    const physical_exe = b.addExecutable(.{
        .name = "usos-physical-ntfs-catalog-probe",
        .root_module = physical_tool_module,
    });
    const install_physical = b.addInstallArtifact(physical_exe, .{});
    const physical_step = b.step("physical-ntfs-catalog-probe", "Build the read-only host probe for NTFS discovery on a physical USOS disk");
    physical_step.dependOn(&install_physical.step);

    const native_tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/windows_native_io_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_tool_module.addImport("storage", storage_module);
    native_tool_module.addImport("catalog", catalog_module);
    const native_exe = b.addExecutable(.{
        .name = "usos-windows-native-io-probe",
        .root_module = native_tool_module,
    });
    const install_native = b.addInstallArtifact(native_exe, .{});
    const native_step = b.step("windows-native-io-probe", "Build the read-only GPT/NTFS/UDF Windows ISO content probe");
    native_step.dependOn(&install_native.step);
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

fn addBootstrapUefiApp(
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

fn addInteractiveX86UefiApp(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
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
        .name = "usos-x86_64",
        .root_module = app_module,
    });
    b.installArtifact(app);

    const install_boot = b.addInstallFile(app.getEmittedBin(), "usb/EFI/BOOT/BOOTX64.EFI");
    b.getInstallStep().dependOn(&install_boot.step);

    const step = b.step("usos-x86_64", "Build the interactive x86_64 UEFI application used by release USB media");
    step.dependOn(&install_boot.step);
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
        "tools/tests/artifacts/qemu/usos-handoff.qcow2",
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
        "media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso",
        "-VhdPath",
        "tools/tests/artifacts/qemu/.staging-usos-handoff.vhd",
        "-BaseQcow2Path",
        "tools/tests/artifacts/qemu/usos-handoff-base.qcow2",
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
        "tools/tests/artifacts/qemu/usos-handoff-base.qcow2",
        "-OverlayPath",
        "tools/tests/artifacts/qemu/usos-handoff.qcow2",
    });
    create.step.dependOn(base_step);
    const step = b.step("prepare-ntfs-handoff-overlay", "Create a fresh differential qcow2 overlay for the handoff test");
    step.dependOn(&create.step);
    return step;
}

fn addFramebufferUi(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const usos_module = createUsosModule(b, target, optimize);
    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/platform/linux/fb_ui_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_module.addImport("usos", usos_module);
    return b.addExecutable(.{
        .name = "usos-fb-ui",
        .root_module = ui_module,
        .linkage = .static,
    });
}

fn addMicroLinux(b: *std.Build, framebuffer_ui: *std.Build.Step.Compile) *std.Build.Step {
    const install_framebuffer_ui = b.addInstallFile(framebuffer_ui.getEmittedBin(), "micro-linux/usos-fb-ui");
    const ui_only = b.step("framebuffer-ui", "Build only the Linux framebuffer UI (no image assembly or VM)");
    ui_only.dependOn(&install_framebuffer_ui.step);
    const build_xp_bootstrap = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/build_xp_bootstrap.ps1",
    });
    const build_xp_geometry_fix_mbr = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/build_xp_geometry_fix_mbr.ps1",
    });
    const build_micro = b.addSystemCommand(&.{
        "python",
        "tools/build_micro_linux.py",
        "--project-root",
        ".",
        "--seven-zip",
        "C:/Program Files/7-Zip/7z.exe",
        "--fb-ui",
        "zig-out/micro-linux/usos-fb-ui",
        "--output-dir",
        "zig-out/micro-linux",
    });
    build_micro.step.dependOn(&install_framebuffer_ui.step);
    build_micro.step.dependOn(&build_xp_bootstrap.step);
    build_micro.step.dependOn(&build_xp_geometry_fix_mbr.step);
    const step = b.step("micro-linux", "Build the pinned Alpine kernel/initramfs, framebuffer UI and EFI loader for WORK preparation");
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
        "media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso",
        "-VhdPath",
        "tools/tests/artifacts/qemu/.staging-usos-e2e.vhd",
        "-BaseQcow2Path",
        "tools/tests/artifacts/qemu/usos-e2e-base.qcow2",
        "-QemuImgPath",
        "tools/qemu/qemu-img.exe",
        "-BootEfiPath",
        "zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI",
        "-UiRootPath",
        "zig-out/manual-usb/UI",
        "-NtfsDriverPath",
        "zig-out/test-assets/ntfs_x64.efi",
        "-MicroLinuxKernelPath",
        "zig-out/micro-linux/vmlinuz-virt",
        "-MicroLinuxInitramfsPath",
        "zig-out/micro-linux/initramfs-usos",
        "-MicroLinuxLoaderPath",
        "zig-out/micro-linux/systemd-bootx64.efi",
        "-UnattendPath",
        "media/Systems/Windows/Windows 11/Unattended/win10-11 best-ustawienia.xml",
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
        "tools/tests/artifacts/qemu/usos-e2e-base.qcow2",
        "-OverlayPath",
        "tools/tests/artifacts/qemu/usos-e2e.qcow2",
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
    // ntfs_driver.zig loads the driver through verified_image.zig (usos module).
    app_module.addImport("usos", createUsosModule(b, target, optimize));
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

fn addUefiNtfsCatalogProbeApp(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const usos_module = createUsosModule(b, target, optimize);
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/ntfs_catalog_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("usos", usos_module);
    const app = b.addExecutable(.{
        .name = "usos-uefi-ntfs-catalog-probe-x86_64",
        .root_module = app_module,
    });
    const install_app = b.addInstallFile(app.getEmittedBin(), "test-assets/uefi-ntfs-catalog-probe-x86_64.efi");
    const step = b.step("uefi-ntfs-catalog-probe-app", "Build the UEFI direct-NTFS catalog discovery probe");
    step.dependOn(&install_app.step);
    return step;
}

/// QEMU-only probe for the Secure Boot chain: started by shim in place of
/// USOS, it loads signed/unsigned children, the NTFS driver and the
/// micro-Linux loader through verified_image.zig (tools/tests/secure_boot).
fn addSecureBootProbeApp(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/secure_boot_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("usos", createUsosModule(b, target, optimize));
    const app = b.addExecutable(.{
        .name = "usos-secure-boot-probe-x86_64",
        .root_module = app_module,
    });
    const install_app = b.addInstallFile(app.getEmittedBin(), "test-assets/secure-boot-probe-x86_64.efi");
    const step = b.step("secure-boot-probe-app", "Build the QEMU Secure Boot chain probe (verified loads through shim)");
    step.dependOn(&install_app.step);
    return step;
}

fn addGptNoBlockIoProbeApp(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/gpt_no_block_io_probe_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("usos", createUsosModule(b, target, optimize));
    const app = b.addExecutable(.{
        .name = "usos-gpt-no-block-io-probe-x86_64",
        .root_module = app_module,
    });
    const install_app = b.addInstallFile(app.getEmittedBin(), "test-assets/gpt-no-block-io-probe-x86_64.efi");
    const step = b.step("gpt-no-block-io-probe-app", "Build the UEFI probe for DATA/WORK visibility with GPT NO_BLOCK_IO_PROTOCOL");
    step.dependOn(&install_app.step);
    return step;
}

fn addQemuX86ManualImage(b: *std.Build, app: *std.Build.Step.Compile) *std.Build.Step {
    const install_boot = b.addInstallFile(app.getEmittedBin(), "manual-usb/EFI/BOOT/BOOTX64.EFI");
    const install_ui = b.addInstallDirectory(.{
        .source_dir = b.path("media/UI"),
        .install_dir = .prefix,
        .install_subdir = "manual-usb/UI",
    });

    const step = b.step("qemu-x86_64-manual-image", "Build the x86_64 UEFI app and UI used by the full QEMU flow");
    step.dependOn(&install_boot.step);
    step.dependOn(&install_ui.step);
    return step;
}

fn addDirectEfiValidationFixture(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const serial_module = b.createModule(.{
        .root_source_file = b.path("src/platform/uefi/serial.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture_module = b.createModule(.{
        .root_source_file = b.path("tools/tests/fixtures/backend_validation/direct_efi_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_module.addImport("serial", serial_module);

    const fixture = b.addExecutable(.{
        .name = "direct-efi-validation",
        .root_module = fixture_module,
    });
    const install_fixture = b.addInstallFile(fixture.getEmittedBin(), "test-assets/direct-efi-validation.efi");
    const step = b.step("direct-efi-validation-fixture", "Build the EFI payload used to validate Direct EFI LoadImage/StartImage");
    step.dependOn(&install_fixture.step);
}

/// Test EFI drivers for DATA\Drivers\UEFI (tools/tests/uefi_drivers):
/// x64 ok/binding/hang variants with distinct labels (so no two share
/// bytes) and an ia32 build as the wrong-architecture sample.
fn addUefiDriverFixtures(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const step = b.step("uefi-driver-fixtures", "Build the test EFI drivers used by tools/tests/uefi_drivers");
    const Variant = struct { name: []const u8, label: []const u8, variant: []const u8, arch: std.Target.Cpu.Arch };
    const variants = [_]Variant{
        .{ .name = "test-driver-a", .label = "A", .variant = "ok", .arch = .x86_64 },
        .{ .name = "test-driver-b", .label = "B", .variant = "ok", .arch = .x86_64 },
        .{ .name = "test-driver-c", .label = "C", .variant = "ok", .arch = .x86_64 },
        .{ .name = "test-driver-d", .label = "D", .variant = "ok", .arch = .x86_64 },
        .{ .name = "test-driver-e", .label = "E", .variant = "ok", .arch = .x86_64 },
        .{ .name = "test-driver-f", .label = "F", .variant = "ok", .arch = .x86_64 },
        .{ .name = "test-driver-g", .label = "G", .variant = "ok", .arch = .x86_64 },
        .{ .name = "test-driver-binding", .label = "BINDING", .variant = "binding", .arch = .x86_64 },
        .{ .name = "test-driver-hang", .label = "HANG", .variant = "hang", .arch = .x86_64 },
        .{ .name = "test-driver-ia32", .label = "IA32", .variant = "ok", .arch = .x86 },
    };
    for (variants) |v| {
        const target = b.resolveTargetQuery(.{ .cpu_arch = v.arch, .os_tag = .uefi });
        const serial_module = b.createModule(.{
            .root_source_file = b.path("src/platform/uefi/serial.zig"),
            .target = target,
            .optimize = optimize,
        });
        const opts = b.addOptions();
        opts.addOption([]const u8, "label", v.label);
        opts.addOption([]const u8, "variant", v.variant);
        const module = b.createModule(.{
            .root_source_file = b.path("tools/tests/fixtures/uefi_driver/test_driver_main.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("serial", serial_module);
        module.addOptions("options", opts);
        const exe = b.addExecutable(.{ .name = v.name, .root_module = module });
        exe.subsystem = .efi_boot_service_driver;
        const install = b.addInstallFile(exe.getEmittedBin(), b.fmt("test-assets/uefi-drivers/{s}.efi", .{v.name}));
        step.dependOn(&install.step);
    }
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
        .source_dir = b.path("tools/tests/fixtures/media"),
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
        .source_dir = b.path("tools/tests/fixtures/media"),
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
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    const id = b.graph.environ_map.get("USOS_BUILD_ID") orelse "DEV";
    const epoch_text = b.graph.environ_map.get("USOS_BUILD_EPOCH") orelse "0";
    const source_sha256 = b.graph.environ_map.get("USOS_BUILD_SOURCE_SHA256") orelse "DEV";
    const epoch = std.fmt.parseInt(u64, epoch_text, 10) catch 0;
    options.addOption([]const u8, "id", id);
    options.addOption(u64, "epoch", epoch);
    options.addOption([]const u8, "source_sha256", source_sha256);
    module.addOptions("build_info", options);
    return module;
}
