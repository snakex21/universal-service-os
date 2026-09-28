//! usos-answer: host front end of the answer renderers (src/flow/answer),
//! for the golden tests (tools/tests/test_answer_render.py) and for
//! rendering an answer file by hand.
//!
//!   usos-answer render PROFILE.ini SYSTEM-ID ARCH OUT [KEY|-] [INSTALL-XML]
//!     INSTALL-XML: the XML metadata of the media's install.wim (UTF-16LE
//!     with BOM, as stored in the WIM) for the profile's edition
//!   usos-answer render-linux PROFILE.ini FORMAT SALT OUT
//!     FORMAT: autoinstall | preseed | kickstart; SALT: 1-16 characters of
//!     [./0-9A-Za-z] (fixed for the goldens); the notes go to stderr
//!   usos-answer import-xp USOS-XP.ini OUT-PROFILE.ini
//!   usos-answer normalize PROFILE.ini OUT-PROFILE.ini
//!   usos-answer check-xml FILE.xml [MEDIA-ARCH]
//!
//! Exit codes: 0 ok, 1 invalid input (field and line on stderr, never the
//! value), 2 usage, 3 check-xml: architecture mismatch warning.
const std = @import("std");
const usos = @import("usos");
const answer = usos.flow.answer;

fn usage() u8 {
    std.debug.print(
        \\usage: usos-answer render PROFILE.ini SYSTEM-ID ARCH OUT [KEY|-] [INSTALL-XML]
        \\       usos-answer render-linux PROFILE.ini autoinstall|preseed|kickstart SALT OUT
        \\       usos-answer import-xp USOS-XP.ini OUT-PROFILE.ini
        \\       usos-answer normalize PROFILE.ini OUT-PROFILE.ini
        \\       usos-answer check-xml FILE.xml [MEDIA-ARCH]
        \\
    , .{});
    return 2;
}

fn report(issue: answer.profile.Issue) u8 {
    std.debug.print("invalid profile: field={s} problem={s} line={d}\n", .{
        if (issue.field) |f| @tagName(f) else "-", @tagName(issue.problem), issue.line,
    });
    return 1;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return usage();
    const cwd = std.Io.Dir.cwd();

    if (std.mem.eql(u8, command, "render")) {
        const profile_path = args.next() orelse return usage();
        const system_id = args.next() orelse return usage();
        const arch_text = args.next() orelse return usage();
        const out_path = args.next() orelse return usage();
        const key_arg = args.next();
        const key: ?[]const u8 = if (key_arg) |k| (if (std.mem.eql(u8, k, "-")) null else k) else null;
        const images_path = args.next();
        const arch = answer.Arch.fromText(arch_text) orelse return usage();
        const text = try cwd.readFileAlloc(io, profile_path, init.gpa, .limited(answer.profile.max_file + 1));
        defer init.gpa.free(text);
        var p: answer.Profile = undefined;
        switch (answer.profile.parse(text, &p)) {
            .ok => {},
            .invalid => |issue| return report(issue),
        }
        if (key) |k| if (answer.profile.checkKey(k) != null) return report(.{ .field = .key, .problem = .bad_key_format });
        var images: answer.editions.List = .{};
        if (images_path) |path| {
            const xml = try cwd.readFileAlloc(io, path, init.gpa, .limited(4 * 1024 * 1024));
            defer init.gpa.free(xml);
            answer.editions.parse(try usos.image_probe.windows_media.installXmlAscii(xml), &images);
            switch (answer.matchEdition(&p, system_id, &images)) {
                .none => {},
                .found => |image| std.debug.print("edition: image {d} ({s})\n", .{ image.index, image.label() }),
                .missing => std.debug.print("edition: not on the media, Setup asks\n", .{}),
            }
        }
        var buffer: [answer.autounattend.max_size]u8 = undefined;
        const rendered = (try answer.render(&p, system_id, arch, key, if (images_path != null) &images else null, &buffer)) orelse {
            std.debug.print("no generated answer for {s}\n", .{system_id});
            return 1;
        };
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = rendered.bytes });
        return 0;
    }
    if (std.mem.eql(u8, command, "render-linux")) {
        const profile_path = args.next() orelse return usage();
        const format_text = args.next() orelse return usage();
        const salt = args.next() orelse return usage();
        const out_path = args.next() orelse return usage();
        const format = std.meta.stringToEnum(answer.linux.Format, format_text) orelse return usage();
        const text = try cwd.readFileAlloc(io, profile_path, init.gpa, .limited(answer.profile.max_file + 1));
        defer init.gpa.free(text);
        var p: answer.Profile = undefined;
        switch (answer.profile.parse(text, &p)) {
            .ok => {},
            .invalid => |issue| return report(issue),
        }
        var buffer: [answer.linux.max_size]u8 = undefined;
        const result = answer.linux.render(&p, format, salt, &buffer) catch |err| {
            std.debug.print("render failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        var notes = result.notes.iterator();
        while (notes.next()) |note| std.debug.print("note: {s}\n", .{@tagName(note)});
        if (result.interactive_identity) std.debug.print("identity: interactive\n", .{});
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = result.bytes });
        return 0;
    }
    if (std.mem.eql(u8, command, "import-xp") or std.mem.eql(u8, command, "normalize")) {
        const in_path = args.next() orelse return usage();
        const out_path = args.next() orelse return usage();
        const text = try cwd.readFileAlloc(io, in_path, init.gpa, .limited(answer.profile.max_file + 1));
        defer init.gpa.free(text);
        var p: answer.Profile = undefined;
        const result = if (std.mem.eql(u8, command, "import-xp"))
            answer.profile.importXpIni(text, &p) orelse {
                std.debug.print("usos-xp.ini is inactive (user= is empty)\n", .{});
                return 1;
            }
        else
            answer.profile.parse(text, &p);
        switch (result) {
            .ok => {},
            .invalid => |issue| return report(issue),
        }
        var buffer: [answer.profile.max_file]u8 = undefined;
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = try answer.profile.write(&p, &buffer) });
        return 0;
    }
    if (std.mem.eql(u8, command, "check-xml")) {
        const path = args.next() orelse return usage();
        const text = try cwd.readFileAlloc(io, path, init.gpa, .limited(1024 * 1024));
        defer init.gpa.free(text);
        answer.xml_check.wellFormed(text) catch |err| {
            std.debug.print("not well-formed: {s}\n", .{@errorName(err)});
            return 1;
        };
        if (args.next()) |arch_text| {
            const arch = answer.Arch.fromText(arch_text) orelse return usage();
            if (answer.xml_check.mismatch(text, arch)) {
                std.debug.print("warning: no component for {s}\n", .{@tagName(arch)});
                return 3;
            }
        }
        return 0;
    }
    return usage();
}
