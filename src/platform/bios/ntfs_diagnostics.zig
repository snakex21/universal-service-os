pub const State = struct {
    data_gpt_found: bool = false,
    data_start_lba: u64 = 0,
    data_sector_count: u64 = 0,

    vbr_read: bool = false,
    vbr_oem_ntfs: bool = false,
    vbr_signature_valid: bool = false,
    bytes_per_sector: u16 = 0,
    sectors_per_cluster: u8 = 0,
    mft_lcn: u64 = 0,

    mount_ok: bool = false,
    mft_runs: usize = 0,

    systems_probe_attempted: bool = false,
    systems_open_ok: bool = false,
    systems_entry_count: usize = 0,

    pre_vbe_index_single_hash: u32 = 0,
    pre_vbe_index_bulk_hash: u32 = 0,
    post_vbe_index_single_hash: u32 = 0,
    post_vbe_index_bulk_hash: u32 = 0,
    pre_vbe_index_single_ok: bool = false,
    pre_vbe_index_bulk_ok: bool = false,
    post_vbe_index_single_ok: bool = false,
    post_vbe_index_bulk_ok: bool = false,

    last_error: ?[]const u8 = null,
    last_path: [260]u8 = [_]u8{0} ** 260,
    last_path_len: usize = 0,

    pub fn clearError(self: *State) void {
        self.last_error = null;
        self.last_path_len = 0;
    }

    pub fn recordError(self: *State, path: []const u8, err: anyerror) void {
        self.last_error = @errorName(err);
        const count = @min(path.len, self.last_path.len);
        var index: usize = 0;
        while (index < count) : (index += 1) self.last_path[index] = path[index];
        self.last_path_len = count;
    }

    pub fn errorPath(self: *const State) []const u8 {
        return self.last_path[0..self.last_path_len];
    }
};
