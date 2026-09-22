const catalog = @import("catalog");
const console = @import("console.zig");
const hardware_state = @import("hardware_state.zig");
const menu_telemetry = @import("menu_telemetry.zig");
const ntfs_diagnostics = @import("ntfs_diagnostics.zig");

pub const key_timeout_ticks: u32 = 546; // ~30 seconds at 18.2 Hz BIOS tick rate.

pub const RuntimeState = struct {
    before_discovery: hardware_state.Snapshot,
    after_discovery: hardware_state.Snapshot = .{},
    after_discovery_valid: bool = false,
    last_timeout: hardware_state.Snapshot = .{},
    last_timeout_valid: bool = false,
};

pub const Info = struct {
    bios_drive: u8,
    gpt_name: []const u8,
    fat32_label: []const u8,
    source: catalog.directory_source.Source,
    data_source: ?catalog.directory_source.Source = null,
    ntfs: *const ntfs_diagnostics.State,
    sector_reads: *const u32,
    cache_hits: *const usize,
    cache_misses: *const usize,
    hardware: *RuntimeState,
};

pub fn captureAfterDiscovery(info: Info) void {
    info.hardware.after_discovery = hardware_state.capture();
    info.hardware.after_discovery_valid = true;
}

pub fn captureTimeout(info: Info) void {
    info.hardware.last_timeout = hardware_state.capture();
    info.hardware.last_timeout_valid = true;
}

pub fn show(info: Info) bool {
    console.clear();
    console.line("USOS LEGACY BIOS DIAGNOSTICS");
    console.print("BIOS DRIVE: 0x");
    console.printHex8(info.bios_drive);
    console.print("\r\nGPT NAME: ");
    console.print(info.gpt_name);
    console.print("\r\nFAT32 BPB LABEL: ");
    console.print(info.fat32_label);
    console.print("\r\nINT13 SECTOR READS: ");
    console.printU32(info.sector_reads.*);
    console.print("\r\nDISCOVERY CACHE HITS/MISSES: ");
    console.printU32(@intCast(info.cache_hits.*));
    console.put('/');
    console.printU32(@intCast(info.cache_misses.*));
    printNtfsDiagnostics(info.ntfs);
    printLiveKeyboardTelemetry();
    printSnapshot("HW BEFORE DISCOVERY: ", info.hardware.before_discovery);
    if (info.hardware.after_discovery_valid) {
        printSnapshot("HW AFTER DISCOVERY:  ", info.hardware.after_discovery);
    } else {
        console.line("HW AFTER DISCOVERY:  [not captured]");
    }
    printSnapshot("HW NOW:              ", hardware_state.capture());
    if (info.hardware.last_timeout_valid) {
        printSnapshot("HW LAST TIMEOUT:     ", info.hardware.last_timeout);
    }
    console.print("\r\n");
    list("ROOT DIRECTORY", info.source, "\\");
    list("EFI DIRECTORY", info.source, "\\EFI");
    if (info.data_source) |data_source| list("DATA SYSTEMS", data_source, "\\Systems");
    console.line("");
    console.line("ESC/BACKSPACE: RETURN   AUTO-RETURN: 30s");
    while (true) {
        const key = console.readKeyTimeoutTicks(key_timeout_ticks) orelse {
            captureTimeout(info);
            return true;
        };
        if (key.ascii == 27 or key.ascii == 8) return false;
    }
}

pub fn printAfterDiscoveryLine(info: Info) void {
    if (!info.hardware.after_discovery_valid) return;
    printSnapshot("HW POST-DISCOVERY: ", info.hardware.after_discovery);
}

pub fn printLastTimeoutLine(info: Info) void {
    if (!info.hardware.last_timeout_valid) return;
    printSnapshot("LAST KEY TIMEOUT:  ", info.hardware.last_timeout);
}

fn printNtfsDiagnostics(state: *const ntfs_diagnostics.State) void {
    console.print("\r\nDATA GPT: ");
    if (!state.data_gpt_found) {
        console.line("NOT FOUND");
    } else {
        console.print("FOUND start_lba=");
        printU64Compact(state.data_start_lba);
        console.print(" sectors=");
        printU64Compact(state.data_sector_count);
        console.line("");
    }

    console.print("DATA VBR READ: ");
    if (!state.vbr_read) {
        console.line("FAIL");
    } else {
        console.print("PASS OEM_NTFS=");
        console.print(if (state.vbr_oem_ntfs) "yes" else "no");
        console.print(" SIG_55AA=");
        console.line(if (state.vbr_signature_valid) "yes" else "no");
        console.print("NTFS BPB: bytes_per_sector=");
        console.printU32(state.bytes_per_sector);
        console.print(" sectors_per_cluster=");
        console.printU32(state.sectors_per_cluster);
        console.print(" MFT_LCN=");
        printU64Compact(state.mft_lcn);
        console.line("");
    }

    console.print("NTFS MOUNT: ");
    if (state.mount_ok) {
        console.print("PASS MFT_RUNS=");
        console.printU32(@intCast(state.mft_runs));
        console.line("");
    } else {
        console.line("FAIL");
    }

    console.print("DATA \\Systems: ");
    if (!state.systems_probe_attempted) {
        console.line("NOT TESTED");
    } else if (state.systems_open_ok) {
        console.print("PASS entries=");
        console.printU32(@intCast(state.systems_entry_count));
        console.line("");
    } else {
        console.line("FAIL");
    }

    printIndexHash("INDEX PRE-VBE single", state.pre_vbe_index_single_ok, state.pre_vbe_index_single_hash);
    printIndexHash("INDEX PRE-VBE bulk", state.pre_vbe_index_bulk_ok, state.pre_vbe_index_bulk_hash);
    printIndexHash("INDEX POST-VBE single", state.post_vbe_index_single_ok, state.post_vbe_index_single_hash);
    printIndexHash("INDEX POST-VBE bulk", state.post_vbe_index_bulk_ok, state.post_vbe_index_bulk_hash);

    console.print("NTFS LAST ERROR: ");
    if (state.last_error) |err| {
        console.print(err);
        if (state.last_path_len != 0) {
            console.print(" path=");
            console.print(state.errorPath());
        }
        console.line("");
    } else {
        console.line("[none]");
    }
}

pub fn printIndexHash(label: []const u8, ok: bool, hash: u32) void {
    console.print(label);
    console.print(": ");
    if (!ok) {
        console.line("READ FAIL");
        return;
    }
    console.print("FNV32=0x");
    console.printHex32(hash);
    console.line("");
}

fn printU64Compact(value: u64) void {
    const high: u32 = @truncate(value >> 32);
    if (high == 0) {
        console.printU32(@truncate(value));
        return;
    }
    console.print("0x");
    console.printHex32(high);
    console.printHex32(@truncate(value));
}

pub fn printLiveKeyboardTelemetry() void {
    console.line("A20 POLICY: FAST 0x92 ONLY; INT15/8042 A20 DISABLED");
    console.print("A20 PORT92 WRITES: ");
    console.printU32(console.a20Port92WriteCount());
    console.print("   BEFORE/AFTER: 0x");
    console.printHex8(console.a20Port92Before());
    console.print("/0x");
    console.printHex8(console.a20Port92After());
    console.print("\r\n");
    console.line("8042: keyboard polling; AUX mouse enable/defaults/streaming only");
    console.print("INT13 READS: ");
    console.printU32(console.int13ReadCount());
    console.print("   8042 BEFORE/AFTER: 0x");
    console.printHex8(console.int13StatusBefore());
    console.print("/0x");
    console.printHex8(console.int13StatusAfter());
    console.print("\r\nKBD LIVE POLL CALLS: ");
    console.printU32(console.keyboardPollCount());
    console.print("   LAST STATUS: 0x");
    console.printHex8(console.lastKeyboardStatus());
    console.print("\r\nSCANCODES READ: ");
    console.printU32(console.scancodeCount());
    console.print("\r\nLAST RAW: 0x");
    console.printHex8(console.lastScancode());
    console.print("\r\nLAST ACCEPTED: 0x");
    console.printHex8(console.lastAcceptedScancode());
    console.print("\r\nRESP-LIKE BYTES: ");
    console.printU32(console.responseLikeCount());
    console.print("   LAST=0x");
    console.printHex8(console.lastResponseLike());
    console.print("   AA=BAT/LSHIFT-break only when unprefixed; E0 AA=fake shift\r\nRAW TAIL: ");
    console.printRawTail();
    console.print("\r\nMENU EVENTS: ");
    console.printU32(menu_telemetry.eventCount());
    console.print("   LAST MENU EVENT: ");
    console.print(menu_telemetry.lastEventName());
    console.print("\r\nMENU SCREEN: ");
    console.print(menu_telemetry.screenName());
    console.print("   SELECTED INDEX: ");
    console.printU32(menu_telemetry.selectedIndex());
    console.print("\r\nLAST ENTER: screen=");
    console.print(menu_telemetry.lastEnterScreenName());
    console.print(" index=");
    console.printU32(menu_telemetry.lastEnterIndex());
    console.print(" count=");
    console.printU32(menu_telemetry.enterCount());
    console.print(" event=ENTER\r\n");
}

fn printSnapshot(prefix: []const u8, snapshot: hardware_state.Snapshot) void {
    console.print(prefix);
    console.print("A20=");
    console.print(if (snapshot.a20_enabled) "ON" else "OFF");
    console.print(" PIC1=0x");
    console.printHex8(snapshot.pic1_mask);
    console.print(" IRR=0x");
    console.printHex8(snapshot.pic1_irr);
    console.print(" ISR=0x");
    console.printHex8(snapshot.pic1_isr);
    console.print(" 8042=0x");
    console.printHex8(snapshot.controller_8042_status);
    console.line("");
    console.print("    IDTR=");
    printHex32(snapshot.idtr_base);
    console.put('/');
    printHex16(snapshot.idtr_limit);
    console.print(" KBD=");
    printHex16(snapshot.keyboard_head);
    console.put('/');
    printHex16(snapshot.keyboard_tail);
    console.line("");
}

fn printHex16(value: u16) void {
    console.printHex8(@truncate(value >> 8));
    console.printHex8(@truncate(value));
}

fn printHex32(value: u32) void {
    printHex16(@truncate(value >> 16));
    printHex16(@truncate(value));
}

fn list(title: []const u8, source: catalog.directory_source.Source, path: []const u8) void {
    console.print(title);
    console.line(":");
    var entries: [catalog.directory_source.max_directory_entries]catalog.directory_source.Entry = undefined;
    const count = source.list(path, &entries) catch |err| {
        console.print("  [LIST FAIL error=");
        console.print(@errorName(err));
        console.line("]");
        return;
    };
    if (count == 0) {
        console.line("  [EMPTY]");
        return;
    }
    for (entries[0..count]) |entry| {
        console.print(if (entry.directory) "  [DIR]  " else "  [FILE] ");
        console.print(entry.name.slice());
        if (!entry.directory) {
            console.print(" bytes=");
            console.printU32(entry.size);
        }
        console.line("");
    }
}
