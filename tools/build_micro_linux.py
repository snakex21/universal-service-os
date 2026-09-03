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


def run_7z(seven_zip: Path, *arguments: str) -> None:
    subprocess.run([str(seven_zip), *arguments], check=True, stdout=subprocess.DEVNULL)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--seven-zip", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    root = args.project_root.resolve()
    seven_zip = args.seven_zip.resolve()
    output = args.output_dir.resolve()
    lock = json.loads((root / "tools/micro_linux.lock.json").read_text(encoding="utf-8"))
    iso_record = lock["alpine_iso"]
    iso = obtain(root, iso_record, root / str(iso_record["file"]))
    packages_dir = root / "third_party/alpine/packages"
    packages: list[tuple[dict[str, object], Path]] = []
    for record in lock["packages"]:
        packages.append((record, obtain(root, record, packages_dir / str(record["file"]))))

    with tempfile.TemporaryDirectory(prefix="usos-micro-linux-") as temp_name:
        temp = Path(temp_name)
        run_7z(
            seven_zip,
            "x",
            "-y",
            f"-o{temp}",
            str(iso),
            "boot/vmlinuz-virt",
            "boot/initramfs-virt",
            "boot/modloop-virt",
        )
        modloop_out = temp / "modloop"
        required_module_patterns = (
            "modules/*/kernel/fs/udf/udf.ko",
            "modules/*/kernel/fs/ntfs3/ntfs3.ko",
            "modules/*/kernel/lib/crc/crc-itu-t.ko",
            "modules/*/kernel/drivers/hid/hid.ko",
            "modules/*/kernel/drivers/hid/hid-generic.ko",
            "modules/*/kernel/drivers/hid/usbhid/usbhid.ko",
            "modules/*/kernel/drivers/input/evdev.ko",
            "modules/*/kernel/drivers/usb/host/xhci-hcd.ko",
            "modules/*/kernel/drivers/usb/host/xhci-pci.ko",
            "modules/*/kernel/drivers/usb/host/ehci-hcd.ko",
            "modules/*/kernel/drivers/usb/host/ehci-pci.ko",
            "modules/*/kernel/drivers/usb/host/ohci-hcd.ko",
            "modules/*/kernel/drivers/usb/host/ohci-pci.ko",
        )
        run_7z(
            seven_zip,
            "x",
            "-y",
            f"-o{modloop_out}",
            str(temp / "boot/modloop-virt"),
            *required_module_patterns,
        )

        entries: dict[str, Entry] = {}
        systemd_boot: bytes | None = None
        for record, package in packages:
            if record.get("efi_only"):
                with tarfile.open(package, "r:gz") as archive:
                    member = archive.getmember("usr/lib/systemd/boot/efi/systemd-bootx64.efi")
                    source = archive.extractfile(member)
                    systemd_boot = source.read() if source else None
                continue
            for entry in archive_entries(package):
                normalized = merged_usr_entry(entry)
                if normalized is not None:
                    put(entries, normalized)

        for source_name, target_name in (
            ("tools/device_guard.sh", "usr/lib/usos/device_guard.sh"),
            ("tools/extract.sh", "usr/lib/usos/extract.sh"),
            ("tools/prepare_work.sh", "usr/lib/usos/prepare_work.sh"),
            ("tools/micro_linux_init.sh", "usos-init"),
        ):
            payload = (root / source_name).read_bytes().replace(b"\r\n", b"\n")
            put(entries, Entry(target_name, stat.S_IFREG | 0o755, payload))

        module_files = list(modloop_out.rglob("*.ko"))
        required_module_names = {
            "udf.ko",
            "ntfs3.ko",
            "crc-itu-t.ko",
            "hid.ko",
            "hid-generic.ko",
            "usbhid.ko",
            "evdev.ko",
            "xhci-hcd.ko",
            "xhci-pci.ko",
            "ehci-hcd.ko",
            "ehci-pci.ko",
            "ohci-hcd.ko",
            "ohci-pci.ko",
        }
        found_module_names = {module.name for module in module_files}
        missing_modules = sorted(required_module_names - found_module_names)
        if missing_modules:
            raise RuntimeError(f"required micro-Linux modules are missing: {missing_modules}")
        for module in module_files:
            relative = module.relative_to(modloop_out / "modules")
            put(entries, Entry(f"usr/lib/modules/{relative.as_posix()}", stat.S_IFREG | 0o644, module.read_bytes()))

        if systemd_boot is None:
            raise RuntimeError("systemd-boot EFI binary missing from pinned package")
        original_initramfs = (temp / "boot/initramfs-virt").read_bytes()
        # Some kernel/initramfs combinations stop after the first gzip member.
        # Use one gzip stream containing Alpine's cpio data followed by USOS's
        # cpio archive so /usos-init is always visible to the kernel.
        combined_cpio = gzip.decompress(original_initramfs) + newc(entries)
        combined_initramfs = gzip.compress(combined_cpio, compresslevel=9, mtime=0)

        output.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(temp / "boot/vmlinuz-virt", output / "vmlinuz-virt")
        (output / "initramfs-usos").write_bytes(combined_initramfs)
        (output / "systemd-bootx64.efi").write_bytes(systemd_boot)
        manifest = {
            "kernel_sha256": sha256(output / "vmlinuz-virt"),
            "initramfs_sha256": sha256(output / "initramfs-usos"),
            "systemd_boot_sha256": sha256(output / "systemd-bootx64.efi"),
            "package_count": len(packages),
            "kernel_modules": sorted(found_module_names),
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"[PASS] micro-Linux kernel={output / 'vmlinuz-virt'}")
        print(f"[PASS] micro-Linux initramfs={output / 'initramfs-usos'}")
        print(f"[PASS] micro-Linux EFI loader={output / 'systemd-bootx64.efi'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
