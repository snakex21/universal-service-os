const std = @import("std");
const usos = @import("usos");

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const image_path = args.next() orelse {
        std.debug.print("usage: usos-image-probe <image.iso> [path/in/image]\n", .{});
        return 2;
    };

    var reader = try usos.image_probe.random_access.FileReader.open(init.io, std.Io.Dir.cwd(), image_path);
    defer reader.close();

    const detection = usos.image_probe.windows_detect.inspect(&reader) catch |err| {
        std.debug.print("probe error: {s}\n", .{@errorName(err)});
        return 1;
    };

    std.debug.print("system: {s}\n", .{@tagName(detection.system)});
    if (detection.filesystem) |filesystem| std.debug.print("filesystem: {s}\n", .{@tagName(filesystem)});
    if (detection.install_image_size) |size| std.debug.print("install image size: {d}\n", .{size});

    if (args.next()) |inner_path| {
        const info = usos.image_probe.optical_fs.findPath(&reader, inner_path) catch |err| {
            std.debug.print("path probe error: {s}\n", .{@errorName(err)});
            return 1;
        };
        if (info) |found| {
            std.debug.print("path: {s}\nfilesystem: {s}\nsize: {d}\ndirectory: {s}\n", .{
                inner_path,
                @tagName(found.filesystem),
                found.size,
                if (found.is_directory) "yes" else "no",
            });
        } else {
            std.debug.print("path: not found\n", .{});
            return 3;
        }
    }

    return 0;
}
