//! Data tables of the answer-profile model (docs/answer-profiles.md):
//! neutral time zone ids and language tags, mapped per OS family.
//!
//!   time zones  IANA id (the neutral id stored in a profile) -> Windows
//!               time zone id (Vista/7 and 8+ where they differ) and the
//!               NT5 WINNT.SIF [GuiUnattended] TimeZone index
//!   languages   BCP-47 tag -> LCID, NT5 language group, default keyboard
//!
//! Sources: Microsoft "Time Zone Index Values" (NT5 unattend reference),
//! the CLDR windowsZones mapping (Windows id -> representative IANA city)
//! and "Default Input Profiles (Input Locales) in Windows". Values were
//! written down by hand; the tests below pin known pairs.
const std = @import("std");

pub const TimeZone = struct {
    /// Neutral id (IANA).
    id: []const u8,
    /// Windows time zone id for Windows 8 and later (and 7 with updates).
    windows: []const u8,
    /// Windows id for Vista/7 media when it differs (older zone names).
    windows_legacy: ?[]const u8 = null,
    /// NT5 (2000/XP/2003) time zone index.
    nt5: u16,
    /// English label for the menu list.
    label: []const u8,
};

/// Ordered by UTC offset (the order of the menu list).
pub const time_zones = [_]TimeZone{
    .{ .id = "Etc/GMT+12", .windows = "Dateline Standard Time", .nt5 = 0, .label = "(UTC-12:00) International Date Line West" },
    .{ .id = "Pacific/Honolulu", .windows = "Hawaiian Standard Time", .nt5 = 2, .label = "(UTC-10:00) Hawaii" },
    .{ .id = "America/Anchorage", .windows = "Alaskan Standard Time", .nt5 = 3, .label = "(UTC-09:00) Alaska" },
    .{ .id = "America/Los_Angeles", .windows = "Pacific Standard Time", .nt5 = 4, .label = "(UTC-08:00) Pacific Time (US & Canada)" },
    .{ .id = "America/Phoenix", .windows = "US Mountain Standard Time", .nt5 = 15, .label = "(UTC-07:00) Arizona" },
    .{ .id = "America/Denver", .windows = "Mountain Standard Time", .nt5 = 10, .label = "(UTC-07:00) Mountain Time (US & Canada)" },
    .{ .id = "America/Chicago", .windows = "Central Standard Time", .nt5 = 20, .label = "(UTC-06:00) Central Time (US & Canada)" },
    .{ .id = "America/Guatemala", .windows = "Central America Standard Time", .nt5 = 33, .label = "(UTC-06:00) Central America" },
    .{ .id = "America/Mexico_City", .windows = "Central Standard Time (Mexico)", .windows_legacy = "Mexico Standard Time", .nt5 = 30, .label = "(UTC-06:00) Guadalajara, Mexico City, Monterrey" },
    .{ .id = "America/Regina", .windows = "Canada Central Standard Time", .nt5 = 25, .label = "(UTC-06:00) Saskatchewan" },
    .{ .id = "America/Bogota", .windows = "SA Pacific Standard Time", .nt5 = 45, .label = "(UTC-05:00) Bogota, Lima, Quito" },
    .{ .id = "America/New_York", .windows = "Eastern Standard Time", .nt5 = 35, .label = "(UTC-05:00) Eastern Time (US & Canada)" },
    .{ .id = "America/Indiana/Indianapolis", .windows = "US Eastern Standard Time", .nt5 = 40, .label = "(UTC-05:00) Indiana (East)" },
    .{ .id = "America/Halifax", .windows = "Atlantic Standard Time", .nt5 = 50, .label = "(UTC-04:00) Atlantic Time (Canada)" },
    .{ .id = "America/La_Paz", .windows = "SA Western Standard Time", .nt5 = 55, .label = "(UTC-04:00) Georgetown, La Paz, Manaus" },
    .{ .id = "America/Santiago", .windows = "Pacific SA Standard Time", .nt5 = 56, .label = "(UTC-04:00) Santiago" },
    .{ .id = "America/St_Johns", .windows = "Newfoundland Standard Time", .nt5 = 60, .label = "(UTC-03:30) Newfoundland" },
    .{ .id = "America/Sao_Paulo", .windows = "E. South America Standard Time", .nt5 = 65, .label = "(UTC-03:00) Brasilia" },
    .{ .id = "America/Cayenne", .windows = "SA Eastern Standard Time", .nt5 = 70, .label = "(UTC-03:00) Cayenne, Fortaleza" },
    .{ .id = "America/Godthab", .windows = "Greenland Standard Time", .nt5 = 73, .label = "(UTC-03:00) Greenland" },
    .{ .id = "Atlantic/Azores", .windows = "Azores Standard Time", .nt5 = 80, .label = "(UTC-01:00) Azores" },
    .{ .id = "Atlantic/Cape_Verde", .windows = "Cape Verde Standard Time", .nt5 = 83, .label = "(UTC-01:00) Cabo Verde Is." },
    .{ .id = "Etc/UTC", .windows = "UTC", .windows_legacy = "Greenwich Standard Time", .nt5 = 90, .label = "(UTC) Coordinated Universal Time" },
    .{ .id = "Europe/London", .windows = "GMT Standard Time", .nt5 = 85, .label = "(UTC+00:00) Dublin, Edinburgh, Lisbon, London" },
    .{ .id = "Atlantic/Reykjavik", .windows = "Greenwich Standard Time", .nt5 = 90, .label = "(UTC+00:00) Monrovia, Reykjavik" },
    .{ .id = "Europe/Berlin", .windows = "W. Europe Standard Time", .nt5 = 110, .label = "(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna" },
    .{ .id = "Europe/Budapest", .windows = "Central Europe Standard Time", .nt5 = 95, .label = "(UTC+01:00) Belgrade, Bratislava, Budapest, Ljubljana, Prague" },
    .{ .id = "Europe/Paris", .windows = "Romance Standard Time", .nt5 = 105, .label = "(UTC+01:00) Brussels, Copenhagen, Madrid, Paris" },
    .{ .id = "Europe/Warsaw", .windows = "Central European Standard Time", .nt5 = 100, .label = "(UTC+01:00) Sarajevo, Skopje, Warsaw, Zagreb" },
    .{ .id = "Africa/Lagos", .windows = "W. Central Africa Standard Time", .nt5 = 113, .label = "(UTC+01:00) West Central Africa" },
    .{ .id = "Europe/Bucharest", .windows = "GTB Standard Time", .nt5 = 130, .label = "(UTC+02:00) Athens, Bucharest" },
    .{ .id = "Africa/Cairo", .windows = "Egypt Standard Time", .nt5 = 120, .label = "(UTC+02:00) Cairo" },
    .{ .id = "Europe/Chisinau", .windows = "E. Europe Standard Time", .nt5 = 115, .label = "(UTC+02:00) Chisinau" },
    .{ .id = "Africa/Johannesburg", .windows = "South Africa Standard Time", .nt5 = 140, .label = "(UTC+02:00) Harare, Pretoria" },
    .{ .id = "Europe/Kiev", .windows = "FLE Standard Time", .nt5 = 125, .label = "(UTC+02:00) Helsinki, Kyiv, Riga, Sofia, Tallinn, Vilnius" },
    .{ .id = "Asia/Jerusalem", .windows = "Israel Standard Time", .nt5 = 135, .label = "(UTC+02:00) Jerusalem" },
    .{ .id = "Asia/Baghdad", .windows = "Arabic Standard Time", .nt5 = 158, .label = "(UTC+03:00) Baghdad" },
    .{ .id = "Asia/Riyadh", .windows = "Arab Standard Time", .nt5 = 150, .label = "(UTC+03:00) Kuwait, Riyadh" },
    .{ .id = "Europe/Moscow", .windows = "Russian Standard Time", .nt5 = 145, .label = "(UTC+03:00) Moscow, St. Petersburg" },
    .{ .id = "Africa/Nairobi", .windows = "E. Africa Standard Time", .nt5 = 155, .label = "(UTC+03:00) Nairobi" },
    .{ .id = "Asia/Tehran", .windows = "Iran Standard Time", .nt5 = 160, .label = "(UTC+03:30) Tehran" },
    .{ .id = "Asia/Dubai", .windows = "Arabian Standard Time", .nt5 = 165, .label = "(UTC+04:00) Abu Dhabi, Muscat" },
    .{ .id = "Asia/Yerevan", .windows = "Caucasus Standard Time", .nt5 = 170, .label = "(UTC+04:00) Yerevan" },
    .{ .id = "Asia/Kabul", .windows = "Afghanistan Standard Time", .nt5 = 175, .label = "(UTC+04:30) Kabul" },
    .{ .id = "Asia/Yekaterinburg", .windows = "Ekaterinburg Standard Time", .nt5 = 180, .label = "(UTC+05:00) Ekaterinburg" },
    .{ .id = "Asia/Tashkent", .windows = "West Asia Standard Time", .nt5 = 185, .label = "(UTC+05:00) Ashgabat, Tashkent" },
    .{ .id = "Asia/Calcutta", .windows = "India Standard Time", .nt5 = 190, .label = "(UTC+05:30) Chennai, Kolkata, Mumbai, New Delhi" },
    .{ .id = "Asia/Colombo", .windows = "Sri Lanka Standard Time", .nt5 = 200, .label = "(UTC+05:30) Sri Jayawardenepura" },
    .{ .id = "Asia/Katmandu", .windows = "Nepal Standard Time", .nt5 = 193, .label = "(UTC+05:45) Kathmandu" },
    .{ .id = "Asia/Almaty", .windows = "Central Asia Standard Time", .nt5 = 195, .label = "(UTC+06:00) Astana" },
    .{ .id = "Asia/Rangoon", .windows = "Myanmar Standard Time", .nt5 = 203, .label = "(UTC+06:30) Yangon (Rangoon)" },
    .{ .id = "Asia/Novosibirsk", .windows = "N. Central Asia Standard Time", .nt5 = 201, .label = "(UTC+07:00) Novosibirsk" },
    .{ .id = "Asia/Bangkok", .windows = "SE Asia Standard Time", .nt5 = 205, .label = "(UTC+07:00) Bangkok, Hanoi, Jakarta" },
    .{ .id = "Asia/Krasnoyarsk", .windows = "North Asia Standard Time", .nt5 = 207, .label = "(UTC+07:00) Krasnoyarsk" },
    .{ .id = "Asia/Shanghai", .windows = "China Standard Time", .nt5 = 210, .label = "(UTC+08:00) Beijing, Chongqing, Hong Kong, Urumqi" },
    .{ .id = "Asia/Irkutsk", .windows = "North Asia East Standard Time", .nt5 = 227, .label = "(UTC+08:00) Irkutsk" },
    .{ .id = "Asia/Singapore", .windows = "Singapore Standard Time", .nt5 = 215, .label = "(UTC+08:00) Kuala Lumpur, Singapore" },
    .{ .id = "Australia/Perth", .windows = "W. Australia Standard Time", .nt5 = 225, .label = "(UTC+08:00) Perth" },
    .{ .id = "Asia/Taipei", .windows = "Taipei Standard Time", .nt5 = 220, .label = "(UTC+08:00) Taipei" },
    .{ .id = "Asia/Tokyo", .windows = "Tokyo Standard Time", .nt5 = 235, .label = "(UTC+09:00) Osaka, Sapporo, Tokyo" },
    .{ .id = "Asia/Seoul", .windows = "Korea Standard Time", .nt5 = 230, .label = "(UTC+09:00) Seoul" },
    .{ .id = "Asia/Yakutsk", .windows = "Yakutsk Standard Time", .nt5 = 240, .label = "(UTC+09:00) Yakutsk" },
    .{ .id = "Australia/Adelaide", .windows = "Cen. Australia Standard Time", .nt5 = 250, .label = "(UTC+09:30) Adelaide" },
    .{ .id = "Australia/Darwin", .windows = "AUS Central Standard Time", .nt5 = 245, .label = "(UTC+09:30) Darwin" },
    .{ .id = "Australia/Brisbane", .windows = "E. Australia Standard Time", .nt5 = 260, .label = "(UTC+10:00) Brisbane" },
    .{ .id = "Australia/Sydney", .windows = "AUS Eastern Standard Time", .nt5 = 255, .label = "(UTC+10:00) Canberra, Melbourne, Sydney" },
    .{ .id = "Pacific/Port_Moresby", .windows = "West Pacific Standard Time", .nt5 = 275, .label = "(UTC+10:00) Guam, Port Moresby" },
    .{ .id = "Australia/Hobart", .windows = "Tasmania Standard Time", .nt5 = 265, .label = "(UTC+10:00) Hobart" },
    .{ .id = "Asia/Vladivostok", .windows = "Vladivostok Standard Time", .nt5 = 270, .label = "(UTC+10:00) Vladivostok" },
    .{ .id = "Pacific/Guadalcanal", .windows = "Central Pacific Standard Time", .nt5 = 280, .label = "(UTC+11:00) Solomon Is., New Caledonia" },
    .{ .id = "Pacific/Auckland", .windows = "New Zealand Standard Time", .nt5 = 290, .label = "(UTC+12:00) Auckland, Wellington" },
    .{ .id = "Pacific/Fiji", .windows = "Fiji Standard Time", .nt5 = 285, .label = "(UTC+12:00) Fiji" },
    .{ .id = "Pacific/Tongatapu", .windows = "Tonga Standard Time", .nt5 = 300, .label = "(UTC+13:00) Nuku'alofa" },
};

pub fn timeZone(id: []const u8) ?*const TimeZone {
    for (&time_zones) |*zone| {
        if (std.ascii.eqlIgnoreCase(zone.id, id)) return zone;
    }
    return null;
}

pub fn timeZoneIndex(id: []const u8) ?usize {
    for (&time_zones, 0..) |*zone, index| {
        if (std.ascii.eqlIgnoreCase(zone.id, id)) return index;
    }
    return null;
}

/// First zone with this NT5 index (importing usos-xp.ini timezone=).
pub fn timeZoneForNt5(index: u16) ?*const TimeZone {
    for (&time_zones) |*zone| {
        if (zone.nt5 == index) return zone;
    }
    return null;
}

pub const Language = struct {
    /// BCP-47 tag used by Windows 6+ (International-Core).
    tag: []const u8,
    /// Locale id (NT5 [RegionalSettings] and the input profile prefix).
    lcid: u16,
    /// NT5 language group (1 Western Europe and US, 2 Central Europe,
    /// 3 Baltic, 4 Greek, 5 Cyrillic, 6 Turkic, 7 Japanese, 8 Korean,
    /// 9 Traditional Chinese, 10 Simplified Chinese).
    group: u8,
    /// Default keyboard layout id (KLID) of the language.
    keyboard: u32,
    /// English name for the menu list.
    label: []const u8,
    /// NT6 tag on Vista/7 media when it differs.
    tag_legacy: ?[]const u8 = null,
    /// NT5 LCID when it differs (Serbian Latin: Serbia and Montenegro).
    lcid_nt5: ?u16 = null,
};

pub const languages = [_]Language{
    .{ .tag = "bg-BG", .lcid = 0x0402, .group = 5, .keyboard = 0x00000402, .label = "Bulgarian" },
    .{ .tag = "cs-CZ", .lcid = 0x0405, .group = 2, .keyboard = 0x00000405, .label = "Czech" },
    .{ .tag = "da-DK", .lcid = 0x0406, .group = 1, .keyboard = 0x00000406, .label = "Danish" },
    .{ .tag = "de-DE", .lcid = 0x0407, .group = 1, .keyboard = 0x00000407, .label = "German" },
    .{ .tag = "el-GR", .lcid = 0x0408, .group = 4, .keyboard = 0x00000408, .label = "Greek" },
    .{ .tag = "en-GB", .lcid = 0x0809, .group = 1, .keyboard = 0x00000809, .label = "English (United Kingdom)" },
    .{ .tag = "en-US", .lcid = 0x0409, .group = 1, .keyboard = 0x00000409, .label = "English (United States)" },
    .{ .tag = "es-ES", .lcid = 0x0c0a, .group = 1, .keyboard = 0x0000040a, .label = "Spanish" },
    .{ .tag = "es-MX", .lcid = 0x080a, .group = 1, .keyboard = 0x0000080a, .label = "Spanish (Mexico)" },
    .{ .tag = "et-EE", .lcid = 0x0425, .group = 3, .keyboard = 0x00000425, .label = "Estonian" },
    .{ .tag = "fi-FI", .lcid = 0x040b, .group = 1, .keyboard = 0x0000040b, .label = "Finnish" },
    .{ .tag = "fr-FR", .lcid = 0x040c, .group = 1, .keyboard = 0x0000040c, .label = "French" },
    .{ .tag = "fr-CA", .lcid = 0x0c0c, .group = 1, .keyboard = 0x00001009, .label = "French (Canada)" },
    .{ .tag = "hr-HR", .lcid = 0x041a, .group = 2, .keyboard = 0x0000041a, .label = "Croatian" },
    .{ .tag = "hu-HU", .lcid = 0x040e, .group = 2, .keyboard = 0x0000040e, .label = "Hungarian" },
    .{ .tag = "it-IT", .lcid = 0x0410, .group = 1, .keyboard = 0x00000410, .label = "Italian" },
    .{ .tag = "ja-JP", .lcid = 0x0411, .group = 7, .keyboard = 0x00000411, .label = "Japanese" },
    .{ .tag = "ko-KR", .lcid = 0x0412, .group = 8, .keyboard = 0x00000412, .label = "Korean" },
    .{ .tag = "lt-LT", .lcid = 0x0427, .group = 3, .keyboard = 0x00010427, .label = "Lithuanian" },
    .{ .tag = "lv-LV", .lcid = 0x0426, .group = 3, .keyboard = 0x00010426, .label = "Latvian" },
    .{ .tag = "nb-NO", .lcid = 0x0414, .group = 1, .keyboard = 0x00000414, .label = "Norwegian" },
    .{ .tag = "nl-NL", .lcid = 0x0413, .group = 1, .keyboard = 0x00020409, .label = "Dutch" },
    .{ .tag = "pl-PL", .lcid = 0x0415, .group = 2, .keyboard = 0x00000415, .label = "Polish" },
    .{ .tag = "pt-BR", .lcid = 0x0416, .group = 1, .keyboard = 0x00000416, .label = "Portuguese (Brazil)" },
    .{ .tag = "pt-PT", .lcid = 0x0816, .group = 1, .keyboard = 0x00000816, .label = "Portuguese (Portugal)" },
    .{ .tag = "ro-RO", .lcid = 0x0418, .group = 2, .keyboard = 0x00010418, .label = "Romanian" },
    .{ .tag = "ru-RU", .lcid = 0x0419, .group = 5, .keyboard = 0x00000419, .label = "Russian" },
    .{ .tag = "sk-SK", .lcid = 0x041b, .group = 2, .keyboard = 0x0000041b, .label = "Slovak" },
    .{ .tag = "sl-SI", .lcid = 0x0424, .group = 2, .keyboard = 0x00000424, .label = "Slovenian" },
    .{ .tag = "sr-Latn-RS", .lcid = 0x241a, .group = 2, .keyboard = 0x0000081a, .label = "Serbian (Latin)", .tag_legacy = "sr-Latn-CS", .lcid_nt5 = 0x081a },
    .{ .tag = "sv-SE", .lcid = 0x041d, .group = 1, .keyboard = 0x0000041d, .label = "Swedish" },
    .{ .tag = "tr-TR", .lcid = 0x041f, .group = 6, .keyboard = 0x0000041f, .label = "Turkish" },
    .{ .tag = "uk-UA", .lcid = 0x0422, .group = 5, .keyboard = 0x00000422, .label = "Ukrainian" },
    .{ .tag = "zh-CN", .lcid = 0x0804, .group = 10, .keyboard = 0x00000804, .label = "Chinese (Simplified)" },
    .{ .tag = "zh-TW", .lcid = 0x0404, .group = 9, .keyboard = 0x00000404, .label = "Chinese (Traditional)" },
};

pub fn language(tag: []const u8) ?*const Language {
    for (&languages) |*entry| {
        if (std.ascii.eqlIgnoreCase(entry.tag, tag)) return entry;
        if (entry.tag_legacy) |legacy| if (std.ascii.eqlIgnoreCase(legacy, tag)) return entry;
    }
    return null;
}

pub fn languageIndex(tag: []const u8) ?usize {
    for (&languages, 0..) |*entry, index| {
        if (std.ascii.eqlIgnoreCase(entry.tag, tag)) return index;
    }
    return null;
}

/// The USOS menu language (installer locale codes: pl, en, pt-BR, sr-Latn,
/// ...) -> the tag proposed for a new profile.
pub fn languageForUi(code: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "en", "en-US" },       .{ "pl", "pl-PL" }, .{ "bg", "bg-BG" }, .{ "cs", "cs-CZ" }, .{ "da", "da-DK" },
        .{ "de", "de-DE" },       .{ "el", "el-GR" }, .{ "es", "es-ES" }, .{ "et", "et-EE" }, .{ "fi", "fi-FI" },
        .{ "fr", "fr-FR" },       .{ "hr", "hr-HR" }, .{ "hu", "hu-HU" }, .{ "it", "it-IT" }, .{ "lt", "lt-LT" },
        .{ "lv", "lv-LV" },       .{ "nb", "nb-NO" }, .{ "nl", "nl-NL" }, .{ "pt-BR", "pt-BR" }, .{ "ro", "ro-RO" },
        .{ "ru", "ru-RU" },       .{ "sk", "sk-SK" }, .{ "sl", "sl-SI" }, .{ "sr-Latn", "sr-Latn-RS" }, .{ "sv", "sv-SE" },
        .{ "tr", "tr-TR" },       .{ "uk", "uk-UA" },
    };
    for (map) |pair| {
        if (std.ascii.eqlIgnoreCase(pair[0], code)) return pair[1];
    }
    return "en-US";
}

/// Default time zone proposed with a language (a new profile).
pub fn timeZoneForLanguage(tag: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "pl-PL", "Europe/Warsaw" },   .{ "cs-CZ", "Europe/Budapest" }, .{ "sk-SK", "Europe/Budapest" },
        .{ "hu-HU", "Europe/Budapest" }, .{ "sl-SI", "Europe/Budapest" }, .{ "sr-Latn-RS", "Europe/Budapest" },
        .{ "hr-HR", "Europe/Warsaw" },   .{ "de-DE", "Europe/Berlin" },   .{ "it-IT", "Europe/Berlin" },
        .{ "nl-NL", "Europe/Berlin" },   .{ "sv-SE", "Europe/Berlin" },   .{ "nb-NO", "Europe/Berlin" },
        .{ "da-DK", "Europe/Paris" },    .{ "fr-FR", "Europe/Paris" },    .{ "es-ES", "Europe/Paris" },
        .{ "en-GB", "Europe/London" },   .{ "pt-PT", "Europe/London" },   .{ "en-US", "America/New_York" },
        .{ "pt-BR", "America/Sao_Paulo" }, .{ "es-MX", "America/Mexico_City" }, .{ "fr-CA", "America/New_York" },
        .{ "bg-BG", "Europe/Kiev" },     .{ "et-EE", "Europe/Kiev" },     .{ "fi-FI", "Europe/Kiev" },
        .{ "lt-LT", "Europe/Kiev" },     .{ "lv-LV", "Europe/Kiev" },     .{ "uk-UA", "Europe/Kiev" },
        .{ "el-GR", "Europe/Bucharest" }, .{ "ro-RO", "Europe/Bucharest" }, .{ "tr-TR", "Europe/Bucharest" },
        .{ "ru-RU", "Europe/Moscow" },   .{ "ja-JP", "Asia/Tokyo" },      .{ "ko-KR", "Asia/Seoul" },
        .{ "zh-CN", "Asia/Shanghai" },   .{ "zh-TW", "Asia/Taipei" },
    };
    for (map) |pair| {
        if (std.ascii.eqlIgnoreCase(pair[0], tag)) return pair[1];
    }
    return "Etc/UTC";
}

test "time zone table: known pairs and unique ids" {
    const warsaw = timeZone("Europe/Warsaw").?;
    try std.testing.expectEqualStrings("Central European Standard Time", warsaw.windows);
    try std.testing.expectEqual(@as(u16, 100), warsaw.nt5);
    try std.testing.expectEqual(@as(u16, 95), timeZone("europe/budapest").?.nt5);
    try std.testing.expectEqual(@as(u16, 4), timeZone("America/Los_Angeles").?.nt5);
    try std.testing.expectEqual(@as(u16, 85), timeZone("Europe/London").?.nt5);
    try std.testing.expectEqualStrings("Europe/Budapest", timeZoneForNt5(95).?.id);
    try std.testing.expectEqualStrings("Europe/Warsaw", timeZoneForNt5(100).?.id);
    try std.testing.expect(timeZoneForNt5(301) == null);
    for (time_zones, 0..) |a, i| {
        try std.testing.expect(a.nt5 <= 300);
        try std.testing.expect(a.id.len <= 32 and a.windows.len <= 40);
        for (time_zones[i + 1 ..]) |b| try std.testing.expect(!std.ascii.eqlIgnoreCase(a.id, b.id));
    }
}

test "language table: known pairs, every UI language maps" {
    const pl = language("pl-PL").?;
    try std.testing.expectEqual(@as(u16, 0x0415), pl.lcid);
    try std.testing.expectEqual(@as(u8, 2), pl.group);
    try std.testing.expectEqual(@as(u32, 0x00000415), pl.keyboard);
    try std.testing.expectEqual(@as(u32, 0x00020409), language("nl-NL").?.keyboard);
    try std.testing.expectEqualStrings("sr-Latn-RS", language("sr-Latn-CS").?.tag);
    for ([_][]const u8{ "en", "pl", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv", "nb", "nl", "pt-BR", "ro", "ru", "sk", "sl", "sr-Latn", "sv", "tr", "uk" }) |code| {
        const tag = languageForUi(code);
        try std.testing.expect(language(tag) != null);
        try std.testing.expect(timeZone(timeZoneForLanguage(tag)) != null);
    }
    for (languages) |entry| try std.testing.expect(timeZone(timeZoneForLanguage(entry.tag)) != null);
}
