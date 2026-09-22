pub fn weekdayName(year: u16, month: u8, day: u8) []const u8 {
    if (year == 0 or month < 1 or month > 12 or day < 1 or day > 31) return "";
    const names = [_][]const u8{ "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" };
    const offsets = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: u32 = year;
    if (month < 3) y -= 1;
    return names[(y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7];
}
