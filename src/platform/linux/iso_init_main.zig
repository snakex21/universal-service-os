//! /usos/init: runs first inside a distro initramfs (kernel `rdinit=/usos/init`)
//! when USOS boots a Linux ISO from DATA (docs/design/linux-iso-boot.md).
//!
//! 1. mount /proc, /sys, /dev (only what is not mounted yet);
//! 2. read /usos/iso.map (generated per boot by the USOS menu/Core);
//! 3. load storage, loop and dm modules through the distro's own modprobe;
//! 4. find the whole disk whose sector at the ISO's PVD has the expected CRC32;
//! 5. one extent: read-only loop device with offset/sizelimit; several:
//!    read-only device-mapper "usos-iso" with one linear target per extent;
//! 6. /dev/usos-iso -> that device; answer hooks for initramfs-tools;
//! 7. unmount what it mounted and execve("/init") (PID 1 is kept).
//!
//! Any failure is reported on the console and the distro init still runs
//! (it then shows its own "medium not found" message). Static, no libc.
const std = @import("std");
const linux = std.os.linux;
const iso_map = @import("iso_map");

const map_path = "/usos/iso.map";
const device_link = "/dev/usos-iso";
const wait_seconds = 30;

var mounted_proc = false;
var mounted_sys = false;
var mounted_dev = false;

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    const envp = init.environ.block.slice;
    run();
    unmountOwn();
    execInit(argv, envp);
    return 1;
}

fn run() void {
    mountIfMissing("proc", "/proc", "proc", &mounted_proc);
    mountIfMissing("sysfs", "/sys", "sysfs", &mounted_sys);
    mountIfMissing("devtmpfs", "/dev", "devtmpfs", &mounted_dev);

    var map_text: [8192]u8 = undefined;
    const text = readFile(map_path, &map_text) orelse return; // not a USOS ISO boot
    const map = iso_map.parse(text) catch {
        say(3, "USOS: /usos/iso.map is damaged; the ISO cannot be attached", .{});
        return;
    };
    info("iso: {d} bytes in {d} extent(s)", .{ map.size, map.len });

    loadModules(map.len > 1);
    var disk_name: [64]u8 = undefined;
    const disk = findDisk(&map, &disk_name) orelse {
        say(3, "USOS: the disk holding the ISO was not found (USB controller or disk not detected)", .{});
        return;
    };
    info("iso found on /dev/{s}", .{disk});

    var target_buffer: [32]u8 = undefined;
    const target = (if (map.len == 1) attachLoop(disk, &map, &target_buffer) else attachDm(disk, &map, &target_buffer)) orelse {
        say(3, "USOS: the ISO could not be attached as a block device", .{});
        return;
    };
    _ = linux.unlink(device_link);
    var target_z: [40]u8 = undefined;
    const target_path = std.fmt.bufPrintZ(&target_z, "{s}", .{target}) catch return;
    if (linux.errno(linux.symlink(target_path, device_link)) != .SUCCESS) {
        say(3, "USOS: cannot create /dev/usos-iso", .{});
    }
    info("iso attached: {s} -> {s}", .{ device_link, target });
    installHooks();
}

// ---------------------------------------------------------------- mounts

fn mountIfMissing(source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8, flag: *bool) void {
    _ = linux.mkdir(target, 0o755);
    const flags: u32 = if (fstype[0] == 'd') linux.MS.NOSUID else linux.MS.NOSUID | linux.MS.NOEXEC | linux.MS.NODEV;
    const rc = linux.mount(source, target, fstype, flags, 0);
    if (linux.errno(rc) == .SUCCESS) flag.* = true;
}

fn unmountOwn() void {
    // The distro init mounts these itself; devtmpfs keeps the nodes and the
    // /dev/usos-iso link (one superblock for every devtmpfs mount).
    if (mounted_dev) _ = linux.umount2("/dev", linux.MNT.DETACH);
    if (mounted_sys) _ = linux.umount2("/sys", linux.MNT.DETACH);
    if (mounted_proc) _ = linux.umount2("/proc", linux.MNT.DETACH);
}

fn execInit(argv: []const [*:0]const u8, envp: [:null]const ?[*:0]const u8) void {
    var args: [64:null]?[*:0]const u8 = @splat(null);
    args[0] = "/init";
    var n: usize = 1;
    for (argv[@min(argv.len, 1)..]) |arg| {
        if (n >= args.len) break;
        args[n] = arg;
        n += 1;
    }
    for ([_][*:0]const u8{ "/init", "/sbin/init" }) |path| {
        args[0] = path;
        _ = linux.execve(path, &args, envp.ptr);
    }
    say(2, "USOS: no /init in this initramfs", .{});
}

// ---------------------------------------------------------------- modules

const storage_modules = [_][*:0]const u8{
    "xhci_pci", "xhci_hcd",   "ehci_pci", "ehci_hcd", "ohci_pci", "uhci_hcd",
    "usb_storage", "uas",     "sd_mod",   "ahci",     "nvme",     "virtio_pci",
    "virtio_blk", "virtio_scsi", "mmc_block", "sdhci_pci", "loop",
};

fn loadModules(need_dm: bool) void {
    const modprobe = findExecutable(&.{ "/sbin/modprobe", "/usr/sbin/modprobe", "/bin/modprobe", "/usr/bin/modprobe" }) orelse {
        info("no modprobe: using built-in drivers only", .{});
        return;
    };
    for (storage_modules) |name| spawn(modprobe, name);
    if (need_dm) spawn(modprobe, "dm_mod");
}

fn findExecutable(paths: []const [*:0]const u8) ?[*:0]const u8 {
    for (paths) |path| {
        if (linux.errno(linux.access(path, linux.X_OK)) == .SUCCESS) return path;
    }
    return null;
}

fn spawn(program: [*:0]const u8, module: [*:0]const u8) void {
    const pid = linux.fork();
    switch (linux.errno(pid)) {
        .SUCCESS => {},
        else => return,
    }
    if (pid == 0) {
        const args = [_:null]?[*:0]const u8{ program, "-q", module };
        const env = [_:null]?[*:0]const u8{"PATH=/sbin:/usr/sbin:/bin:/usr/bin"};
        _ = linux.execve(program, &args, &env);
        linux.exit(127);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}

// ---------------------------------------------------------------- disk search

fn findDisk(map: *const iso_map.Map, name_out: *[64]u8) ?[]const u8 {
    const pvd_disk_offset = map.diskOffset(iso_map.pvd_offset) orelse return null;
    var elapsed_ms: u32 = 0;
    while (elapsed_ms <= wait_seconds * 1000) : (elapsed_ms += 250) {
        if (scanDisks(map, pvd_disk_offset, name_out)) |name| return name;
        if (elapsed_ms % 5000 == 0 and elapsed_ms != 0) info("waiting for the USOS disk ({d} s)", .{elapsed_ms / 1000});
        sleepMs(250);
    }
    return null;
}

fn scanDisks(map: *const iso_map.Map, pvd_disk_offset: u64, name_out: *[64]u8) ?[]const u8 {
    const dir = linux.open("/sys/block", .{ .DIRECTORY = true }, 0);
    if (linux.errno(dir) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(dir));
    var buffer: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(@intCast(dir), &buffer, buffer.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return null;
        var at: usize = 0;
        while (at < n) {
            const entry: *align(1) linux.dirent64 = @ptrCast(&buffer[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&entry.name)), 0);
            if (skipDisk(name) or name.len >= name_out.len - 6) continue;
            if (diskMatches(name, map, pvd_disk_offset)) {
                @memcpy(name_out[0..name.len], name);
                return name_out[0..name.len];
            }
        }
    }
}

fn skipDisk(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    for ([_][]const u8{ "loop", "ram", "zram", "dm-", "sr", "fd", "md", "nbd" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

fn devicePath(name: []const u8, out: *[80]u8) ?[*:0]const u8 {
    var path = std.fmt.bufPrintZ(out, "/dev/{s}", .{name}) catch return null;
    for (path[5..]) |*c| {
        if (c.* == '!') c.* = '/';
    }
    return path.ptr;
}

fn diskMatches(name: []const u8, map: *const iso_map.Map, pvd_disk_offset: u64) bool {
    var path_buffer: [80]u8 = undefined;
    const path = devicePath(name, &path_buffer) orelse return false;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var pvd: [iso_map.pvd_bytes]u8 = undefined;
    if (!preadAll(@intCast(fd), &pvd, pvd_disk_offset)) return false;
    if (!std.mem.eql(u8, pvd[1..6], "CD001")) return false;
    return iso_map.pvdCrc(&pvd) == map.crc;
}

fn preadAll(fd: i32, buffer: []u8, offset: u64) bool {
    var done: usize = 0;
    while (done < buffer.len) {
        const rc = linux.pread(fd, buffer[done..].ptr, buffer.len - done, @intCast(offset + done));
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        done += rc;
    }
    return true;
}

// ---------------------------------------------------------------- loop

const LOOP_SET_FD = 0x4C00;
const LOOP_SET_STATUS64 = 0x4C04;
const LOOP_CTL_GET_FREE = 0x4C82;
const LO_FLAGS_READ_ONLY = 1;

const LoopInfo64 = extern struct {
    device: u64 = 0,
    inode: u64 = 0,
    rdevice: u64 = 0,
    offset: u64 = 0,
    sizelimit: u64 = 0,
    number: u32 = 0,
    encrypt_type: u32 = 0,
    encrypt_key_size: u32 = 0,
    flags: u32 = 0,
    file_name: [64]u8 = @splat(0),
    crypt_name: [64]u8 = @splat(0),
    encrypt_key: [32]u8 = @splat(0),
    init: [2]u64 = .{ 0, 0 },
};

fn attachLoop(disk: []const u8, map: *const iso_map.Map, out: *[32]u8) ?[]const u8 {
    const control = openWait("/dev/loop-control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }) orelse return null;
    defer _ = linux.close(control);
    const index = linux.ioctl(control, LOOP_CTL_GET_FREE, 0);
    if (linux.errno(index) != .SUCCESS) return null;
    var loop_path_buffer: [32]u8 = undefined;
    const loop_path = std.fmt.bufPrintZ(&loop_path_buffer, "/dev/loop{d}", .{index}) catch return null;
    const loop_fd = openWait(loop_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) orelse return null;
    defer _ = linux.close(loop_fd);
    var disk_path_buffer: [80]u8 = undefined;
    const disk_path = devicePath(disk, &disk_path_buffer) orelse return null;
    const disk_fd = linux.open(disk_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(disk_fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(disk_fd));
    if (linux.errno(linux.ioctl(loop_fd, LOOP_SET_FD, disk_fd)) != .SUCCESS) return null;
    var loop_info = LoopInfo64{
        .offset = map.extents[0].lba * 512,
        .sizelimit = map.size,
        .flags = LO_FLAGS_READ_ONLY,
    };
    @memcpy(loop_info.file_name[0.."usos-iso".len], "usos-iso");
    if (linux.errno(linux.ioctl(loop_fd, LOOP_SET_STATUS64, @intFromPtr(&loop_info))) != .SUCCESS) return null;
    return std.fmt.bufPrint(out, "/dev/loop{d}", .{index}) catch null;
}

fn openWait(path: [*:0]const u8, flags: linux.O) ?i32 {
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        const fd = linux.open(path, flags, 0);
        if (linux.errno(fd) == .SUCCESS) return @intCast(fd);
        sleepMs(50);
    }
    return null;
}

// ---------------------------------------------------------------- device-mapper

const DmIoctl = extern struct {
    version: [3]u32 = .{ 4, 0, 0 },
    data_size: u32 = 0,
    data_start: u32 = 0,
    target_count: u32 = 0,
    open_count: i32 = 0,
    flags: u32 = 0,
    event_nr: u32 = 0,
    padding: u32 = 0,
    dev: u64 = 0,
    name: [128]u8 = @splat(0),
    uuid: [129]u8 = @splat(0),
    data: [7]u8 = @splat(0),
};

const DmTargetSpec = extern struct {
    sector_start: u64,
    length: u64,
    status: i32 = 0,
    next: u32,
    target_type: [16]u8,
};

comptime {
    std.debug.assert(@sizeOf(DmIoctl) == 312);
    std.debug.assert(@sizeOf(DmTargetSpec) == 40);
}

fn dmRequest(nr: u8) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(DmIoctl)) << 16) | (0xfd << 8) | nr;
}
const DM_DEV_CREATE = 3;
const DM_DEV_SUSPEND = 6;
const DM_TABLE_LOAD = 9;
const DM_READONLY_FLAG = 1 << 0;

fn attachDm(disk: []const u8, map: *const iso_map.Map, out: *[32]u8) ?[]const u8 {
    var dev_path: [96]u8 = undefined;
    var dev_text: [32]u8 = undefined;
    const devno = readFile(std.fmt.bufPrintZ(&dev_path, "/sys/block/{s}/dev", .{disk}) catch return null, &dev_text) orelse return null;
    const major_minor = std.mem.trim(u8, devno, " \r\n");
    const control = openWait("/dev/mapper/control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }) orelse return null;
    defer _ = linux.close(control);

    var create = DmIoctl{ .data_size = @sizeOf(DmIoctl), .data_start = @sizeOf(DmIoctl) };
    @memcpy(create.name[0.."usos-iso".len], "usos-iso");
    if (linux.errno(linux.ioctl(control, dmRequest(DM_DEV_CREATE), @intFromPtr(&create))) != .SUCCESS) return null;
    const minor: u64 = (create.dev & 0xff) | ((create.dev >> 12) & 0xfff00);

    var table: [@sizeOf(DmIoctl) + iso_map.max_extents * 96]u8 align(8) = undefined;
    var at: usize = @sizeOf(DmIoctl);
    var start: u64 = 0;
    for (map.slice()) |extent| {
        const spec_at = at;
        at += @sizeOf(DmTargetSpec);
        const params = std.fmt.bufPrint(table[at..], "{s} {d}\x00", .{ major_minor, extent.lba }) catch return null;
        at += params.len;
        at = std.mem.alignForward(usize, at, 8);
        var spec = DmTargetSpec{ .sector_start = start, .length = extent.sectors, .next = @intCast(at - spec_at), .target_type = @splat(0) };
        @memcpy(spec.target_type[0.."linear".len], "linear");
        @memcpy(table[spec_at..][0..@sizeOf(DmTargetSpec)], std.mem.asBytes(&spec));
        start += extent.sectors;
    }
    var load = DmIoctl{ .data_size = @intCast(at), .data_start = @sizeOf(DmIoctl), .target_count = @intCast(map.len), .flags = DM_READONLY_FLAG };
    @memcpy(load.name[0.."usos-iso".len], "usos-iso");
    @memcpy(table[0..@sizeOf(DmIoctl)], std.mem.asBytes(&load));
    if (linux.errno(linux.ioctl(control, dmRequest(DM_TABLE_LOAD), @intFromPtr(&table))) != .SUCCESS) return null;

    var resume_request = DmIoctl{ .data_size = @sizeOf(DmIoctl), .data_start = @sizeOf(DmIoctl) };
    @memcpy(resume_request.name[0.."usos-iso".len], "usos-iso");
    if (linux.errno(linux.ioctl(control, dmRequest(DM_DEV_SUSPEND), @intFromPtr(&resume_request))) != .SUCCESS) return null;
    const path = std.fmt.bufPrint(out, "/dev/dm-{d}", .{minor}) catch return null;
    // devtmpfs creates the node asynchronously.
    var z: [32]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return null;
    const fd = openWait(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) orelse return null;
    _ = linux.close(fd);
    return path;
}

// ---------------------------------------------------------------- answer hooks

/// initramfs-tools (casper, live-boot): run /usos/hooks/init-bottom from
/// /scripts/init-bottom/ORDER when a rendered Ubuntu answer is present.
fn installHooks() void {
    if (linux.errno(linux.access("/usos/answer/autoinstall.yaml", linux.F_OK)) != .SUCCESS) return;
    if (linux.errno(linux.access("/usos/hooks/init-bottom", linux.X_OK)) != .SUCCESS) return;
    const fd = linux.open("/scripts/init-bottom/ORDER", .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) {
        info("answer: no initramfs-tools init-bottom (not casper/live-boot)", .{});
        return;
    }
    defer _ = linux.close(@intCast(fd));
    const line = "/usos/hooks/init-bottom \"$@\"\n[ -e /conf/param.conf ] && . /conf/param.conf\n";
    _ = linux.write(@intCast(fd), line, line.len);
    info("answer: init-bottom hook installed", .{});
}

// ---------------------------------------------------------------- helpers

fn readFile(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var len: usize = 0;
    while (len < buffer.len) {
        const rc = linux.read(@intCast(fd), buffer[len..].ptr, buffer.len - len);
        if (linux.errno(rc) != .SUCCESS) return null;
        if (rc == 0) break;
        len += rc;
    }
    return buffer[0..len];
}

fn sleepMs(ms: u32) void {
    const request = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&request, null);
}

fn info(comptime format: []const u8, args: anytype) void {
    log(6, "usos-init: " ++ format, args);
}

/// Error-level messages go to the kernel log (shown on the console even with
/// `quiet`) and straight to /dev/console.
fn say(level: u3, comptime format: []const u8, args: anytype) void {
    log(level, format, args);
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "\n" ++ format ++ "\n", args) catch return;
    const fd = linux.open("/dev/console", .{ .ACCMODE = .WRONLY, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), text.ptr, text.len);
    _ = linux.close(@intCast(fd));
}

fn log(level: u3, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "<{d}>" ++ format ++ "\n", .{level} ++ args) catch return;
    const fd = linux.open("/dev/kmsg", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), text.ptr, text.len);
    _ = linux.close(@intCast(fd));
}
