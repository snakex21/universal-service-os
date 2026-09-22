"""Run the production XP staging backend from an empty MBR disk in QEMU.

Only disposable image files are written. Export the result to VBox for Setup.
"""
import argparse
import gzip
import socket
import shutil
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import build_micro_linux as cpio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--blank", action="store_true")
    parser.add_argument("--existing", action="store_true", help="Preserve a sentinel primary partition before XPSETUP")
    parser.add_argument("--interactive", action="store_true", help="Exercise target selection and confirmation on tty1")
    parser.add_argument("--guard-only", action="store_true")
    parser.add_argument("--format-disk", action="store_true", help="Select whole-disk formatting through the actual UI")
    parser.add_argument("--cancel-format", action="store_true")
    parser.add_argument("--cancel-key", choices=["ret", "esc"], default="ret")
    parser.add_argument("--reset-tests", action="store_true")
    parser.add_argument("--gpt", action="store_true")
    parser.add_argument("--overview-tests", action="store_true")
    parser.add_argument("--graphical", action="store_true")
    parser.add_argument("--mouse", action="store_true")
    parser.add_argument("--back-cycle", action="store_true")
    parser.add_argument("--source-iso", type=Path, help="Read-only ISO device for testing a different source without rebuilding the USB fixture")
    parser.add_argument("--system", choices=['windows-xp', 'windows-2000'], default='windows-xp')
    args = parser.parse_args()
    title = 'WINDOWS 2000' if args.system == 'windows-2000' else 'WINDOWS XP'
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    qi = ROOT / "tools/qemu/qemu-img.exe"
    usos_source = ROOT / "zig-out/repair-bios-20260909/vbox-staging/fixture/xp-menu-usos.qcow2"
    usos = out / "usos.qcow2"
    target = out / "target.raw"
    size = 120034123776
    subprocess.run([str(qi), "create", "-f", "qcow2", "-F", "qcow2", "-b", str(usos_source), str(usos)], check=True)
    subprocess.run([str(qi), "create", "-f", "raw", str(target), str(size)], check=True)
    if not args.blank:
        with target.open("r+b") as handle:
            handle.seek(440); handle.write(struct.pack("<I", 0x1234abcd))
            handle.seek(510); handle.write(b"\x55\xaa")
    sentinel = b"USOS EXISTING PARTITION MUST SURVIVE\n" * 100
    if args.existing:
        assert not args.blank
        with target.open("r+b") as handle:
            handle.seek(446); handle.write(struct.pack("<B3sB3sII", 0, bytes(3), 7, bytes(3), 2048, 65536))
            handle.seek(2048 * 512); handle.write(sentinel)
    if args.gpt:
        assert args.format_disk and not args.blank
        from xp_gpt_test_fixture import write_gpt
        write_gpt(target, size)
    entries = cpio.parse_newc(gzip.decompress((ROOT / "zig-out/micro-linux/initramfs-usos").read_bytes()))
    for name in ["prepare_xp_local_source.sh", "prepare_xp_source_aliases.sh", "xp_dosnet_aliases.awk", "xp_menu_ui.sh", "xp_confirmation_ui.sh", "xp_detect_system.sh", "xp_disk_overview.sh", "xp_disk_reset.sh", "xp_disk_reset_ui.sh", "micro_linux_ui.sh", "target_disk_guard.sh", "legacy_xp_staging.sh", "prepare_xp_target.sh", "prepare_xp_windows_partition.sh", "xp_windows_partition_plan.awk", "xp_selected_partition.sif"]:
        cpio.put(entries, cpio.Entry("usr/lib/usos/" + name, stat.S_IFREG | 0o755, (ROOT / "tools" / name).read_bytes().replace(b"\r\n", b"\n")))
    cpio.put(entries, cpio.Entry("usr/lib/usos/xp_drive_letters.awk", stat.S_IFREG | 0o644, (ROOT / "tools/xp_drive_letters.awk").read_bytes()))
    for name in ['xp_source_io.sh', 'prepare_xp_ntfs_target.sh', 'nt5_profile.sh', 'probe_nt5_source.sh', 'probe_xp_source.sh', 'prepare_nt5_media_markers.sh']:
        cpio.put(entries, cpio.Entry('usr/lib/usos/' + name, stat.S_IFREG | 0o755, (ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n')))
    cpio.put(entries, cpio.Entry('usr/lib/usos/xp-nt52-ntfs.bin', stat.S_IFREG | 0o644, (ROOT / 'zig-out/xp-bios/xp-nt52-ntfs.bin').read_bytes()))
    image = (args.source_iso.name if args.source_iso else "windows_xp_professional_service_pack_2_x86_pl.iso").encode().hex()
    if args.source_iso:
        assert not args.graphical, "The ISO device fixture currently uses the PC IDE layout"
        script = entries["usr/lib/usos/legacy_xp_staging.sh"].data.decode()
        original = 'XP_IMAGE_PATH="/mnt/data/Systems/Windows/$NT5_NAME/Images/$XP_IMAGE_NAME"'
        assert original in script
        script = script.replace(original, 'XP_IMAGE_PATH=/dev/sdc', 1)
        script = script.replace('[ -f "$XP_IMAGE_PATH" ]', '[ -b "$XP_IMAGE_PATH" ]', 1)
        entries["usr/lib/usos/legacy_xp_staging.sh"].data = script.encode()
    injected = f'''USOS_XP_CHOOSING=yes
export NT5_SYSTEM={args.system}
BIOS_BOOT_DRIVE=80
BIOS_DISKS=80:0:400000:200:400:ff:3f,81:0:{size // 512:x}:200:400:f0:3f
. /usr/lib/usos/legacy_xp_staging.sh
usos_legacy_xp_staging {image}
'''
    if args.interactive:
        injected = 'rm -f /mnt/esp/EFI/USOS/legacy-xp-menu-test.ini\n' + injected
    if args.guard_only:
        assert args.blank and not args.existing and not args.interactive
        cpio.put(entries, cpio.Entry("test-guard.sh", stat.S_IFREG | 0o755, Path(__file__).with_name("xp_blank_guard_cases.sh").read_bytes()))
        injected = 'sh /test-guard.sh\npoweroff -f\n'
    if args.reset_tests:
        assert args.existing and not args.blank
        cpio.put(entries, cpio.Entry("test-reset.sh", stat.S_IFREG | 0o755, Path(__file__).with_name("xp_disk_reset_cases.sh").read_bytes()))
        injected = 'sh /test-reset.sh\npoweroff -f\n'
    if args.format_disk or args.cancel_format:
        assert args.interactive
    if args.overview_tests:
        assert args.existing
        cpio.put(entries, cpio.Entry("test-overview.sh", stat.S_IFREG | 0o755, Path(__file__).with_name("xp_overview_cases.sh").read_bytes()))
        injected = 'sh /test-overview.sh\npoweroff -f\n'
    with target.open("rb") as handle:
        before_mbr = handle.read(512)
    init = entries["usos-init"].data.decode()
    anchor = 'if [ -n "$LEGACY_ACTION" ]; then'
    assert anchor in init
    entries["usos-init"].data = init.replace(anchor, injected + anchor, 1).encode()
    initramfs = out / "initramfs-test"
    initramfs.write_bytes(gzip.compress(cpio.newc(entries), compresslevel=9, mtime=0))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
    serial = out / "serial.log"
    command = [str(ROOT / "tools/qemu/qemu-system-x86_64.exe"), "-machine", "pc", "-accel", "tcg,thread=multi", "-cpu", "max", "-m", "512", "-smp", "2", "-display", "none", "-nic", "none", "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off", "-serial", "file:" + str(serial), "-kernel", str(ROOT / "zig-out/micro-linux/vmlinuz-virt"), "-initrd", str(initramfs), "-append", "console=ttyS0,115200 rdinit=/usos-init usos.esp_partuuid=ed5ccc07-7a88-4bfe-b5d1-34d45b2db302", "-drive", "if=ide,index=0,format=qcow2,file=" + str(usos), "-drive", "if=none,id=target,format=raw,file=" + str(target), "-device", "ide-hd,bus=ide.0,unit=1,drive=target,serial=XP-TARGET-A"]
    if args.source_iso:
        command += ['-drive', 'if=ide,index=2,format=raw,snapshot=on,file=' + str(args.source_iso.resolve())]
    if args.graphical:
        command[command.index('-machine') + 1] = 'q35'
        command[command.index('ide-hd,bus=ide.0,unit=1,drive=target,serial=XP-TARGET-A')] = 'ide-hd,bus=ide.1,unit=0,drive=target,serial=XP-TARGET-A'
        for option in ['-kernel', '-initrd', '-append']:
            index = command.index(option)
            del command[index:index+2]
        boot = out / 'boot'
        (boot / 'EFI/BOOT').mkdir(parents=True)
        (boot / 'loader/entries').mkdir(parents=True)
        shutil.copyfile(ROOT / 'zig-out/micro-linux/systemd-bootx64.efi', boot / 'EFI/BOOT/BOOTX64.EFI')
        shutil.copyfile(ROOT / 'zig-out/micro-linux/vmlinuz-virt', boot / 'kernel')
        shutil.copyfile(initramfs, boot / 'initramfs')
        (boot / 'loader/loader.conf').write_text('default usos.conf\ntimeout 0\nconsole-mode 0\n')
        (boot / 'loader/entries/usos.conf').write_text('title USOS test\nlinux /kernel\ninitrd /initramfs\noptions console=tty0 console=ttyS0,115200 fbcon=nodefer quiet loglevel=3 rdinit=/usos-init usos.esp_partuuid=ed5ccc07-7a88-4bfe-b5d1-34d45b2db302\n')
        shutil.copyfile(ROOT / 'tools/qemu/share/edk2-i386-vars.fd', out / 'vars.fd')
        command += ['-drive', 'if=pflash,format=raw,readonly=on,file=' + str(ROOT / 'tools/qemu/share/edk2-x86_64-code.fd'), '-drive', 'if=pflash,format=raw,file=' + str(out / 'vars.fd'), '-drive', 'if=none,id=boot,format=raw,file=fat:rw:' + str(boot), '-device', 'ide-hd,bus=ide.2,unit=0,drive=boot,bootindex=1', '-vga', 'std']
    with (out / "qemu.log").open("w") as log:
        proc = subprocess.Popen(command, stdout=log, stderr=log, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            selected = confirmed = mode_selected = format_confirmed = False
            disk_seen = mode_seen = 0
            went_back = False
            def keys(sequence):
                with socket.create_connection(("127.0.0.1", port)) as sock:
                    for key in sequence:
                        sock.sendall(("sendkey " + key + "\n").encode())
                        time.sleep(0.3)
            def monitor(line):
                with socket.create_connection(("127.0.0.1", port)) as sock:
                    sock.sendall((line + '\n').encode())
                    time.sleep(0.5)
            def screenshot(name):
                if args.graphical:
                    monitor('screendump ' + str(out / (name + '.ppm')).replace('\\', '/'))
            def click_row(row):
                # PS/2 relative input: clamp our pointer at the upper left,
                # then move in bounded packets to the actual rendered row.
                width, height = 640, 480
                if args.graphical:
                    header = (out / 'disk-menu.ppm').read_bytes().split(b'\n', 3)
                    width, height = map(int, header[1].split())
                clamp = lambda v, lo, hi: min(hi, max(lo, v))
                y = clamp(height // 32, 16, 32) + clamp(height // 22, 28, 44) + clamp(height // 36, 18, 28) + clamp(height // 48, 12, 22) + 12 + row * 62 + 24
                x = clamp(width // 32, 20, 40) + 80
                with socket.create_connection(('127.0.0.1', port)) as sock:
                    for _ in range(max(width, height) // 80 + 2):
                        sock.sendall(b'mouse_move -80 -80\n'); time.sleep(0.02)
                    while x or y:
                        dx, dy = min(x, 80), min(y, 80)
                        sock.sendall(f'mouse_move {dx} {dy}\n'.encode()); time.sleep(0.03)
                        x -= dx; y -= dy
                    time.sleep(0.5)
                    sock.sendall(b'mouse_button 1\n'); time.sleep(0.2)
                    sock.sendall(b'mouse_button 0\n'); time.sleep(0.3)
            end = time.monotonic() + 480
            while time.monotonic() < end:
                transcript = serial.read_text(errors="replace") if serial.exists() else ""
                if args.overview_tests and "[OVERVIEW_TEST] ALL PASS" in transcript:
                    break
                if "[OVERVIEW_TEST] FAIL:" in transcript:
                    raise RuntimeError(transcript[-6000:])
                if args.guard_only and "[BLANK_GUARD_TEST] ALL PASS" in transcript:
                    break
                if args.reset_tests and "[RESET_TEST] ALL PASS" in transcript:
                    break
                if "[RESET_TEST] FAIL:" in transcript:
                    raise RuntimeError(transcript[-6000:])
                if "[BLANK_GUARD_TEST] FAIL:" in transcript:
                    raise RuntimeError(transcript[-6000:])
                if args.interactive and transcript.count(f"[XP_MENU] READY: {title} - SELECT DISK") > disk_seen:
                    disk_seen += 1
                    screenshot('disk-menu')
                    if args.mouse: click_row(0)
                    else: keys(["down", "up", "ret"])
                    selected = True
                if args.interactive and transcript.count(f"[XP_MENU] READY: {title} - PREPARE DISK") > mode_seen:
                    mode_seen += 1
                    screenshot('disk-mode')
                    if args.back_cycle and not went_back:
                        keys(['esc']); went_back = True
                    elif args.mouse:
                        click_row(1 if args.format_disk or args.cancel_format else 0)
                    else:
                        keys(["down", "ret"] if args.format_disk or args.cancel_format else ["ret"])
                    mode_selected = True
                if args.interactive and not format_confirmed and "[XP_MENU] READY: FORMAT THE ENTIRE DISK?" in transcript:
                    screenshot('confirmation')
                    sequence = [args.cancel_key] if args.cancel_format else ["left", "ret"]
                    if args.mouse: click_row(1 if args.cancel_format else 0)
                    else: keys(sequence)
                    format_confirmed = True
                if args.cancel_format and "Formatting cancelled; no target write occurred" in transcript:
                    break
                if args.interactive and not confirmed and f"[XP_MENU] READY: {title} - CONFIRMATION" in transcript:
                    keys(["tab", "ret"]); confirmed = True
                if "[LEGACY_XP] TEST STOP AFTER PREPARE" in transcript or "[LEGACY_XP] WAITING FOR USER:" in transcript:
                    break
                if "[MICRO-LINUX] STOP:" in transcript or "PARTUUID DIAGNOSTIC FROZEN" in transcript or proc.poll() is not None:
                    raise RuntimeError(transcript[-6000:])
                time.sleep(1)
            else:
                raise TimeoutError(transcript[-6000:])
        finally:
            if proc.poll() is None:
                with socket.create_connection(("127.0.0.1", port)) as sock:
                    sock.sendall(b"quit\n")
                    time.sleep(0.5)
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait()
    if args.reset_tests:
        print('[PASS] Eight reset refusals and confirmed empty MBR preparation')
        return
    if args.overview_tests:
        print('[PASS] Read-only FAT/NTFS inspection, busy disk, system detection')
        return
    if args.cancel_format:
        if args.back_cycle:
            assert disk_seen >= 2 and mode_seen >= 2
        with target.open('rb') as handle:
            assert handle.read(512) == before_mbr
            handle.seek(2048 * 512)
            assert handle.read(len(sentinel)) == sentinel
        assert '[XP_RESET] RESET PASS' not in transcript
        print('[PASS] UI cancellation preserved MBR and existing data')
        return
    if args.guard_only:
        print("[PASS] Six blank-disk guard rejection cases; final snapshot unchanged")
        return
    assert "[XP_WINDOWS] PREPARED PASS" in transcript, transcript[-6000:]
    if args.interactive:
        assert selected and (format_confirmed if args.format_disk else confirmed) and "TEST AUTO-SELECT" not in transcript
        if args.format_disk:
            assert f"[XP_MENU] READY: {title} - CONFIRMATION" not in transcript
    with target.open("rb") as handle:
        mbr = handle.read(512)
    assert mbr[:440] == (ROOT / "zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin").read_bytes()
    assert mbr[440:444] != bytes(4)
    if not args.blank and not args.format_disk:
        assert mbr[440:444] == struct.pack("<I", 0x1234abcd)
    if args.existing and not args.format_disk:
        assert mbr[450] == 7 and mbr[462] == 128 and mbr[466] == 7
        assert mbr[478:510] == bytes(32)
        with target.open("rb") as handle:
            handle.seek(2048 * 512)
            assert handle.read(len(sentinel)) == sentinel
    else:
        assert mbr[446] == 128 and mbr[450] == 7
        assert mbr[462:510] == bytes(48)
    setup_entry = 462 if args.existing and not args.format_disk else 446
    setup_start = struct.unpack_from('<I', mbr, setup_entry + 8)[0]
    with target.open('rb') as handle:
        handle.seek(setup_start * 512)
        vbr = handle.read(512)
        setup_sectors = struct.unpack_from('<I', mbr, setup_entry + 12)[0]
        handle.seek((setup_start + setup_sectors - 1) * 512)
        assert handle.read(512) == vbr, 'Backup VBR differs'
    assert vbr[3:11] == b'NTFS    '
    assert struct.unpack_from('<HH', vbr, 24) == (63, 240), 'Successor XP loader needs actual BIOS geometry'
    assert struct.unpack_from('<I', vbr, 28)[0] == setup_start
    assert 'Windows=C: layout=single-volume' in transcript
    if args.gpt:
        with target.open('rb') as handle:
            handle.seek(512)
            assert handle.read(33 * 512) == bytes(33 * 512), 'Primary GPT survived format'
            # NTFS may use part of the cleared last MiB after reset. Only the
            # former GPT header/table must still be zero after full staging.
            handle.seek(size - 33 * 512)
            assert handle.read(33 * 512) == bytes(33 * 512), 'Backup GPT survived format'
        assert 'pttype=gpt' in transcript
    vdi = out / "target.vdi"
    subprocess.run([str(qi), "convert", "-f", "raw", "-O", "vdi", str(target), str(vdi)], check=True)
    subprocess.run([sys.executable, str(Path(__file__).with_name("patch_vdi_geometry.py")), str(vdi), "--cylinders", "1024", "--heads", "240", "--sectors", "63"], check=True)
    print("[PASS] Production automatic XP staging: " + str(vdi))


if __name__ == "__main__":
    main()
