const std = @import("std");
const usos = @import("usos");
const linux = std.os.linux;

const FBIOGET_VSCREENINFO: u32 = 0x4600;
const FBIOPUT_VSCREENINFO: u32 = 0x4601;
const FBIOGET_FSCREENINFO: u32 = 0x4602;
const FB_ACTIVATE_NOW: u32 = 0;
const FB_ACTIVATE_FORCE: u32 = 128;
/// Created after the first forced scanout of this boot (tmpfs /run).
const scanout_marker = "/run/usos-fb-scanout";

const FbBitfield = extern struct {
    offset: u32,
    length: u32,
    msb_right: u32,
};

const FbVarScreenInfo = extern struct {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    red: FbBitfield,
    green: FbBitfield,
    blue: FbBitfield,
    transp: FbBitfield,
    nonstd: u32,
    activate: u32,
    height: u32,
    width: u32,
    accel_flags: u32,
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [4]u32,
};

const FbFixScreenInfo = extern struct {
    id: [16]u8,
    smem_start: u64,
    smem_len: u32,
    type: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    line_length: u32,
    mmio_start: u64,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [2]u16,
};

comptime {
    if (@sizeOf(FbVarScreenInfo) != 160) @compileError("unexpected Linux fb_var_screeninfo layout");
    if (@sizeOf(FbFixScreenInfo) != 80) @compileError("unexpected Linux fb_fix_screeninfo layout");
}

pub const Device = struct {
    fd: i32,
    mapping: [*]u8,
    mapping_len: usize,
    surface: usos.gui.Surface,
    width: u32,
    height: u32,
    stride_bytes: u32,
    bits_per_pixel: u32,

    pub fn open() !Device {
        const open_result = linux.open("/dev/fb0", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(open_result) != .SUCCESS) return error.OpenFramebufferFailed;
        const fd: i32 = @intCast(open_result);
        errdefer _ = linux.close(fd);

        var variable = std.mem.zeroes(FbVarScreenInfo);
        const variable_result = linux.ioctl(fd, FBIOGET_VSCREENINFO, @intFromPtr(&variable));
        if (linux.errno(variable_result) != .SUCCESS) return error.GetVariableScreenInfoFailed;

        var fixed = std.mem.zeroes(FbFixScreenInfo);
        const fixed_result = linux.ioctl(fd, FBIOGET_FSCREENINFO, @intFromPtr(&fixed));
        if (linux.errno(fixed_result) != .SUCCESS) return error.GetFixedScreenInfoFailed;

        if (variable.xres == 0 or variable.yres == 0) return error.InvalidResolution;
        if (variable.bits_per_pixel != 32) return error.UnsupportedBitsPerPixel;
        if (fixed.line_length == 0 or (fixed.line_length % 4) != 0) return error.InvalidStride;

        const pixel_format: usos.boot_info.PixelFormat = if (
            variable.red.offset == 16 and variable.green.offset == 8 and variable.blue.offset == 0
        ) .bgrx8 else if (
            variable.red.offset == 0 and variable.green.offset == 8 and variable.blue.offset == 16
        ) .rgbx8 else return error.UnsupportedPixelFormat;

        const virtual_height = @max(variable.yres_virtual, variable.yres);
        const stride_bytes: usize = fixed.line_length;
        const minimum_map_len = stride_bytes * @as(usize, virtual_height);
        const mapping_len = @max(@as(usize, fixed.smem_len), minimum_map_len);
        if (mapping_len == 0) return error.InvalidFramebufferSize;

        const mmap_result = linux.mmap(
            null,
            mapping_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        if (linux.errno(mmap_result) != .SUCCESS) return error.MapFramebufferFailed;
        const mapping: [*]u8 = @ptrFromInt(mmap_result);
        errdefer _ = linux.munmap(mapping, mapping_len);

        const bytes_per_pixel: usize = variable.bits_per_pixel / 8;
        const visible_offset = @as(usize, variable.yoffset) * stride_bytes + @as(usize, variable.xoffset) * bytes_per_pixel;
        if (visible_offset >= mapping_len) return error.InvalidVisibleOffset;

        const framebuffer = usos.boot_info.Framebuffer{
            .address = @intCast(mmap_result + visible_offset),
            .size = mapping_len - visible_offset,
            .width = variable.xres,
            .height = variable.yres,
            .pixels_per_scan_line = @intCast(stride_bytes / bytes_per_pixel),
            .pixel_format = pixel_format,
        };
        const surface = usos.gui.Surface.init(framebuffer) orelse return error.UnsupportedPixelFormat;

        return .{
            .fd = fd,
            .mapping = mapping,
            .mapping_len = mapping_len,
            .surface = surface,
            .width = variable.xres,
            .height = variable.yres,
            .stride_bytes = fixed.line_length,
            .bits_per_pixel = variable.bits_per_pixel,
        };
    }

    /// Makes what was drawn visible. The micro-Linux boots with deferred
    /// fbcon takeover, so the last UEFI or Legacy BIOS frame (the USOS
    /// "Starting..." splash) stays on screen through the kernel boot instead
    /// of a black console. Until something sets the mode, simpledrm's fbdev
    /// emulation keeps our writes in its shadow buffer; the first call per
    /// boot re-applies the current mode (FBIOPUT_VSCREENINFO with
    /// FB_ACTIVATE_FORCE -> fb_set_par), which scans the drawn frame out in
    /// one step. Later frames are flushed by fbdev deferred I/O as before.
    pub fn present(self: *Device) void {
        if (scanoutDone()) return;
        var variable = std.mem.zeroes(FbVarScreenInfo);
        if (linux.errno(linux.ioctl(self.fd, FBIOGET_VSCREENINFO, @intFromPtr(&variable))) != .SUCCESS) return;
        variable.activate = FB_ACTIVATE_NOW | FB_ACTIVATE_FORCE;
        if (linux.errno(linux.ioctl(self.fd, FBIOPUT_VSCREENINFO, @intFromPtr(&variable))) != .SUCCESS) return;
        const marker = linux.open(scanout_marker, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
        if (linux.errno(marker) == .SUCCESS) _ = linux.close(@intCast(marker));
    }

    /// Pushes what was just written through the mapping to the screen now.
    /// simpledrm's fbdev emulation uses deferred I/O: writes to the mmap are
    /// only copied to the scanout by a worker that runs every HZ/20 (50 ms),
    /// so a pointer drawn through the mapping moved at 20 fps at best and
    /// felt laggy. fsync on /dev/fb0 (fb_deferred_io_fsync) runs that worker
    /// immediately. Harmless where the driver has no deferred I/O.
    pub fn flush(self: *const Device) void {
        _ = linux.fsync(self.fd);
    }

    pub fn close(self: *Device) void {
        _ = linux.munmap(self.mapping, self.mapping_len);
        _ = linux.close(self.fd);
    }
};

fn scanoutDone() bool {
    const result = linux.open(scanout_marker, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    _ = linux.close(@intCast(result));
    return true;
}
