pub const Error = error{
    Io,
    OutOfBounds,
};

pub const Reader = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, u64, []u8) Error!void,

    pub fn readAt(self: Reader, offset: u64, output: []u8) Error!void {
        return self.read_fn(self.context, offset, output);
    }
};
