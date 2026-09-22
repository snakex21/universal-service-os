const menu_pointer = @import("menu_pointer.zig");
const console = @import("console.zig");
const diagnostics = @import("diagnostics.zig");
const menu_telemetry = @import("menu_telemetry.zig");
const graphics_menu = @import("graphics_menu.zig");
const vbe_probe = @import("vbe_probe.zig");

extern fn bios_power_off() callconv(.c) u32;
extern fn bios_restart() callconv(.c) noreturn;

const restart_index: usize = 0;
const shutdown_index: usize = 1;
const option_count: usize = 2;

pub fn show(diag: diagnostics.Info, graphics: *?vbe_probe.Session) void {
    var selected: usize = 0;
    var full_redraw = true;
    while (true) {
        menu_telemetry.setSelection(.power, selected);
        if (full_redraw) {
            render(selected, graphics);
            full_redraw = false;
        }
        const key = readMenuKey(graphics);
        if (key.selection != 255) {
            const index: usize = key.selection;
            selected = index;
            full_redraw = true;
        }
        menu_telemetry.recordKey(.power, selected, key);

        if (key.ascii == 'd' or key.ascii == 'D') {
            _ = showDiagnostics(graphics, diag);
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) return;
        if (key.scan == 0x48 or key.scan == 0x4B or key.scan == 0x50 or key.scan == 0x4D) {
            const previous = selected;
            if (key.scan == 0x48 or key.scan == 0x4B) {
                selected = if (selected == 0) option_count - 1 else selected - 1;
            } else {
                selected = (selected + 1) % option_count;
            }
            if (graphics.*) |*session| {
                graphics_menu.powerSelection(session, previous, selected);
            } else {
                full_redraw = true;
            }
            continue;
        }
        if (key.ascii != 13) continue;

        switch (selected) {
            restart_index => bios_restart(),
            shutdown_index => {
                _ = bios_power_off();
                showManualPowerOff(diag, graphics);
                full_redraw = true;
            },
            else => {},
        }
    }
}

fn render(selected: usize, graphics: *?vbe_probe.Session) void {
    if (graphics.*) |*session| {
        graphics_menu.power(session, selected);
        return;
    }
    console.clear();
    console.line("UNIVERSAL SERVICE OS");
    console.line("FIRMWARE: BIOS   POWER");
    console.line("");
    console.print(if (selected == restart_index) "> " else "  ");
    console.line("Restart");
    console.print(if (selected == shutdown_index) "> " else "  ");
    console.line("Shut down");
    console.line("");
    console.line("ARROWS: MOVE   ENTER: SELECT   ESC/BACKSPACE: BACK   D: DIAGNOSTICS");
}

fn showManualPowerOff(diag: diagnostics.Info, graphics: *?vbe_probe.Session) void {
    while (true) {
        renderManualPowerOff(graphics);
        const key = readMenuKey(graphics);
        if (key.ascii == 'd' or key.ascii == 'D') {
            _ = showDiagnostics(graphics, diag);
            continue;
        }
        if (key.ascii == 13 or key.ascii == 27 or key.ascii == 8) return;
    }
}

fn renderManualPowerOff(graphics: *?vbe_probe.Session) void {
    if (graphics.*) |*session| {
        graphics_menu.manualPowerOff(session);
        return;
    }
    console.clear();
    console.line("UNIVERSAL SERVICE OS");
    console.line("FIRMWARE: BIOS   POWER");
    console.line("");
    console.line("APM power-off is unavailable on this machine.");
    console.line("Turn off the computer manually.");
    console.line("");
    console.line("ENTER/ESC/BACKSPACE: BACK   D: DIAGNOSTICS");
}

fn readMenuKey(graphics: *?vbe_probe.Session) console.Key {
    if (graphics.* == null) {
        menu_pointer.stopListening();
        return console.readKey();
    }
    menu_pointer.listen();
    defer menu_pointer.stopListening();
    while (true) {
        if (console.readKeyTimeoutTicks(18)) |key| return key;
        if (graphics.*) |*session| {
            menu_pointer.hide();
            graphics_menu.refreshClock(session);
            menu_pointer.listen();
        }
    }
}

fn showDiagnostics(graphics: *?vbe_probe.Session, diag: diagnostics.Info) bool {
    if (graphics.*) |*session| {
        session.enterText();
        const result = diagnostics.show(diag);
        if (session.restore()) {
            console.line("VESA-2 GRAPHICS RESTORED");
        } else {
            graphics.* = null;
            console.line("VESA-2 GRAPHICS RESTORE FAILED - TEXT FALLBACK ACTIVE");
        }
        return result;
    }
    return diagnostics.show(diag);
}
