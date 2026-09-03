const std = @import("std");
const MemorySummary = @import("usos").boot_info.MemorySummary;

const page_size: u64 = 4096;
const descriptor_slack: usize = 8;

pub fn collectSummary() !MemorySummary {
    const boot_services = std.os.uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const initial = try boot_services.getMemoryMapInfo();
    const buffer_size = (initial.len + descriptor_slack) * initial.descriptor_size;
    const buffer = try boot_services.allocatePool(.loader_data, buffer_size);
    defer boot_services.freePool(buffer.ptr) catch {};

    const memory_map = try boot_services.getMemoryMap(buffer);
    var conventional_bytes: u64 = 0;
    var iterator = memory_map.iterator();
    while (iterator.next()) |descriptor| {
        if (descriptor.type == .conventional_memory) {
            conventional_bytes += descriptor.number_of_pages * page_size;
        }
    }

    return .{
        .descriptor_count = memory_map.info.len,
        .conventional_bytes = conventional_bytes,
    };
}
