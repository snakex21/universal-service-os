//! Loads the EFI images USOS starts so that they also work under Secure
//! Boot, where USOS itself was started by shim and signed with the USOS MOK
//! key that the firmware db does not know.
//!
//! - Secure Boot off (or no shim): plain gBS->LoadImage, as before.
//! - shim 16+: shim has replaced gBS->LoadImage with a loader that checks
//!   db, dbx and MOK itself, so applications use plain LoadImage too. Its
//!   loader frees an image when the entry point returns, which would unload
//!   a boot-service driver, so drivers are verified with SHIM_LOCK and
//!   loaded by USOS (pe_loader) instead.
//! - shim 15.x: gBS->LoadImage is the firmware's and rejects MOK-signed
//!   files. The buffer is verified with SHIM_LOCK->Verify and the firmware
//!   security protocols are overridden for exactly that buffer during
//!   LoadImage (the approach systemd-boot uses for shim < 16).
const std = @import("std");
const uefi = std.os.uefi;
const cc = uefi.cc;
const Status = uefi.Status;
const DevicePath = uefi.protocol.DevicePath;
const secure_boot = @import("secure_boot.zig");
const pe_loader = @import("usos").image_probe.pe_loader;

pub const Error = error{
    SecureBootRejected,
    BootServicesUnavailable,
    DriverStartFailed,
    ImageTooLarge,
} || uefi.tables.BootServices.LoadImageError || uefi.tables.BootServices.AllocatePagesError ||
    pe_loader.Error || std.mem.Allocator.Error;

/// EFI_SECURITY_ARCH_PROTOCOL (PI spec).
const SecurityArch = extern struct {
    file_authentication_state: *const fn (*const SecurityArch, u32, ?*const DevicePath) callconv(cc) Status,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0xa46423e3,
        .time_mid = 0x4617,
        .time_high_and_version = 0x49f1,
        .clock_seq_high_and_reserved = 0xb9,
        .clock_seq_low = 0xff,
        .node = .{ 0xd1, 0xbf, 0xa9, 0x11, 0x58, 0x39 },
    };
};

/// EFI_SECURITY2_ARCH_PROTOCOL (PI spec 1.2.1+), where DxeImageVerificationLib
/// performs the db/dbx check.
const Security2Arch = extern struct {
    file_authentication: *const fn (*const Security2Arch, ?*const DevicePath, ?*anyopaque, usize, bool) callconv(cc) Status,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x94ab2f58,
        .time_mid = 0x1438,
        .time_high_and_version = 0x4ef1,
        .clock_seq_high_and_reserved = 0x91,
        .clock_seq_low = 0x52,
        .node = .{ 0x18, 0x94, 0x1a, 0x3a, 0x0e, 0x68 },
    };
};

/// EFI_MEMORY_ATTRIBUTE_PROTOCOL (UEFI 2.10), used to make a manually
/// loaded driver executable on firmware that maps new pages non-executable.
const MemoryAttribute = extern struct {
    get: *const anyopaque,
    set: *const anyopaque,
    clear: *const fn (*MemoryAttribute, u64, u64, u64) callconv(cc) Status,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0xf4560cf6,
        .time_mid = 0x40ec,
        .time_high_and_version = 0x4b4a,
        .clock_seq_high_and_reserved = 0xa1,
        .clock_seq_low = 0x92,
        .node = .{ 0xbf, 0x1d, 0x57, 0xd0, 0xb1, 0x89 },
    };
    const execute_protect: u64 = 0x4000;
};

var approved: []const u8 = &.{};
var original_security: ?*const fn (*const SecurityArch, u32, ?*const DevicePath) callconv(cc) Status = null;
var original_security2: ?*const fn (*const Security2Arch, ?*const DevicePath, ?*anyopaque, usize, bool) callconv(cc) Status = null;

fn security2Hook(this: *const Security2Arch, path: ?*const DevicePath, buffer: ?*anyopaque, size: usize, boot_policy: bool) callconv(cc) Status {
    if (buffer) |pointer| {
        if (approved.len != 0 and @intFromPtr(pointer) == @intFromPtr(approved.ptr) and size == approved.len) return .success;
    }
    const original = original_security2 orelse return .security_violation;
    return original(this, path, buffer, size, boot_policy);
}

fn securityHook(this: *const SecurityArch, status: u32, path: ?*const DevicePath) callconv(cc) Status {
    // Only armed for the duration of one LoadImage of an already verified
    // buffer; the v1 protocol does not receive the buffer to compare.
    if (approved.len != 0) return .success;
    const original = original_security orelse return .security_violation;
    return original(this, status, path);
}

/// Runs LoadImage(device_path, buffer) with the firmware security handlers
/// accepting exactly `buffer`, which the caller verified through shim.
fn loadWithOverride(bs: *uefi.tables.BootServices, device_path: ?*const DevicePath, buffer: []const u8) Error!uefi.Handle {
    const security = bs.locateProtocol(SecurityArch, null) catch null;
    const security2 = bs.locateProtocol(Security2Arch, null) catch null;
    approved = buffer;
    if (security) |protocol| {
        original_security = protocol.file_authentication_state;
        protocol.file_authentication_state = securityHook;
    }
    if (security2) |protocol| {
        original_security2 = protocol.file_authentication;
        protocol.file_authentication = security2Hook;
    }
    defer {
        if (security) |protocol| protocol.file_authentication_state = original_security.?;
        if (security2) |protocol| protocol.file_authentication = original_security2.?;
        approved = &.{};
        original_security = null;
        original_security2 = null;
    }
    var handle: uefi.Handle = undefined;
    return switch (bs._loadImage(false, uefi.handle, device_path, buffer.ptr, buffer.len, &handle)) {
        .success => handle,
        .security_violation, .access_denied => error.SecureBootRejected,
        .not_found => error.NotFound,
        .invalid_parameter => error.InvalidParameter,
        .unsupported => error.Unsupported,
        .out_of_resources => error.OutOfResources,
        .load_error => error.LoadError,
        .device_error => error.DeviceError,
        else => |status| uefi.unexpectedStatus(status),
    };
}

fn plainLoad(bs: *uefi.tables.BootServices, source: uefi.tables.BootServices.LoadImageSource) Error!uefi.Handle {
    return bs.loadImage(false, uefi.handle, source) catch |err| switch (err) {
        // With Secure Boot on, the firmware or shim refused the signature.
        error.SecurityViolation, error.AccessDenied => if (secure_boot.enforced()) error.SecureBootRejected else err,
        else => err,
    };
}

/// Loads an EFI application from `device_path`. `file` is the already opened
/// image file; it is read only on the shim 15.x path.
pub fn loadApplication(device_path: *const DevicePath, file: *uefi.protocol.File) !uefi.Handle {
    const bs = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    if (!secure_boot.enforced() or secure_boot.shimOwnsLoadImage()) return plainLoad(bs, .{ .device_path = device_path });
    const lock = secure_boot.shimLock() orelse return plainLoad(bs, .{ .device_path = device_path });
    const bytes = try readWhole(bs, file);
    defer bs.freePool(bytes.ptr) catch {};
    try secure_boot.shimVerify(lock, bytes);
    return loadWithOverride(bs, device_path, bytes);
}

fn readWhole(bs: *uefi.tables.BootServices, file: *uefi.protocol.File) ![]align(8) u8 {
    try file.setPosition(0xffff_ffff_ffff_ffff);
    const size = try file.getPosition();
    try file.setPosition(0);
    if (size == 0 or size > 256 * 1024 * 1024) return error.ImageTooLarge;
    const bytes = try bs.allocatePool(.loader_data, @intCast(size));
    errdefer bs.freePool(bytes.ptr) catch {};
    var used: usize = 0;
    while (used < bytes.len) {
        const read = try file.read(bytes[used..]);
        if (read == 0) return error.EndOfStream;
        used += read;
    }
    return bytes;
}

/// Loads and starts a boot-service driver held in `bytes`.
pub fn startDriver(bytes: []const u8, device_handle: ?uefi.Handle) Error!void {
    return startDriverWithOptions(bytes, device_handle, null);
}

/// startDriver with LoadedImage->LoadOptions (UTF-16, e.g. `log=<path>`)
/// and DeviceHandle set before the entry point runs, on every load path.
/// `options` must stay valid while the driver is resident.
pub fn startDriverWithOptions(bytes: []const u8, device_handle: ?uefi.Handle, options: ?[]const u16) Error!void {
    const bs = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const lock = if (secure_boot.enforced()) secure_boot.shimLock() else null;
    if (lock) |shim| {
        try secure_boot.shimVerify(shim, bytes);
        if (secure_boot.shimOwnsLoadImage()) return startDriverManually(bs, bytes, device_handle, options);
        const image = try loadWithOverride(bs, null, bytes);
        setLoadedImage(bs, image, device_handle, options);
        return startLoaded(image);
    }
    const image = try plainLoad(bs, .{ .buffer = bytes });
    setLoadedImage(bs, image, device_handle, options);
    return startLoaded(image);
}

/// An image loaded from a buffer has no DeviceHandle and no options; fill
/// them in between LoadImage and StartImage (as a shell passes arguments).
fn setLoadedImage(bs: *uefi.tables.BootServices, image: uefi.Handle, device_handle: ?uefi.Handle, options: ?[]const u16) void {
    if (device_handle == null and options == null) return;
    const loaded = (bs.handleProtocol(uefi.protocol.LoadedImage, image) catch null) orelse return;
    if (device_handle) |device| loaded.device_handle = device;
    if (options) |text| {
        loaded.load_options = @ptrCast(@constCast(text.ptr));
        loaded.load_options_size = @intCast(text.len * 2);
    }
}

fn startLoaded(image: uefi.Handle) Error!void {
    const code = start(image) catch return error.DriverStartFailed;
    if (code != .success) return error.DriverStartFailed;
}

pub const StartError = error{ BootServicesUnavailable, InvalidParameter, SecurityViolation };

/// StartImage without reading exit data. std's startImage leaves the exit
/// data size uninitialised and trusts the callee to set it; shim 16's
/// StartImage hook only sets it when the image calls Exit(), so an image
/// that simply returns would make std dereference garbage. Exit data is
/// never used by USOS, and a non-null buffer is freed as the spec requires.
pub fn start(image: uefi.Handle) StartError!Status {
    const bs = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    var exit_data_size: usize = 0;
    var exit_data: ?[*]u16 = null;
    const Start = *const fn (uefi.Handle, *usize, *?[*]u16) callconv(cc) Status;
    const call: Start = @ptrCast(bs._startImage);
    const code = call(image, &exit_data_size, &exit_data);
    if (exit_data_size != 0) {
        if (exit_data) |data| bs.freePool(@ptrCast(@alignCast(data))) catch {};
    }
    return switch (code) {
        .invalid_parameter => error.InvalidParameter,
        .security_violation => error.SecurityViolation,
        else => code,
    };
}

const end_of_path = [4]u8{ 0x7f, 0xff, 0x04, 0x00 };
var reserved_word: u64 = 0;

fn unloadUnsupported(_: *uefi.protocol.LoadedImage, _: uefi.Handle) callconv(cc) Status {
    return .unsupported;
}

/// Loads a verified driver without gBS->LoadImage: copies and relocates it
/// into boot-services code pages, installs a LoadedImage protocol on a new
/// handle and calls its entry point. The memory stays allocated for the
/// rest of boot services, like any resident driver.
fn startDriverManually(bs: *uefi.tables.BootServices, bytes: []const u8, device_handle: ?uefi.Handle, options: ?[]const u16) Error!void {
    const layout = try pe_loader.parse(bytes);
    if (layout.subsystem != pe_loader.subsystem_efi_boot_service_driver) return error.Unsupported;
    const pages = try bs.allocatePages(.any, .boot_services_code, (@as(usize, layout.size_of_image) + 4095) / 4096);
    const memory = std.mem.sliceAsBytes(pages);
    pe_loader.load(bytes, layout, memory, @intFromPtr(memory.ptr)) catch |err| {
        bs.freePages(pages) catch {};
        return err;
    };
    if (bs.locateProtocol(MemoryAttribute, null) catch null) |attributes| {
        _ = attributes.clear(attributes, @intFromPtr(memory.ptr), memory.len, MemoryAttribute.execute_protect);
    }
    const loaded = try uefi.pool_allocator.create(uefi.protocol.LoadedImage);
    loaded.* = .{
        .revision = 0x1000,
        .parent_handle = uefi.handle,
        .system_table = uefi.system_table,
        .device_handle = device_handle,
        .file_path = @ptrCast(@constCast(&end_of_path)),
        .reserved = @ptrCast(&reserved_word),
        .load_options_size = if (options) |text| @intCast(text.len * 2) else 0,
        .load_options = if (options) |text| @ptrCast(@constCast(text.ptr)) else null,
        .image_base = memory.ptr,
        .image_size = layout.size_of_image,
        .image_code_type = .boot_services_code,
        .image_data_type = .boot_services_data,
        ._unload = unloadUnsupported,
    };
    // std's installProtocolInterface(s) wrappers do not compile for a new
    // handle in this Zig version; call InstallProtocolInterface directly.
    const Install = *const fn (*?uefi.Handle, *const uefi.Guid, uefi.tables.InterfaceType, *anyopaque) callconv(cc) Status;
    const install: Install = @ptrCast(bs._installProtocolInterface);
    var new_handle: ?uefi.Handle = null;
    if (install(&new_handle, &uefi.protocol.LoadedImage.guid, .native, loaded) != .success) return error.DriverStartFailed;
    const handle = new_handle orelse return error.DriverStartFailed;
    const Entry = *const fn (uefi.Handle, *uefi.tables.SystemTable) callconv(cc) Status;
    const entry: Entry = @ptrFromInt(@intFromPtr(memory.ptr) + layout.entry_rva);
    if (entry(handle, uefi.system_table) != .success) return error.DriverStartFailed;
}
