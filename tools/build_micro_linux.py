#!/usr/bin/env python3
"""Build the USOS micro-Linux initramfs from pinned Alpine artifacts."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request

# Windows Embedded POSReady 2009: the XP x86 X470 driver set (under
# media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86), as
# tools/xp_driver_overlay.py SELECTED.
POSREADY_DRIVERS = (
    "ACPI/acpi.sys", "Dependencies/ntoskrn8.sys", "Dependencies/storport.sys", "KMDF/wdf01000.sys", "KMDF/wdfldr.sys",
    "SATA/genahci.sys", "SATA/genahci.inf", "USB3/ksecd8.sys", "USB3/ucx01000.sys", "USB3/usbd8.sys", "USB3/usbhub3.sys",
    "USB3/usbhub3.inf", "USB3/usbxhci.sys", "USB3/usbxhci.inf", "USB3/wpprecor.sys",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def obtain(root: Path, record: dict[str, object], destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected = str(record["sha256"]).lower()
    if destination.exists() and sha256(destination) == expected:
        return destination
    if destination.exists():
        destination.unlink()
    if os.environ.get("USOS_OFFLINE") == "1":
        raise RuntimeError(f"offline build: {destination} is missing or differs (restore it with tools/release/use_buildkit.ps1)")
    print(f"[MICRO-LINUX] download {record['url']}")
    urllib.request.urlretrieve(str(record["url"]), destination)
    actual = sha256(destination)
    if actual != expected:
        destination.unlink(missing_ok=True)
        raise RuntimeError(f"SHA-256 mismatch for {destination.name}: {actual}")
    return destination


class Entry:
    def __init__(self, name: str, mode: int, data: bytes = b"", link: str = "") -> None:
        self.name = name.strip("/")
        self.mode = mode
        self.data = data
        self.link = link


def archive_entries(apk: Path) -> list[Entry]:
    result: list[Entry] = []
    data_by_name: dict[str, bytes] = {}
    with tarfile.open(apk, "r:gz") as archive:
        for member in archive.getmembers():
            name = member.name.lstrip("./")
            if not name or name.startswith("."):
                continue
            mode = member.mode & 0o7777
            if member.isdir():
                result.append(Entry(name, stat.S_IFDIR | mode))
            elif member.issym():
                result.append(Entry(name, stat.S_IFLNK | mode, member.linkname.encode("utf-8"), member.linkname))
            elif member.islnk():
                target = member.linkname.lstrip("./")
                payload = data_by_name.get(target)
                if payload is None:
                    source = archive.extractfile(member)
                    payload = source.read() if source else b""
                data_by_name[name] = payload
                result.append(Entry(name, stat.S_IFREG | mode, payload))
            elif member.isfile():
                source = archive.extractfile(member)
                payload = source.read() if source else b""
                data_by_name[name] = payload
                result.append(Entry(name, stat.S_IFREG | mode, payload))
    return result


def ensure_parents(entries: dict[str, Entry], name: str) -> None:
    parent = PurePosixPath(name).parent
    parts: list[str] = []
    for component in parent.parts:
        if component in ("", "."):
            continue
        parts.append(component)
        current = "/".join(parts)
        entries.setdefault(current, Entry(current, stat.S_IFDIR | 0o755))


def put(entries: dict[str, Entry], entry: Entry) -> None:
    ensure_parents(entries, entry.name)
    entries[entry.name] = entry


def merged_usr_entry(entry: Entry) -> Entry | None:
    """Keep Alpine initramfs' /bin, /sbin and /lib symlinks intact."""
    for root in ("bin", "sbin", "lib"):
        if entry.name == root:
            return None
        prefix = root + "/"
        if entry.name.startswith(prefix):
            return Entry("usr/" + entry.name, entry.mode, entry.data, entry.link)
    return entry


def pad4(stream: io.BytesIO) -> None:
    missing = (-stream.tell()) % 4
    if missing:
        stream.write(b"\0" * missing)


def pad_initrd(data: bytes) -> bytes:
    """Zero-pads a compressed initramfs to a multiple of 4 bytes.

    Loaders (the kernel EFI stub, systemd-boot) append EFI/USOS/lang.cpio
    right after this file. The kernel accepts a cpio header only at a
    4-byte-aligned offset: otherwise lang.cpio is dropped ("invalid magic
    at start of compressed archive") and the UI falls back to English.
    The kernel and gzip readers skip the trailing zeros."""
    return data + b"\0" * ((-len(data)) % 4)


def newc(entries: dict[str, Entry]) -> bytes:
    stream = io.BytesIO()
    inode = 1
    for name in sorted(entries):
        entry = entries[name]
        payload = entry.data
        encoded_name = name.encode("utf-8") + b"\0"
        fields = (
            inode,
            entry.mode,
            0,
            0,
            1,
            0,
            len(payload),
            0,
            0,
            0,
            0,
            len(encoded_name),
            0,
        )
        stream.write(b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields))
        stream.write(encoded_name)
        pad4(stream)
        stream.write(payload)
        pad4(stream)
        inode += 1
    trailer = b"TRAILER!!!\0"
    fields = (inode, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(trailer), 0)
    stream.write(b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields))
    stream.write(trailer)
    pad4(stream)
    return stream.getvalue()


def parse_newc(data: bytes) -> dict[str, Entry]:
    """Parse Alpine's single newc archive so we can prune its generic module set."""
    entries: dict[str, Entry] = {}
    offset = 0
    while offset + 110 <= len(data):
        while offset < len(data) and data[offset] == 0:
            offset += 1
        if offset >= len(data):
            break
        if data[offset : offset + 6] != b"070701":
            raise RuntimeError(f"unsupported initramfs cpio member at offset {offset}")
        header = data[offset + 6 : offset + 110]
        fields = [int(header[index : index + 8], 16) for index in range(0, 104, 8)]
        mode = fields[1]
        file_size = fields[6]
        name_size = fields[11]
        name_start = offset + 110
        name_end = name_start + name_size
        if name_size == 0 or name_end > len(data):
            raise RuntimeError("invalid initramfs cpio name")
        name = data[name_start : name_end - 1].decode("utf-8")
        payload_start = (name_end + 3) & ~3
        payload_end = payload_start + file_size
        if payload_end > len(data):
            raise RuntimeError(f"truncated initramfs cpio payload: {name}")
        payload = data[payload_start:payload_end]
        offset = (payload_end + 3) & ~3
        if name == "TRAILER!!!":
            break
        if name in ("", "."):
            continue
        link = payload.decode("utf-8") if stat.S_IFMT(mode) == stat.S_IFLNK else ""
        put(entries, Entry(name, mode, payload, link))
    return entries


def prune_lts_base(entries: dict[str, Entry]) -> dict[str, Entry]:
    """Keep Alpine userspace, but remove its broad preselected modules/firmware."""
    pruned: dict[str, Entry] = {}
    for name, entry in entries.items():
        if name == ".modloop" or name.startswith(".modloop/"):
            continue
        if name == "usr/lib/modules" or name.startswith("usr/lib/modules/"):
            continue
        if name == "usr/lib/firmware" or name.startswith("usr/lib/firmware/"):
            continue
        put(pruned, entry)
    return pruned


def run_7z(seven_zip: Path, *arguments: str) -> None:
    subprocess.run([str(seven_zip), *arguments], check=True, stdout=subprocess.DEVNULL)


def verify_static_linux_elf(path: Path) -> None:
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise RuntimeError(f"framebuffer UI is not an ELF executable: {path}")
    if data[4] != 2 or data[5] != 1:
        raise RuntimeError("framebuffer UI must be ELF64 little-endian")
    if int.from_bytes(data[18:20], "little") != 62:
        raise RuntimeError("framebuffer UI must target x86_64")
    program_offset = int.from_bytes(data[32:40], "little")
    program_entry_size = int.from_bytes(data[54:56], "little")
    program_count = int.from_bytes(data[56:58], "little")
    for index in range(program_count):
        start = program_offset + index * program_entry_size
        end = start + program_entry_size
        if end > len(data) or program_entry_size < 4:
            raise RuntimeError("invalid framebuffer UI ELF program header table")
        program_type = int.from_bytes(data[start : start + 4], "little")
        if program_type == 3:  # PT_INTERP
            raise RuntimeError("framebuffer UI is dynamically linked (PT_INTERP present)")


def read_module_dependencies(modules_dep: Path) -> dict[str, list[str]]:
    dependencies: dict[str, list[str]] = {}
    for raw_line in modules_dep.read_text(encoding="utf-8").splitlines():
        module, separator, tail = raw_line.partition(":")
        if separator:
            dependencies[module] = [item for item in tail.split() if item]
    return dependencies


def module_dependency_closure(
    dependencies: dict[str, list[str]], root_modules: list[str]
) -> list[str]:
    ordered: list[str] = []
    visited: set[str] = set()
    visiting: set[str] = set()

    def visit(module: str) -> None:
        if module in visited:
            return
        if module in visiting:
            raise RuntimeError(f"module dependency cycle detected at: {module}")
        if module not in dependencies:
            raise RuntimeError(f"module is missing from modules.dep: {module}")
        visiting.add(module)
        for dependency in dependencies[module]:
            visit(dependency)
        visiting.remove(module)
        visited.add(module)
        ordered.append(module)

    for root_module in root_modules:
        visit(root_module)
    return ordered


def elf_needed(data: bytes) -> list[str]:
    """DT_NEEDED sonames of an ELF64 little-endian file ([] for anything else)."""
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return []
    u16 = lambda at: int.from_bytes(data[at : at + 2], "little")  # noqa: E731
    u64 = lambda at: int.from_bytes(data[at : at + 8], "little")  # noqa: E731
    phoff, phentsize, phnum = u64(32), u16(54), u16(56)
    loads: list[tuple[int, int, int]] = []
    dynamic: tuple[int, int] | None = None
    for index in range(phnum):
        at = phoff + index * phentsize
        kind = int.from_bytes(data[at : at + 4], "little")
        if kind == 1:  # PT_LOAD
            loads.append((u64(at + 16), u64(at + 8), u64(at + 32)))
        elif kind == 2:  # PT_DYNAMIC
            dynamic = (u64(at + 8), u64(at + 32))
    if dynamic is None:
        return []
    needed: list[int] = []
    strtab = None
    for at in range(dynamic[0], dynamic[0] + dynamic[1], 16):
        tag, value = u64(at), u64(at + 8)
        if tag == 0:
            break
        if tag == 1:
            needed.append(value)
        elif tag == 5:
            strtab = value
    if strtab is None:
        return []
    for vaddr, offset, size in loads:
        if vaddr <= strtab < vaddr + size:
            strtab = strtab - vaddr + offset
            break
    else:
        raise RuntimeError("ELF string table outside the loaded segments")
    return [data[strtab + item : data.index(b"\0", strtab + item)].decode("ascii") for item in needed]


def qemu9x_entries(
    lock: dict[str, object], packages: list[tuple[dict[str, object], Path]], base: dict[str, Entry]
) -> dict[str, Entry]:
    """The optional Windows 9x phase-1 VM initrd (qemu9x.cpio): QEMU, its
    firmware and the shared objects it needs that initramfs-usos lacks."""
    entries: dict[str, Entry] = {}
    libraries: dict[str, Entry] = {}
    for record, package in packages:
        only = record.get("files")
        mapping = record.get("map") or {}
        for entry in archive_entries(package):
            normalized = merged_usr_entry(entry)
            if normalized is None:
                continue
            name = normalized.name
            if name in mapping:
                put(entries, Entry(str(mapping[name]), normalized.mode, normalized.data, normalized.link))
            elif only is not None and name in only:
                put(entries, normalized)
            elif name.startswith("usr/lib/") and name.count("/") == 2 and ".so" in name:
                libraries[name] = normalized
    binary = str(lock["binary"])
    if binary not in entries:
        raise RuntimeError(f"qemu9x: {binary} missing from the pinned packages")
    for required in ("usr/share/qemu/bios-256k.bin", "usr/share/qemu/vgabios-stdvga.bin"):
        if required not in entries:
            raise RuntimeError(f"qemu9x: firmware missing: {required}")

    def resolve(soname: str) -> Entry | None:
        name = "usr/lib/" + soname
        seen = 0
        while seen < 8:
            # initramfs-usos already has it (and its own dependencies).
            if name in base:
                return base[name] if stat.S_IFMT(base[name].mode) != stat.S_IFLNK else Entry(name, stat.S_IFREG, b"")
            entry = libraries.get(name)
            if entry is None:
                return None
            put(entries, entry)
            if stat.S_IFMT(entry.mode) != stat.S_IFLNK:
                return entry
            name = str(PurePosixPath(name).parent / entry.link) if not entry.link.startswith("/") else entry.link.lstrip("/")
            name = name.replace("lib/../", "").replace("usr/usr/", "usr/")
            if name.startswith("lib/"):
                name = "usr/" + name
            seen += 1
        raise RuntimeError(f"qemu9x: symlink loop for {soname}")

    pending = [entries[binary]]
    done: set[str] = set()
    missing: list[str] = []
    while pending:
        for soname in elf_needed(pending.pop().data):
            if soname in done:
                continue
            done.add(soname)
            if soname.startswith("libc.musl") or soname.startswith("ld-musl"):
                continue
            target = resolve(soname)
            if target is None:
                missing.append(soname)
            elif target.name in libraries:
                pending.append(target)
    if missing:
        raise RuntimeError(f"qemu9x: unresolved shared objects: {sorted(missing)}")
    return entries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--seven-zip", type=Path, required=True)
    parser.add_argument("--fb-ui", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    root = args.project_root.resolve()
    seven_zip = args.seven_zip.resolve()
    framebuffer_ui = args.fb_ui.resolve()
    output = args.output_dir.resolve()
    if not framebuffer_ui.is_file():
        raise FileNotFoundError(framebuffer_ui)
    verify_static_linux_elf(framebuffer_ui)
    lock = json.loads((root / "tools/micro_linux.lock.json").read_text(encoding="utf-8"))
    lts = lock["alpine_lts"]
    kernel_record = lts["kernel"]
    initramfs_record = lts["initramfs"]
    modloop_record = lts["modloop"]
    kernel = obtain(root, kernel_record, root / str(kernel_record["file"]))
    base_initramfs = obtain(root, initramfs_record, root / str(initramfs_record["file"]))
    modloop = obtain(root, modloop_record, root / str(modloop_record["file"]))
    packages_dir = root / "tools/cache/alpine/packages"
    packages: list[tuple[dict[str, object], Path]] = []
    for record in lock["packages"]:
        packages.append((record, obtain(root, record, packages_dir / str(record["file"]))))
    qemu9x_lock = lock["qemu9x"]
    qemu9x_packages = [
        (record, obtain(root, record, packages_dir / str(record["file"]))) for record in qemu9x_lock["packages"]
    ]

    with tempfile.TemporaryDirectory(prefix="usos-micro-linux-") as temp_name:
        temp = Path(temp_name)
        modloop_out = temp / "modloop"
        run_7z(
            seven_zip,
            "x",
            "-y",
            f"-o{modloop_out}",
            str(modloop),
            "modules/*/modules.*",
        )
        modules_dep_files = list(modloop_out.glob("modules/*/modules.dep"))
        if len(modules_dep_files) != 1:
            raise RuntimeError(f"expected exactly one modules.dep, found {len(modules_dep_files)}")
        modules_dep = modules_dep_files[0]
        kernel_release = modules_dep.parent.name
        dependencies = read_module_dependencies(modules_dep)

        # LTS is deliberately broad. Keep the complete libata driver family so
        # PCI modalias probing covers nForce, VIA, SiS, Intel ICH, Promise,
        # Silicon Image and other controllers from the 2000-2010 era without a
        # custom kernel. Only matching PCI aliases are loaded at runtime.
        legacy_ata_roots = sorted(
            module
            for module in dependencies
            if module.startswith("kernel/drivers/ata/") and module.endswith(".ko")
        )
        runtime_roots = [
            "kernel/fs/isofs/isofs.ko",
            "kernel/fs/udf/udf.ko",
            "kernel/fs/ntfs3/ntfs3.ko",
            "kernel/lib/crc/crc-itu-t.ko",
            "kernel/drivers/hid/hid.ko",
            "kernel/drivers/hid/hid-generic.ko",
            "kernel/drivers/hid/usbhid/usbhid.ko",
            "kernel/drivers/input/evdev.ko",
            "kernel/drivers/input/mouse/psmouse.ko",
            # Gamepads (Xbox-compatible, incl. the ROG Ally's built-in pad in
            # gamepad mode), touchscreens (USB and I2C HID multitouch; the
            # AMD/Intel I2C controllers and GPIO are built into the kernel)
            # and the ASUS HID keys (ROG Ally N-KEY device 0b05:1abe/1b4c).
            "kernel/drivers/input/joystick/xpad.ko",
            "kernel/drivers/hid/hid-multitouch.ko",
            "kernel/drivers/hid/i2c-hid/i2c-hid-acpi.ko",
            "kernel/drivers/hid/hid-asus.ko",
            "kernel/drivers/usb/host/xhci-hcd.ko",
            "kernel/drivers/usb/host/xhci-pci.ko",
            "kernel/drivers/usb/host/ehci-hcd.ko",
            "kernel/drivers/usb/host/ehci-pci.ko",
            "kernel/drivers/usb/host/ohci-hcd.ko",
            "kernel/drivers/usb/host/ohci-pci.ko",
            "kernel/drivers/usb/storage/usb-storage.ko",
            "kernel/drivers/usb/storage/uas.ko",
            "kernel/drivers/scsi/sd_mod.ko",
            # virtio_blk/virtio_scsi only bind through the virtio PCI
            # transport (virtio_pci + virtio_pci_{modern,legacy}_dev, pulled
            # in by modules.dep); without it QEMU's virtio disks stay invisible.
            "kernel/drivers/virtio/virtio_pci.ko",
            "kernel/drivers/scsi/virtio_scsi.ko",
            "kernel/drivers/block/virtio_blk.ko",
            "kernel/drivers/block/loop.ko",
            "kernel/drivers/nvme/host/nvme.ko",
            "kernel/fs/fuse/fuse.ko",
            "kernel/fs/nls/nls_ascii.ko",
            "kernel/fs/nls/nls_cp437.ko",
            "kernel/fs/nls/nls_utf8.ko",
            "kernel/fs/fat/fat.ko",
            "kernel/fs/fat/vfat.ko",
            "kernel/drivers/cdrom/cdrom.ko",
            # efivarfs: firmware boot entries (tools/uefi_boot_entry.sh).
            "kernel/fs/efivarfs/efivarfs.ko",
        ]
        selected_modules = module_dependency_closure(
            dependencies, runtime_roots + legacy_ata_roots
        )
        strategic_storage_modules = {
            "kernel/drivers/ata/sata_nv.ko",
            "kernel/drivers/ata/pata_amd.ko",
            "kernel/drivers/ata/sata_sil24.ko",
            "kernel/drivers/ata/sata_via.ko",
            "kernel/drivers/ata/sata_sis.ko",
            "kernel/drivers/ata/ata_piix.ko",
            "kernel/drivers/ata/sata_promise.ko",
            "kernel/drivers/ata/sata_sil.ko",
            "kernel/drivers/virtio/virtio_pci.ko",
            "kernel/drivers/virtio/virtio_pci_modern_dev.ko",
            "kernel/drivers/virtio/virtio_pci_legacy_dev.ko",
        }
        missing_strategic = sorted(strategic_storage_modules - set(selected_modules))
        if missing_strategic:
            raise RuntimeError(
                f"Alpine LTS no longer covers required legacy storage modules: {missing_strategic}"
            )
        # KVM for the Windows 9x phase-1 VM: only in qemu9x.cpio.
        qemu9x_modules = [
            module
            for module in module_dependency_closure(dependencies, list(qemu9x_lock["kernel_modules"]))
            if module not in selected_modules
        ]
        module_patterns = tuple(
            f"modules/{kernel_release}/{module}" for module in selected_modules + qemu9x_modules
        )
        run_7z(
            seven_zip,
            "x",
            "-y",
            f"-o{modloop_out}",
            str(modloop),
            *module_patterns,
        )

        base_entries = parse_newc(gzip.decompress(base_initramfs.read_bytes()))
        entries = prune_lts_base(base_entries)
        systemd_boot: bytes | None = None
        for record, package in packages:
            if record.get("efi_only"):
                with tarfile.open(package, "r:gz") as archive:
                    member = archive.getmember("usr/lib/systemd/boot/efi/systemd-bootx64.efi")
                    source = archive.extractfile(member)
                    systemd_boot = source.read() if source else None
                continue
            only = record.get("files")
            for entry in archive_entries(package):
                # "files": take only these paths (and their folders) from the package.
                if only is not None and entry.name not in only:
                    continue
                normalized = merged_usr_entry(entry)
                if normalized is not None:
                    put(entries, normalized)

        for source_name, target_name in (
            ("tools/hardware_inventory.sh", "usr/lib/usos/hardware_inventory.sh"),
            ("tools/hardware_smart.sh", "usr/lib/usos/hardware_smart.sh"),
            ("tools/hardware_smart_table.awk", "usr/lib/usos/hardware_smart_table.awk"),
            ("tools/hardware_ui.sh", "usr/lib/usos/hardware_ui.sh"),
            ("tools/stick_release.sh", "usr/lib/usos/stick_release.sh"),
            ("tools/stick_write.sh", "usr/lib/usos/stick_write.sh"),
            ("tools/partuuid.sh", "usr/lib/usos/partuuid.sh"),
            ("tools/partuuid_diagnostics.sh", "usr/lib/usos/partuuid_diagnostics.sh"),
            ("tools/device_guard.sh", "usr/lib/usos/device_guard.sh"),
            ("tools/target_disk_identity.sh", "usr/lib/usos/target_disk_identity.sh"),
            ("tools/target_disk_wait.sh", "usr/lib/usos/target_disk_wait.sh"),
            ("tools/target_disk_guard.sh", "usr/lib/usos/target_disk_guard.sh"),
            ("tools/extract.sh", "usr/lib/usos/extract.sh"),
            ("tools/windows_setup_media.sh", "usr/lib/usos/windows_setup_media.sh"),
            ("tools/legacy_windows_request.sh", "usr/lib/usos/legacy_windows_request.sh"),
            ("tools/prepare_windows_bios_boot.sh", "usr/lib/usos/prepare_windows_bios_boot.sh"),
            ("tools/prepare_windows7_uefi.sh", "usr/lib/usos/prepare_windows7_uefi.sh"),
            ("tools/windows_bios_cpu_check.sh", "usr/lib/usos/windows_bios_cpu_check.sh"),
            ("tools/windows_wim_version.awk", "usr/lib/usos/windows_wim_version.awk"),
            ("tools/prepare_work.sh", "usr/lib/usos/prepare_work.sh"),
            ("tools/probe_xp_source.sh", "usr/lib/usos/probe_xp_source.sh"),
            ("tools/probe_nt5_source.sh", "usr/lib/usos/probe_nt5_source.sh"),
            ("tools/prepare_nt5_media_markers.sh", "usr/lib/usos/prepare_nt5_media_markers.sh"),
            ("tools/nt5_profile.sh", "usr/lib/usos/nt5_profile.sh"),
            ("tools/beta_clock.sh", "usr/lib/usos/beta_clock.sh"),
            ("tools/prepare_xp_local_source.sh", "usr/lib/usos/prepare_xp_local_source.sh"),
            ("tools/prepare_xp_target.sh", "usr/lib/usos/prepare_xp_target.sh"),
            ("tools/legacy_xp_staging.sh", "usr/lib/usos/legacy_xp_staging.sh"),
            ("tools/xp_csmwrap_esp.sh", "usr/lib/usos/xp_csmwrap_esp.sh"),
            ("tools/w9x_csmwrap_prepare.sh", "usr/lib/usos/w9x_csmwrap_prepare.sh"),
            ("tools/w9x_csmwrap_target.sh", "usr/lib/usos/w9x_csmwrap_target.sh"),
            ("tools/legacy_addons.sh", "usr/lib/usos/legacy_addons.sh"),
            ("tools/w9x_tzfix.sh", "usr/lib/usos/w9x_tzfix.sh"),
            ("tools/w9x_vesa95.sh", "usr/lib/usos/w9x_vesa95.sh"),
            ("tools/w9x_vesa950.sh", "usr/lib/usos/w9x_vesa950.sh"),
            ("tools/w9x_reg95.sh", "usr/lib/usos/w9x_reg95.sh"),
            ("tools/w9x_nvme.sh", "usr/lib/usos/w9x_nvme.sh"),
            ("tools/w9x_phase1_qemu.sh", "usr/lib/usos/w9x_phase1_qemu.sh"),
            ("tools/w9x_95_ui.sh", "usr/lib/usos/w9x_95_ui.sh"),
            ("tools/dos_csmwrap_target.sh", "usr/lib/usos/dos_csmwrap_target.sh"),
            ("tools/image_disk_target.sh", "usr/lib/usos/image_disk_target.sh"),
            ("tools/uefi_boot_entry.sh", "usr/lib/usos/uefi_boot_entry.sh"),
            ("tools/nt4_csmwrap_target.sh", "usr/lib/usos/nt4_csmwrap_target.sh"),
            ("tools/nt4_qemu_install.sh", "usr/lib/usos/nt4_qemu_install.sh"),
            ("tools/posready_csmwrap_target.sh", "usr/lib/usos/posready_csmwrap_target.sh"),
            ("tools/posready_qemu_install.sh", "usr/lib/usos/posready_qemu_install.sh"),
            ("tools/legacy_xp_resume.sh", "usr/lib/usos/legacy_xp_resume.sh"),
            ("tools/xp_unattended_policy.sh", "usr/lib/usos/xp_unattended_policy.sh"),
            ("tools/xp_user_settings.sh", "usr/lib/usos/xp_user_settings.sh"),
            ("tools/display_profile.sh", "usr/lib/usos/display_profile.sh"),
            ("tools/w9x_logon.sh", "usr/lib/usos/w9x_logon.sh"),
            ("tools/network_setup.sh", "usr/lib/usos/network_setup.sh"),
            ("tools/answer_plan.sh", "usr/lib/usos/answer_plan.sh"),
            ("tools/xp_windows_partition_plan.awk", "usr/lib/usos/xp_windows_partition_plan.awk"),
            ("tools/xp_selected_partition.sif", "usr/lib/usos/xp_selected_partition.sif"),
            ("tools/xp_selected_partition_uefi_csm.sif", "usr/lib/usos/xp_selected_partition_uefi_csm.sif"),
            ("tools/w2k_selected_partition_uefi_csm.sif", "usr/lib/usos/w2k_selected_partition_uefi_csm.sif"),
            ("tools/w2k3_selected_partition_uefi_csm.sif", "usr/lib/usos/w2k3_selected_partition_uefi_csm.sif"),
            ("tools/xp64_selected_partition_uefi_csm.sif", "usr/lib/usos/xp64_selected_partition_uefi_csm.sif"),
            ("tools/nt5_storage_stage.sh", "usr/lib/usos/nt5_storage_stage.sh"),
            ("tools/nt52_usb_stage.sh", "usr/lib/usos/nt52_usb_stage.sh"),
            ("tools/nt5_usosmpart_stage.sh", "usr/lib/usos/nt5_usosmpart_stage.sh"),
            ("tools/w2k_stage.sh", "usr/lib/usos/w2k_stage.sh"),
            ("tools/nt5_user_drivers.sh", "usr/lib/usos/nt5_user_drivers.sh"),
            ("tools/nt5_media_key.sh", "usr/lib/usos/nt5_media_key.sh"),
            ("tools/xp_driver_stage.sh", "usr/lib/usos/xp_driver_stage.sh"),
            ("tools/xp_verify_target.sh", "usr/lib/usos/xp_verify_target.sh"),
            ("tools/xp_drive_letters.awk", "usr/lib/usos/xp_drive_letters.awk"),
            ("tools/xp_source_io.sh", "usr/lib/usos/xp_source_io.sh"),
            ("tools/prepare_xp_ntfs_target.sh", "usr/lib/usos/prepare_xp_ntfs_target.sh"),
            ("tools/xp_disk_reset.sh", "usr/lib/usos/xp_disk_reset.sh"),
            ("tools/xp_disk_reset_ui.sh", "usr/lib/usos/xp_disk_reset_ui.sh"),
            ("tools/xp_confirmation_ui.sh", "usr/lib/usos/xp_confirmation_ui.sh"),
            ("tools/xp_menu_ui.sh", "usr/lib/usos/xp_menu_ui.sh"),
            ("tools/prepare_xp_source_aliases.sh", "usr/lib/usos/prepare_xp_source_aliases.sh"),
            ("tools/xp_dosnet_aliases.awk", "usr/lib/usos/xp_dosnet_aliases.awk"),
            ("tools/xp_detect_system.sh", "usr/lib/usos/xp_detect_system.sh"),
            ("tools/xp_disk_overview.sh", "usr/lib/usos/xp_disk_overview.sh"),
            ("tools/prepare_xp_windows_partition.sh", "usr/lib/usos/prepare_xp_windows_partition.sh"),
            ("tools/w9x_filesystem.sh", "usr/lib/usos/w9x_filesystem.sh"),
            ("tools/prepare_wimboot.sh", "usr/lib/usos/prepare_wimboot.sh"),
            ("tools/prepare_vhdboot.sh", "usr/lib/usos/prepare_vhdboot.sh"),
            ("tools/work_boot_relocate.sh", "usr/lib/usos/work_boot_relocate.sh"),
            ("tools/micro_linux_ui.sh", "usr/lib/usos/micro_linux_ui.sh"),
            ("tools/pipeline/run.sh", "usr/lib/usos/pipeline/run.sh"),
            ("tools/pipeline/steps/100_nt5_staging.sh", "usr/lib/usos/pipeline/steps/100_nt5_staging.sh"),
            ("tools/pipeline/steps/150_nt5_resume.sh", "usr/lib/usos/pipeline/steps/150_nt5_resume.sh"),
            ("tools/pipeline/steps/500_windows_pe_bios_request.sh", "usr/lib/usos/pipeline/steps/500_windows_pe_bios_request.sh"),
            ("tools/pipeline/steps/600_vista_disk_prepare.sh", "usr/lib/usos/pipeline/steps/600_vista_disk_prepare.sh"),
            ("tools/vista_disk_prepare.sh", "usr/lib/usos/vista_disk_prepare.sh"),
            ("tools/pipeline/steps/610_vista_csmwrap.sh", "usr/lib/usos/pipeline/steps/610_vista_csmwrap.sh"),
            ("tools/pipeline/steps/620_w9x_csmwrap.sh", "usr/lib/usos/pipeline/steps/620_w9x_csmwrap.sh"),
            ("tools/vista_csmwrap_prepare.sh", "usr/lib/usos/vista_csmwrap_prepare.sh"),
            ("tools/vista_csmwrap_target.sh", "usr/lib/usos/vista_csmwrap_target.sh"),
            ("tools/micro_linux_init.sh", "usos-init"),
        ):
            payload = (root / source_name).read_bytes().replace(b"\r\n", b"\n")
            put(entries, Entry(target_name, stat.S_IFREG | 0o755, payload))
        put(entries, Entry("usr/bin/usos-fb-ui", stat.S_IFREG | 0o755, framebuffer_ui.read_bytes()))
        from build_win95_setup_ui import build as build_win95_setup_ui
        win95_ui = build_win95_setup_ui(root, root / 'zig-out/win95-setup-ui')
        verify_static_linux_elf(win95_ui)
        put(entries, Entry('usr/lib/usos/win95-setup-ui', stat.S_IFREG | 0o755, win95_ui.read_bytes()))
        # Windows NT 4.0 (tools/nt4_csmwrap_target.sh): own GPL builds for NT 4.0.
        for source_name, target_name in (
            ("tools/vendor/ahcint/1.3.0.0-usos4/bin/NT4/i386/ahcint.sys", "usr/lib/usos/nt4/AHCINT.SYS"),
            ("tools/w2k/usosrst/bin/nt4/i386/usosrst.sys", "usr/lib/usos/nt4/USOSRST.SYS"),
            ("tools/nt4/usosusb/bin/i386/usosusb.sys", "usr/lib/usos/nt4/USOSUSB.SYS"),
            ("tools/nt4/usosvbe/bin/i386/usosvbe.sys", "usr/lib/usos/nt4/USOSVBE.SYS"),
            ("tools/nt4/usosoff/bin/i386/usosoff.exe", "usr/lib/usos/nt4/USOSOFF.EXE"),
            # usosnvme (own GPL NVMe miniport, tools/nt/usosnvme): staged only
            # for an NVMe target (docs/nvme-nt-2026-10-11.md).
            ("tools/nt/usosnvme/bin/NT4/i386/usosnvme.sys", "usr/lib/usos/nt4/USOSNVME.SYS"),
            ("tools/nt/usosnvme/bin/NT351/i386/usosnvme.sys", "usr/lib/usos/nt3/USOSNVME.SYS"),
            ("tools/nt/usosnvme/bin/NT31/i386/usosnvme.sys", "usr/lib/usos/nt3/USOSNVME31.SYS"),
            # Windows NT 3.51 (the same target script, \USOS\NT3): own GPL
            # builds for NT 3.51 (docs/nt351-2026-10-08.md).
            ("tools/vendor/ahcint/1.3.0.0-usos4/bin/NT351/i386/ahcint.sys", "usr/lib/usos/nt3/AHCINT.SYS"),
            ("tools/w2k/usosrst/bin/nt351/i386/usosrst.sys", "usr/lib/usos/nt3/USOSRST.SYS"),
            # NT 3.5 (docs/nt35-2026-10-09.md): usosrst without the per-CPU DPC calls.
            ("tools/w2k/usosrst/bin/nt35/i386/usosrst.sys", "usr/lib/usos/nt3/USOSRST35.SYS"),
            ("tools/nt4/usosusb/bin/i386/usosusb.sys", "usr/lib/usos/nt3/USOSUSB.SYS"),
            ("tools/nt3/usosachk/bin/i386/usosachk.exe", "usr/lib/usos/nt3/USOSACHK.EXE"),
            # VESA miniport, NT 3.x build (build-nt3.cmd; with the CD's own
            # framebuf.dll, docs/nt3-vesa-2026-10-14.md).
            ("tools/nt4/usosvbe/bin/nt3/i386/usosvbe.sys", "usr/lib/usos/nt3/USOSVBE.SYS"),
            # NT 3.1 (docs/nt31-2026-10-09.md): builds for the NT 3.1 kernel,
            # HAL and ScsiPort (build-nt31.cmd of each driver).
            ("tools/vendor/ahcint/1.3.0.0-usos4/bin/NT31/i386/ahcint.sys", "usr/lib/usos/nt3/AHCINT31.SYS"),
            ("tools/w2k/usosrst/bin/nt31/i386/usosrst.sys", "usr/lib/usos/nt3/USOSRST31.SYS"),
            ("tools/nt4/usosusb/bin/nt31/i386/usosusb.sys", "usr/lib/usos/nt3/USOSUSB31.SYS"),
            # usosmpart (own GPL USB multi-partition disk filter,
            # tools/nt/usosmpart): every NT 5 system (nt5_usosmpart_stage.sh).
            ("tools/nt/usosmpart/bin/i386/usosmpart.sys", "usr/lib/usos/nt5-usosmpart/i386/usosmpart.sys"),
            ("tools/nt/usosmpart/bin/amd64/usosmpart.sys", "usr/lib/usos/nt5-usosmpart/amd64/usosmpart.sys"),
        ):
            put(entries, Entry(target_name, stat.S_IFREG | 0o644, (root / source_name).read_bytes()))
        # Windows Embedded POSReady 2009 (docs/posready-2009-2026-10-10.md):
        # the answer template, the X470 registry values and the XP path's
        # community driver set (the files of tools/xp_driver_overlay.py
        # SELECTED); FIRST.CMD installs them at the first logon in the VM.
        # Windows Me, stock user USOS: the empty-password list (tools/w9x_logon.sh).
        put(entries, Entry("usr/lib/usos/w9x/USOSME.PWL", stat.S_IFREG | 0o644, (root / "src/platform/bios/win9x/usosme.pwl").read_bytes()))
        put(entries, Entry("usr/lib/usos/posready_unattended.xml", stat.S_IFREG | 0o644, (root / "tools/posready_unattended.xml").read_bytes()))
        put(entries, Entry("usr/lib/usos/posready/X470.REG", stat.S_IFREG | 0o644, (root / "tools/posready_x470.reg").read_bytes()))
        put(entries, Entry("usr/lib/usos/posready/FIRST.CMD", stat.S_IFREG | 0o644, (root / "tools/posready_first.cmd").read_bytes()))
        put(entries, Entry("usr/lib/usos/posready/LOGON.CMD", stat.S_IFREG | 0o644, (root / "tools/posready_logon.cmd").read_bytes()))
        put(entries, Entry("usr/lib/usos/posready/LOGON.REG", stat.S_IFREG | 0o644, (root / "tools/posready_logon.reg").read_bytes()))
        put(entries, Entry("usr/lib/usos/posready/LOGON.EXE", stat.S_IFREG | 0o644, (root / "tools/nt/posrlog/bin/i386/posrlog.exe").read_bytes()))
        posready_drivers = root / "media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86"
        for name in POSREADY_DRIVERS:
            put(entries, Entry("usr/lib/usos/posready/DRV/" + name.split("/")[1], stat.S_IFREG | 0o644, (posready_drivers / name).read_bytes()))
        # Own GPL USB multi-partition disk filter; FIRST.CMD registers it.
        put(entries, Entry("usr/lib/usos/posready/DRV/usosmpart.sys", stat.S_IFREG | 0o644, (root / "tools/nt/usosmpart/bin/i386/usosmpart.sys").read_bytes()))
        xp_vbr = root / "zig-out/xp-bios/xp-vbr-code.bin"
        xp_stage2 = root / "zig-out/xp-bios/xp-stage2.bin"
        xp_nt52_vbr = root / "zig-out/xp-bios/xp-nt52-vbr-tail.bin"
        xp_nt52_stage2 = root / "zig-out/xp-bios/xp-nt52-stage2.bin"
        xp_geometry_fix_mbr = root / "zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin"
        # NT 3.51: the geometry-fix MBR with the E820 filter (nt3_e820_mbr.S).
        nt3_e820_mbr = root / "zig-out/xp-geometry-fix-mbr/nt3-e820-mbr-440.bin"
        # Its resident hooks (sector 1 of the NT 3.x disk).
        nt3_e820_hook = root / "zig-out/xp-geometry-fix-mbr/nt3-e820-hook-512.bin"
        # ReactOS / own BIOS images behind CSMWrap: ELCR MBR (elcr_mbr.S).
        elcr_mbr = root / "zig-out/xp-geometry-fix-mbr/elcr-mbr-440.bin"
        # Windows 2000 with ACPI: the USOS_W2K_ACPI build of the geometry MBR.
        w2k_acpi_mbr = root / "zig-out/xp-geometry-fix-mbr/w2k-acpi-mbr-440.bin"
        for required in (xp_vbr, xp_stage2, xp_nt52_vbr, xp_nt52_stage2, xp_geometry_fix_mbr, nt3_e820_mbr, nt3_e820_hook, elcr_mbr, w2k_acpi_mbr):
            if not required.is_file():
                raise FileNotFoundError(f"XP BIOS bootstrap artifact missing: {required}")
        geometry_mbr = xp_geometry_fix_mbr.read_bytes()
        if len(geometry_mbr) != 440:
            raise RuntimeError(f"XP Strategy B MBR must be exactly 440 bytes, got {len(geometry_mbr)}")
        put(entries, Entry("usr/lib/usos/xp-vbr-code.bin", stat.S_IFREG | 0o644, xp_vbr.read_bytes()))
        put(entries, Entry("usr/lib/usos/xp-stage2.bin", stat.S_IFREG | 0o644, xp_stage2.read_bytes()))
        put(entries, Entry("usr/lib/usos/xp-nt52-vbr-tail.bin", stat.S_IFREG | 0o644, xp_nt52_vbr.read_bytes()))
        put(entries, Entry("usr/lib/usos/xp-nt52-stage2.bin", stat.S_IFREG | 0o644, xp_nt52_stage2.read_bytes()))
        put(entries, Entry("usr/lib/usos/xp-nt52-ntfs.bin", stat.S_IFREG | 0o644, (root / "zig-out/xp-bios/xp-nt52-ntfs.bin").read_bytes()))
        # Vista without CSM (vista_csmwrap_target.sh): NT60 NTFS boot code, from the host bootsect.exe at build time.
        nt60 = (root / "zig-out/xp-bios/vista-nt60-ntfs.bin").read_bytes()
        if len(nt60) != 8192:
            raise RuntimeError(f"Vista NT60 NTFS bootstrap must be 8192 bytes, got {len(nt60)}")
        put(entries, Entry("usr/lib/usos/vista-nt60-ntfs.bin", stat.S_IFREG | 0o644, nt60))
        from wimboot_kexec import (
            make_kexec_wimboot,
            make_ordered_kexec_wimboot,
            build_disk_order,
            build_kexec_bridge,
            build_kexec_cpu_reset,
        )
        wimboot = (root / "tools/vendor/wimboot/2.9.0/wimboot").read_bytes()
        if hashlib.sha256(wimboot).hexdigest() != "5f067ccdc4d084d5bf77b6c853bd0f8402dfc2b4cd1b103d358993ae97fae8e3":
            raise RuntimeError("Pinned wimboot checksum mismatch")
        put(entries, Entry("usr/lib/usos/wimboot", stat.S_IFREG | 0o644, wimboot))
        put(entries, Entry("usr/lib/usos/wimboot-kexec", stat.S_IFREG | 0o644, make_kexec_wimboot(wimboot)))
        ordered = make_ordered_kexec_wimboot(
            wimboot,
            build_disk_order(root, root / 'zig-out/wimboot-disk-order'),
            build_kexec_bridge(root, root / 'zig-out/wimboot-kexec-bridge'),
            build_kexec_cpu_reset(root, root / 'zig-out/wimboot-kexec-cpu-reset'),
        )
        put(entries, Entry("usr/lib/usos/wimboot-kexec-ordered", stat.S_IFREG | 0o644, ordered))
        put(entries, Entry("usr/lib/usos/windows_bios_handoff.sh", stat.S_IFREG | 0o755, (root / "tools/windows_bios_handoff.sh").read_bytes().replace(b"\r\n", b"\n")))
        put(entries, Entry("usr/lib/usos/windows_bios_startup.cmd", stat.S_IFREG | 0o644, (root / "tools/windows_bios_startup.cmd").read_bytes()))
        from build_windows_source_mount import build as build_source_reader
        from build_windows7_uefi import build as build_win7_uefi
        win7_out = root / "zig-out/windows7-uefi"
        build_win7_uefi(root, win7_out)
        from build_windows7_nvme import build_helpers as build_win7_nvme, read_assets as read_win7_nvme_assets
        nvme_out = root / "zig-out/windows7-nvme"
        build_win7_nvme(root, nvme_out)
        for filename in ("usos-win7-nvme.exe", "usos-win7-unattend.exe", "pe-file-version"):
            put(entries, Entry("usr/lib/usos/" + filename, stat.S_IFREG | (0o755 if filename == "pe-file-version" else 0o644), (nvme_out / filename).read_bytes()))
        put(entries, Entry("usr/lib/usos/prepare_windows7_nvme.sh", stat.S_IFREG | 0o755, (root / "tools/prepare_windows7_nvme.sh").read_bytes().replace(b"\r\n", b"\n")))
        for filename, data in read_win7_nvme_assets(root).items():
            put(entries, Entry("usr/lib/usos/windows7-nvme/" + filename, stat.S_IFREG | 0o644, data))
        for filename in ("win7-wrapper.efi", "usos-win7-finalize.exe"):
            put(entries, Entry("usr/lib/usos/" + filename, stat.S_IFREG | 0o644, (win7_out / filename).read_bytes()))
        put(entries, Entry("usr/lib/usos/windows7_uefi_startup.cmd", stat.S_IFREG | 0o644, (root / "tools/windows7_uefi_startup.cmd").read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")))
        win7_vendor = root / "tools/vendor/uefiseven/1.30"
        for filename, checksum in json.loads((win7_vendor / "manifest.json").read_text())["files"].items():
            data = (win7_vendor / filename).read_bytes()
            if hashlib.sha256(data).hexdigest() != checksum:
                raise RuntimeError("Pinned UefiSeven checksum mismatch: " + filename)
            name = "uefiseven-LICENSE.txt" if filename == "LICENSE.txt" else filename
            put(entries, Entry("usr/lib/usos/" + name, stat.S_IFREG | 0o644, data))
        # usos-reg.exe (own GPL tool, tools/windows_usos_reg.c): declarative
        # registry set files for NT 4.0 SP6 .. 11; the XP/2000/2003 and NT 4.0
        # target scripts run from usr/lib/usos and find it as
        # "$SCRIPT_DIR/usos-reg.exe" / "$LIB/usos-reg.exe".
        from build_windows_usos_reg import build as build_usos_reg
        usos_reg = build_usos_reg(root, root / "zig-out/windows-usos-reg")
        put(entries, Entry("usr/lib/usos/usos-reg.exe", stat.S_IFREG | 0o644, usos_reg.read_bytes()))
        from build_windows_usos_res import build as build_usos_res, build_collector as build_vbe_collector, build_nt3
        usos_res = build_usos_res(root, root / "zig-out/windows-usos-res")
        put(entries, Entry("usr/lib/usos/USOSRES.EXE", stat.S_IFREG | 0o644, usos_res.read_bytes()))
        nt3_post = build_nt3(root)
        put(entries, Entry("usr/lib/usos/nt3/USOSNT3.EXE", stat.S_IFREG | 0o644, nt3_post.read_bytes()))
        res9x_out = root / "zig-out/windows-usos-res/9x"
        res9x = build_usos_res(root, res9x_out, win9x=True)
        collector = build_vbe_collector(root, res9x_out)
        for name, source in (("USOSRES.EXE", res9x), ("USOSVBI.EXE", collector)):
            put(entries, Entry("usr/lib/usos/w9x-display/"+name, stat.S_IFREG | 0o644, source.read_bytes()))
        from build_windows_usos_lan import build as build_lan, stage_driver as stage_lan_driver
        lan_out = root / "zig-out/windows-usos-lan"
        lan_files = list(build_lan(root, lan_out).values()) + stage_lan_driver(root, lan_out / "driver")
        for file in lan_files:
            put(entries, Entry("usr/lib/usos/network/" + file.name, stat.S_IFREG | 0o644, file.read_bytes()))
        for relative, source in (
            ('win95-rtm/usosnet4.sys', 'tools/nt/usosnet/bin/i386/win95-rtm/usosnet4.sys'),
            ('usosnet95rtm.inf', 'tools/nt/usosnet/inf/usosnet95rtm.inf'),
        ):
            put(entries, Entry('usr/lib/usos/network/' + relative, stat.S_IFREG | 0o644,
                               (root / source).read_bytes()))
        from build_usosadd import build as build_addons_runner
        from build_legacy_stage import build as build_addons_planner
        addons_out = root / "zig-out/legacy-pack"
        addons_runner = build_addons_runner(addons_out)
        addons_planner = build_addons_planner(root, root / "zig-out/legacy-stage-linux")
        put(entries, Entry("usr/lib/usos/addons/USOSADD.EXE", stat.S_IFREG | 0o644, addons_runner.read_bytes()))
        put(entries, Entry("usr/lib/usos/addons/legacy-stage-plan", stat.S_IFREG | 0o755, addons_planner.read_bytes()))
        from addons.legacy_manifest import Manifest as AddonsManifest, validate as validate_addons
        if errors := validate_addons(AddonsManifest.load(root / "src/addons/legacy-pack.ini")):
            raise ValueError("Invalid legacy pack: " + "; ".join(errors))
        addon_text = (root / "src/addons/legacy-pack.ini").read_text(encoding="utf-8").replace("\r\n", "\n").replace("\n", "\r\n")
        for addon_lang, codepage in (("PL", "cp1250"), ("EN", "cp1252")):
            put(entries, Entry("usr/lib/usos/addons/LEGACY." + addon_lang, stat.S_IFREG | 0o644, addon_text.encode(codepage, errors="replace")))
        reader_out = root / "zig-out/windows-source-mount"
        build_source_reader(root, reader_out)
        vendor = root / "tools/vendor/imdisk/2.1.2"
        imdisk_manifest = json.loads((vendor / "manifest.json").read_text())
        for filename, checksum in imdisk_manifest["files"].items():
            data = (vendor / filename).read_bytes()
            if hashlib.sha256(data).hexdigest() != checksum:
                raise RuntimeError("Pinned ImDisk checksum mismatch: " + filename)
            dest = {"README.md": "usos-imdisk-README.txt", "LICENSE.md": "usos-imdisk-LICENSE.txt", "source.zip": "usos-imdisk-source.zip"}.get(filename, filename)
            put(entries, Entry("usr/lib/usos/" + dest, stat.S_IFREG | 0o644, data))
        for arch in ("x86", "x86_64"):
            for prefix in ("usos-source-", "usos-launch-"):
                filename = prefix + arch + ".exe"
                put(entries, Entry("usr/lib/usos/" + filename, stat.S_IFREG | 0o644, (reader_out / filename).read_bytes()))
        put(entries, Entry("usr/lib/usos/xp-geometry-fix-mbr-440.bin", stat.S_IFREG | 0o644, geometry_mbr))
        nt3_mbr = nt3_e820_mbr.read_bytes()
        if len(nt3_mbr) != 440:
            raise RuntimeError(f"NT 3.51 E820 MBR code must be 440 bytes: {nt3_e820_mbr}")
        put(entries, Entry("usr/lib/usos/nt3-e820-mbr-440.bin", stat.S_IFREG | 0o644, nt3_mbr))
        elcr = elcr_mbr.read_bytes()
        if len(elcr) != 440:
            raise RuntimeError(f"ELCR MBR code must be 440 bytes: {elcr_mbr}")
        put(entries, Entry("usr/lib/usos/elcr-mbr-440.bin", stat.S_IFREG | 0o644, elcr))
        w2k_mbr = w2k_acpi_mbr.read_bytes()
        if len(w2k_mbr) != 440:
            raise RuntimeError(f"Windows 2000 ACPI MBR code must be 440 bytes: {w2k_acpi_mbr}")
        put(entries, Entry("usr/lib/usos/w2k-acpi-mbr-440.bin", stat.S_IFREG | 0o644, w2k_mbr))
        nt3_hook = nt3_e820_hook.read_bytes()
        if len(nt3_hook) != 512 or nt3_hook[510:] != b"U3":
            raise RuntimeError(f"NT 3.x MBR hook sector must be 512 bytes ending in U3: {nt3_e820_hook}")
        put(entries, Entry("usr/lib/usos/nt3-e820-hook-512.bin", stat.S_IFREG | 0o644, nt3_hook))

        module_root = modloop_out / "modules" / kernel_release
        qemu9x_module_set = set(qemu9x_modules)
        qemu9x_module_files = [module_root / module for module in qemu9x_modules]
        module_files = [
            module
            for module in module_root.rglob("*.ko")
            if module.relative_to(module_root).as_posix() not in qemu9x_module_set
        ]
        extracted_relative = {
            module.relative_to(module_root).as_posix() for module in module_files
        }
        missing_modules = sorted(set(selected_modules) - extracted_relative)
        if missing_modules:
            raise RuntimeError(f"selected micro-Linux modules are missing: {missing_modules}")
        for module in module_files:
            relative = module.relative_to(modloop_out / "modules")
            put(
                entries,
                Entry(
                    f"usr/lib/modules/{relative.as_posix()}",
                    stat.S_IFREG | 0o644,
                    module.read_bytes(),
                ),
            )
        module_metadata_files = sorted(
            path for path in modules_dep.parent.glob("modules.*") if path.is_file()
        )
        if not any(path.name == "modules.alias" for path in module_metadata_files):
            raise RuntimeError("modules.alias missing from Alpine LTS modloop")
        for metadata in module_metadata_files:
            put(
                entries,
                Entry(
                    f"usr/lib/modules/{kernel_release}/{metadata.name}",
                    stat.S_IFREG | 0o644,
                    metadata.read_bytes(),
                ),
            )

        # In Alpine LTS simpledrm is built into the kernel. Keep the existing
        # loader contract: an empty module list means "framebuffer already
        # provided by the kernel", then the UI only waits for /dev/fb0.
        put(
            entries,
            Entry("usr/lib/usos/simpledrm.modules", stat.S_IFREG | 0o644, b""),
        )

        if systemd_boot is None:
            raise RuntimeError("systemd-boot EFI binary missing from pinned package")
        combined_cpio = newc(entries)
        combined_initramfs = pad_initrd(gzip.compress(combined_cpio, compresslevel=9, mtime=0))

        qemu9x = qemu9x_entries(qemu9x_lock, qemu9x_packages, entries)
        for module in qemu9x_module_files:
            if not module.is_file():
                raise RuntimeError(f"qemu9x module missing from the modloop: {module.name}")
            put(
                qemu9x,
                Entry(
                    f"usr/lib/modules/{kernel_release}/{module.relative_to(module_root).as_posix()}",
                    stat.S_IFREG | 0o644,
                    module.read_bytes(),
                ),
            )
        overlap = sorted(
            name for name, entry in qemu9x.items()
            if name in entries and stat.S_IFMT(entry.mode) != stat.S_IFDIR
        )
        if overlap:
            raise RuntimeError(f"qemu9x.cpio would replace initramfs-usos files: {overlap[:5]}")
        qemu9x_initrd = pad_initrd(gzip.compress(newc(qemu9x), compresslevel=9, mtime=0))

        output.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(kernel, output / "vmlinuz-virt")
        (output / "initramfs-usos").write_bytes(combined_initramfs)
        (output / "qemu9x.cpio").write_bytes(qemu9x_initrd)
        (output / "systemd-bootx64.efi").write_bytes(systemd_boot)
        selected_module_bytes = sum(module.stat().st_size for module in module_files)
        legacy_ata_bytes = sum(
            (module_root / module).stat().st_size
            for module in legacy_ata_roots
            if (module_root / module).is_file()
        )
        found_module_names = {module.name for module in module_files}
        manifest = {
            "kernel_family": "lts",
            "kernel_release": kernel_release,
            "kernel_sha256": sha256(output / "vmlinuz-virt"),
            "initramfs_sha256": sha256(output / "initramfs-usos"),
            "systemd_boot_sha256": sha256(output / "systemd-bootx64.efi"),
            "framebuffer_ui_sha256": sha256(framebuffer_ui),
            "framebuffer_ui_bytes": framebuffer_ui.stat().st_size,
            "package_count": len(packages),
            "kernel_modules": sorted(found_module_names),
            "selected_module_count": len(selected_modules),
            "selected_module_bytes": selected_module_bytes,
            "legacy_ata_root_count": len(legacy_ata_roots),
            "legacy_ata_root_bytes": legacy_ata_bytes,
            "legacy_ata_roots": legacy_ata_roots,
            "sata_nv_included": "kernel/drivers/ata/sata_nv.ko" in selected_modules,
            "base_initramfs_pruned": True,
            "base_firmware_removed": True,
            "simpledrm": "built-in",
            "qemu9x_sha256": sha256(output / "qemu9x.cpio"),
            "qemu9x_bytes": len(qemu9x_initrd),
            "qemu9x_unpacked_bytes": sum(len(entry.data) for entry in qemu9x.values()),
            "qemu9x_package_count": len(qemu9x_packages),
            "qemu9x_files": sorted(
                name for name, entry in qemu9x.items() if stat.S_IFMT(entry.mode) != stat.S_IFDIR
            ),
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"[PASS] micro-Linux kernel={output / 'vmlinuz-virt'}")
        print(f"[PASS] micro-Linux initramfs={output / 'initramfs-usos'}")
        print(f"[PASS] micro-Linux EFI loader={output / 'systemd-bootx64.efi'}")
        print(f"[PASS] micro-Linux Windows 9x VM initrd={output / 'qemu9x.cpio'} ({len(qemu9x_initrd)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
