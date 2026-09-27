//! The answer-profile editor (docs/answer-profiles.md): the profile model
//! of src/flow/answer on the shared form (manual_form.zig). Field rules are
//! the model's (checked live: a bad value turns the row red and the help
//! panel says why); Save writes \EFI\USOS\profiles\<stem>.ini through
//! answer_profiles.save. The product key edited here is the one for the
//! system the editor was opened from (key.<system-id>); it is written only
//! with "Remember the key".
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const form = @import("manual_form.zig");
const view = @import("manual_view.zig");
const answer_profiles = @import("answer_profiles.zig");

const answer = usos.flow.answer;
const tables = answer.tables;
const Profile = answer.Profile;
const Problem = answer.profile.Problem;

const F = enum(u8) {
    name,
    user,
    user2,
    computer,
    org,
    password,
    timezone,
    language,
    locale,
    keyboard,
    key,
    edition,
    remember_key,
    local_account,
    bypass_tpm,
    bypass_secure_boot,
    bypass_ram,
    no_network,
    protect_pc,
    network_location,
    disable_wer,
    save,
    cancel,
};

const save_id: u8 = 1;
const cancel_id: u8 = 2;

var name_text = form.TextValue{ .max = 32 };
var user_text = form.TextValue{ .max = 20 };
var user2_text = form.TextValue{ .max = 20 };
var computer_text = form.TextValue{ .max = 15 };
var org_text = form.TextValue{ .max = 64 };
var password_text = form.TextValue{ .max = 64 };
var key_text = form.TextValue{ .max = 29 };
/// Edition: typed (no ISO known) or picked from the chosen ISO's images.
var edition_text = form.TextValue{ .max = 64 };
var edition_images: ?*const answer.editions.List = null;
var edition_index: usize = 0;
var edition_options: [answer.editions.max_images + 2][]const u8 = undefined;
var edition_option_count: usize = 0;
/// A stored edition that is not on this ISO stays selectable as it is.
var edition_custom: [64]u8 = undefined;
var edition_custom_len: usize = 0;
var timezone_index: usize = 0;
var language_index: usize = 0;
var locale_index: usize = 0;
var keyboard_index: usize = 0;
var remember_key = false;
var local_account = true;
var bypass_tpm = false;
var bypass_secure_boot = false;
var bypass_ram = false;
var no_network = false;
/// Index into ProtectPc order recommended, updates, off (protect_options).
var protect_index: usize = 2;
/// Index into NetworkLocation order work, home, public (network_options).
var network_index: usize = 0;
var disable_wer = false;
var protect_options: [3][]const u8 = undefined;
var network_options: [3][]const u8 = undefined;
const protect_values = [_]answer.profile.ProtectPc{ .recommended, .updates, .off };
const network_values = [_]answer.profile.NetworkLocation{ .work, .home, .public };

var zone_options: [tables.time_zones.len + 1][]const u8 = undefined;
var language_options: [tables.languages.len + 1][]const u8 = undefined;
var locale_options: [tables.languages.len + 1][]const u8 = undefined;
var keyboard_options: [tables.languages.len + 2][]const u8 = undefined;
var keyboard_option_count: usize = 0;
var custom_keyboard: ?answer.profile.Keyboard = null;
var custom_keyboard_text: [48]u8 = undefined;

const name_chars = form.charset(" ._-", true);
const account_chars = form.charset(" ._-", true);
const computer_chars = form.charset("-", true);
const key_chars = form.charset("-", true);
const org_chars = form.cleanAscii(true);
const password_chars = form.cleanAscii(false);

var fields_storage: [@typeInfo(F).@"enum".fields.len]form.Field = undefined;
var field_ids: [@typeInfo(F).@"enum".fields.len]F = undefined;
var field_count: usize = 0;

var base: Profile = .{};
var system_id_storage: [48]u8 = undefined;
var system_id: []const u8 = "";
var system_name: []const u8 = "";
var previous_stem: ?[]const u8 = null;
var previous_stem_storage: [32]u8 = undefined;
var key_label: [96]u8 = undefined;
var help_lines: [2][]const u8 = undefined;
var help_text: [2][200]u8 = undefined;
/// Save pressed with a problem: from then on every problem is shown.
var show_all = false;

fn t(key: view.Key) []const u8 {
    return view.t(key);
}

fn setOptions() void {
    zone_options[0] = t(.profile_value_auto);
    for (tables.time_zones, 0..) |zone, i| zone_options[i + 1] = zone.label;
    language_options[0] = t(.profile_value_auto);
    locale_options[0] = t(.profile_value_same_language);
    keyboard_options[0] = t(.profile_value_same_locale);
    protect_options = .{ t(.profile_value_protect_recommended), t(.profile_value_protect_updates), t(.profile_value_protect_off) };
    network_options = .{ t(.profile_value_network_work), t(.profile_value_network_home), t(.profile_value_network_public) };
    for (tables.languages, 0..) |entry, i| {
        language_options[i + 1] = entry.label;
        locale_options[i + 1] = entry.label;
        keyboard_options[i + 1] = entry.label;
    }
    keyboard_option_count = tables.languages.len + 1;
    edition_options[0] = t(.profile_value_setup_asks);
    edition_option_count = 1;
    if (edition_images) |list| {
        for (list.slice()) |*image| {
            edition_options[edition_option_count] = image.label();
            edition_option_count += 1;
        }
        if (edition_custom_len > 0) {
            edition_options[edition_option_count] = edition_custom[0..edition_custom_len];
            edition_option_count += 1;
        }
    }
    if (custom_keyboard) |k| {
        keyboard_options[keyboard_option_count] = std.fmt.bufPrint(&custom_keyboard_text, "{X:0>4}:{X:0>8}", .{ k.lcid, k.klid }) catch "custom";
        keyboard_option_count += 1;
    }
}

fn load(p: *const Profile) void {
    name_text.set(p.name.slice());
    user_text.set(p.user.slice());
    user2_text.set(p.user2.slice());
    computer_text.set(p.computer.slice());
    org_text.set(p.org.slice());
    password_text.set(p.password.slice());
    key_text.set(p.keyFor(system_id));
    const edition = p.editionFor(system_id);
    edition_text.set(edition);
    edition_index = 0;
    edition_custom_len = 0;
    if (edition_images) |list| if (edition.len > 0) {
        if (answer.editions.match(edition, list)) |image| {
            edition_index = @as(usize, @intCast(image - &list.items[0])) + 1;
        } else {
            edition_custom_len = @min(edition.len, edition_custom.len);
            @memcpy(edition_custom[0..edition_custom_len], edition[0..edition_custom_len]);
            edition_index = list.len + 1;
        }
    };
    timezone_index = if (p.timezone) |i| @as(usize, i) + 1 else 0;
    language_index = if (p.language) |i| @as(usize, i) + 1 else 0;
    locale_index = if (p.locale) |i| @as(usize, i) + 1 else 0;
    custom_keyboard = null;
    keyboard_index = 0;
    if (p.keyboard) |k| {
        keyboard_index = for (tables.languages, 0..) |entry, i| {
            if (entry.lcid == k.lcid and entry.keyboard == k.klid) break i + 1;
        } else blk: {
            custom_keyboard = k;
            break :blk tables.languages.len + 1;
        };
    }
    remember_key = p.remember_key;
    local_account = p.local_account;
    bypass_tpm = p.bypass_tpm;
    bypass_secure_boot = p.bypass_secure_boot;
    bypass_ram = p.bypass_ram;
    no_network = p.no_network_oobe;
    protect_index = std.mem.indexOfScalar(answer.profile.ProtectPc, &protect_values, p.protect_pc).?;
    network_index = std.mem.indexOfScalar(answer.profile.NetworkLocation, &network_values, p.network_location).?;
    disable_wer = p.disable_wer;
}

/// The profile as the form shows it (keys of other systems kept).
fn build(out: *Profile) void {
    out.* = base;
    out.name.set(name_text.slice()) catch {};
    out.user.set(user_text.slice()) catch {};
    out.user2.set(user2_text.slice()) catch {};
    out.computer.set(computer_text.slice()) catch {};
    out.org.set(org_text.slice()) catch {};
    out.password.set(password_text.slice()) catch {};
    out.timezone = if (timezone_index == 0) null else @intCast(timezone_index - 1);
    out.language = if (language_index == 0) null else @intCast(language_index - 1);
    out.locale = if (locale_index == 0) null else @intCast(locale_index - 1);
    out.keyboard = if (keyboard_index == 0) null else if (keyboard_index <= tables.languages.len) blk: {
        const entry = &tables.languages[keyboard_index - 1];
        break :blk .{ .lcid = entry.lcid, .klid = entry.keyboard };
    } else custom_keyboard;
    var upper: [29]u8 = undefined;
    const key = key_text.slice();
    for (key, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    out.setSystemKey(system_id, upper[0..key.len]) catch {};
    var id_buffer: [64]u8 = undefined;
    const edition: []const u8 = if (edition_images) |list| blk: {
        if (edition_index == 0) break :blk "";
        if (edition_index <= list.len) break :blk list.items[edition_index - 1].id(&id_buffer);
        break :blk edition_custom[0..edition_custom_len];
    } else edition_text.slice();
    out.setSystemEdition(system_id, edition) catch {};
    out.remember_key = remember_key;
    out.local_account = local_account;
    out.bypass_tpm = bypass_tpm;
    out.bypass_secure_boot = bypass_secure_boot;
    out.bypass_ram = bypass_ram;
    out.no_network_oobe = no_network;
    out.protect_pc = protect_values[protect_index];
    out.network_location = network_values[network_index];
    out.disable_wer = disable_wer;
    out.manual_disk = true;
}

fn problemOf(id: F) ?Problem {
    return switch (id) {
        .name => answer.profile.checkName(name_text.slice()) orelse if (duplicateName()) Problem.duplicate else null,
        .user => answer.profile.checkAccount(user_text.slice()),
        .user2 => if (user2_text.len == 0) null else answer.profile.checkAccount(user2_text.slice()) orelse if (std.ascii.eqlIgnoreCase(user_text.slice(), user2_text.slice())) Problem.same_as_user else null,
        .computer => answer.profile.checkComputer(computer_text.slice()),
        .org => answer.profile.checkOrg(org_text.slice()),
        .password => answer.profile.checkPassword(password_text.slice()),
        .key => answer.profile.checkKey(key_text.slice()),
        .edition => if (edition_images == null) answer.profile.checkEdition(edition_text.slice()) else null,
        else => null,
    };
}

fn duplicateName() bool {
    const index = answer_profiles.find(name_text.slice()) orelse return false;
    const current = previous_stem orelse return true;
    return !std.ascii.eqlIgnoreCase(answer_profiles.stem(index), current);
}

fn problemText(problem: Problem) []const u8 {
    return switch (problem) {
        .too_long => t(.profile_problem_too_long),
        .empty => t(.profile_problem_empty),
        .bad_characters => t(.profile_problem_bad_characters),
        .reserved_name => t(.profile_problem_reserved_name),
        .same_as_user => t(.profile_problem_same_as_user),
        .only_digits => t(.profile_problem_only_digits),
        .bad_key_format => t(.profile_problem_bad_key_format),
        .duplicate => t(.profile_problem_duplicate),
        else => t(.profile_problem_bad_characters),
    };
}

fn helpKey(id: F) view.Key {
    return switch (id) {
        .name => .profile_help_name,
        .user => .profile_help_user,
        .user2 => .profile_help_user2,
        .computer => .profile_help_computer,
        .org => .profile_help_org,
        .password => .profile_help_password,
        .timezone => .profile_help_timezone,
        .language => .profile_help_language,
        .locale => .profile_help_locale,
        .keyboard => .profile_help_keyboard,
        .key => .profile_help_key,
        .edition => .profile_help_edition,
        .remember_key => .profile_help_remember_key,
        .local_account => .profile_help_local_account,
        .bypass_tpm, .bypass_secure_boot, .bypass_ram => .profile_help_bypass,
        .no_network => .profile_help_no_network,
        .protect_pc => .profile_help_protect_pc,
        .network_location => .profile_help_network_location,
        .disable_wer => .profile_help_disable_wer,
        .save, .cancel => .profile_editor_subtitle,
    };
}

fn hookHelp(_: *anyopaque, index: usize) usos.gui.menu_screens.Help {
    const id = field_ids[index];
    help_lines[0] = if (id == .key) view.format(&help_text[0], .profile_help_key, &.{system_name}) else t(helpKey(id));
    var n: usize = 1;
    if (problemOf(id)) |problem| {
        if (show_all or !isEmptyRequired(id)) {
            help_lines[1] = problemText(problem);
            n = 2;
        }
    }
    return .{ .title = fields_storage[index].label, .lines = help_lines[0..n] };
}

/// An empty required field is not red until Save is pressed.
fn isEmptyRequired(id: F) bool {
    return switch (id) {
        .name => name_text.len == 0,
        .user => user_text.len == 0,
        else => false,
    };
}

fn hookInvalid(_: *anyopaque, index: usize) bool {
    const id = field_ids[index];
    const problem = problemOf(id) orelse return false;
    _ = problem;
    return show_all or !isEmptyRequired(id);
}

fn addField(id: F, field: form.Field) void {
    fields_storage[field_count] = field;
    field_ids[field_count] = id;
    field_count += 1;
}

fn buildFields() void {
    field_count = 0;
    const win11 = std.mem.eql(u8, system_id, "windows-11");
    // Vista and newer (autounattend.xml); the NT5 settings have no such pages.
    const family = answer.target.familyFor(system_id);
    const nt6 = if (family) |f| !f.nt5() else false;
    const legacy_nt6 = if (family) |f| !f.nt5() and f.legacyNt6() else false;
    addField(.name, .{ .kind = .text, .label = t(.profile_field_name), .text = &name_text, .allowed = &name_chars });
    addField(.user, .{ .kind = .text, .label = t(.profile_field_user), .text = &user_text, .allowed = &account_chars });
    addField(.user2, .{ .kind = .text, .label = t(.profile_field_user2), .text = &user2_text, .allowed = &account_chars });
    addField(.computer, .{ .kind = .text, .label = t(.profile_field_computer), .text = &computer_text, .allowed = &computer_chars, .uppercase = true, .placeholder = t(.profile_value_auto) });
    addField(.org, .{ .kind = .text, .label = t(.profile_field_org), .text = &org_text, .allowed = &org_chars });
    addField(.password, .{ .kind = .text, .label = t(.profile_field_password), .text = &password_text, .allowed = &password_chars, .secret = true });
    addField(.timezone, .{ .kind = .choice, .label = t(.profile_field_timezone), .options = &zone_options, .index = &timezone_index });
    addField(.language, .{ .kind = .choice, .label = t(.profile_field_language), .options = &language_options, .index = &language_index });
    addField(.locale, .{ .kind = .choice, .label = t(.profile_field_locale), .options = &locale_options, .index = &locale_index });
    addField(.keyboard, .{ .kind = .choice, .label = t(.profile_field_keyboard), .options = keyboard_options[0..keyboard_option_count], .index = &keyboard_index });
    addField(.key, .{ .kind = .text, .label = view.format(&key_label, .profile_field_key, &.{system_name}), .text = &key_text, .allowed = &key_chars, .uppercase = true, .placeholder = t(.profile_value_setup_asks) });
    if (nt6) {
        if (edition_images != null) {
            addField(.edition, .{ .kind = .choice, .label = t(.profile_field_edition), .options = edition_options[0..edition_option_count], .index = &edition_index });
        } else {
            addField(.edition, .{ .kind = .text, .label = t(.profile_field_edition), .text = &edition_text, .allowed = &org_chars, .placeholder = t(.profile_value_setup_asks) });
        }
    }
    addField(.remember_key, .{ .kind = .toggle, .label = t(.profile_field_remember_key), .flag = &remember_key });
    addField(.local_account, .{ .kind = .toggle, .label = t(.profile_field_local_account), .flag = &local_account });
    if (win11) {
        addField(.bypass_tpm, .{ .kind = .toggle, .label = t(.profile_field_bypass_tpm), .flag = &bypass_tpm });
        addField(.bypass_secure_boot, .{ .kind = .toggle, .label = t(.profile_field_bypass_secure_boot), .flag = &bypass_secure_boot });
        addField(.bypass_ram, .{ .kind = .toggle, .label = t(.profile_field_bypass_ram), .flag = &bypass_ram });
        addField(.no_network, .{ .kind = .toggle, .label = t(.profile_field_no_network), .flag = &no_network });
    }
    if (nt6) addField(.protect_pc, .{ .kind = .choice, .label = t(.profile_field_protect_pc), .options = &protect_options, .index = &protect_index });
    if (legacy_nt6) addField(.network_location, .{ .kind = .choice, .label = t(.profile_field_network_location), .options = &network_options, .index = &network_index });
    if (nt6) addField(.disable_wer, .{ .kind = .toggle, .label = t(.profile_field_disable_wer), .flag = &disable_wer });
    addField(.save, .{ .kind = .action, .label = t(.profile_save), .primary = true, .id = save_id });
    addField(.cancel, .{ .kind = .action, .label = t(.profile_cancel), .id = cancel_id });
}

var dummy_context: u8 = 0;

/// A new profile's defaults: the menu language, its time zone.
pub fn defaults(ui_language: []const u8) Profile {
    var p = Profile{};
    const tag = tables.languageForUi(ui_language);
    p.language = @intCast(tables.languageIndex(tag).?);
    p.timezone = @intCast(tables.timeZoneIndex(tables.timeZoneForLanguage(tag)).?);
    return p;
}

/// Edits `initial` (a new profile when `stem` is null, else the file with
/// that stem). Returns the saved profile's name, or null on Cancel/Back.
/// `images`: the install images of the ISO chosen before the answer screen
/// (the edition is then a list picker); null: the edition is typed.
pub fn edit(root: *uefi.protocol.File, initial: *const Profile, stem: ?[]const u8, for_system_id: []const u8, for_system_name: []const u8, images: ?*const answer.editions.List) ?[]const u8 {
    base = initial.*;
    edition_images = images;
    const n = @min(for_system_id.len, system_id_storage.len);
    @memcpy(system_id_storage[0..n], for_system_id[0..n]);
    system_id = system_id_storage[0..n];
    system_name = for_system_name;
    previous_stem = if (stem) |s| blk: {
        const m = @min(s.len, previous_stem_storage.len);
        @memcpy(previous_stem_storage[0..m], s[0..m]);
        break :blk previous_stem_storage[0..m];
    } else null;
    show_all = false;
    load(initial);
    setOptions();
    buildFields();
    var selected: usize = if (stem == null) 1 else 0;
    const hooks = form.Hooks{ .context = @ptrCast(&dummy_context), .help = hookHelp, .invalid = hookInvalid };
    while (true) {
        const title = if (stem == null) t(.profile_editor_new) else t(.profile_editor_title);
        switch (form.run(title, t(.profile_editor_subtitle), fields_storage[0..field_count], hooks, &selected)) {
            .back => return null,
            .x_on, .y_on => {},
            .action => |id| {
                if (id == cancel_id) return null;
                // Save: the first problem, if any, gets the selection.
                show_all = true;
                var first_problem: ?usize = null;
                for (field_ids[0..field_count], 0..) |fid, i| {
                    if (problemOf(fid) != null) {
                        first_problem = i;
                        break;
                    }
                }
                if (first_problem) |i| {
                    selected = i;
                    continue;
                }
                var profile: Profile = undefined;
                build(&profile);
                answer_profiles.save(root, &profile, previous_stem) catch |err| {
                    const lines = [_][]const u8{ view.t(.profile_save_failed), @errorName(err) };
                    view.notice(title, .warning, .warning, profile.name.slice(), &lines);
                    view.waitForDismiss();
                    continue;
                };
                return name_text.slice();
            },
        }
    }
}
