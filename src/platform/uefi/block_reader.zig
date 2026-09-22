const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");

const random_reader = usos.storage.random_reader;
const sector_bytes: usize = 512;

pub const Error = error{
    UnsupportedBlockSize,
    MediaMissing,
};

pub const Context = struct {
    io: *uefi.protocol.BlockIo,
    bounce: [sector_bytes]u8 align(4096) = undefined,

    pub fn init(io: *uefi.protocol.BlockIo) Error!Context {
        const media = io.media;
        if (!media.media_present) return error.MediaMissing;
        if (media.block_size != sector_bytes) return error.UnsupportedBlockSize;
        return .{ .io = io };
    }

    pub fn reader(self: *Context) random_reader.Reader {
        return .{ .context = self, .read_fn = readAt };
    }

    fn readAt(context: *anyopaque, offset: u64, output: []u8) random_reader.Error!void {
        const self: *Context = @ptrCast(@alignCast(context));
        if (output.len == 0) return;

        const media = self.io.media;
        if (!media.media_present or media.block_size != sector_bytes) return error.Io;
        const device_bytes = std.math.mul(u64, media.last_block + 1, sector_bytes) catch return error.OutOfBounds;
        const end = std.math.add(u64, offset, output.len) catch return error.OutOfBounds;
        if (end > device_bytes) return error.OutOfBounds;

        var cursor = offset;
        var written: usize = 0;
        while (written < output.len) {
            const lba = cursor / sector_bytes;
            const within: usize = @intCast(cursor % sector_bytes);
            const alignment = @max(@as(usize, 1), media.io_align);
            if (within == 0 and output.len - written >= sector_bytes and @intFromPtr(output[written..].ptr) % alignment == 0) {
                const amount = @min((output.len - written) / sector_bytes * sector_bytes, 1024 * 1024);
                self.io.readBlocks(media.media_id, lba, output[written..][0..amount]) catch return error.Io;
                cursor += amount;
                written += amount;
                continue;
            }
            self.io.readBlocks(media.media_id, lba, self.bounce[0..]) catch return error.Io;
            const amount = @min(output.len - written, sector_bytes - within);
            @memcpy(output[written .. written + amount], self.bounce[within .. within + amount]);
            cursor += amount;
            written += amount;
        }
    }
};
