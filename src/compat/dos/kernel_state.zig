pub const KernelState = struct {
    current_psp: u16,
    current_drive: u8 = 2,
    logical_drive_count: u8 = 3,
    version_major: u8 = 4,
    version_minor: u8 = 0,
};
