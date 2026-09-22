"""Build the Legacy Core -> wimboot cache for a selected Windows ISO.

This is the validation gate for the native BIOS strategy: the resulting
boot.cpio is consumed directly by Legacy Core, with no micro-Linux/kexec step.
The tool deliberately binds native-cache.ini to the exact menu image name.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import stat


def find_ci(root: Path, relative: str) -> Path:
    current = root
    for component in Path(relative.replace("\\", "/")).parts:
        matches = [p for p in current.iterdir() if p.name.casefold() == component.casefold()]
        if len(matches) != 1:
            raise FileNotFoundError(f"expected one {relative!r} component {component!r} under {current}")
        current = matches[0]
    if not current.is_file():
        raise FileNotFoundError(f"not a file: {current}")
    return current


def parse_device_ini(path: Path) -> tuple[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("[") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip().lower()] = value.strip()
    nonce = values.get("nonce", "")
    work = values.get("work_partuuid", "") or values.get("workpartuuid", "")
    if not nonce or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for ch in nonce):
        raise ValueError("invalid nonce in usos-device.ini")
    if len(work) != 36 or any(ch not in "0123456789abcdefABCDEF-" for ch in work):
        raise ValueError("invalid WORK PARTUUID in usos-device.ini")
    return nonce, work.lower()


def substitute_startup(template: bytes, nonce: str, setup_from_source: bool) -> bytes:
    text = template.replace(b"\r\n", b"\n").decode("ascii")
    text = text.replace("@USOS_NONCE@", nonce)
    text = text.replace("@USOS_SETUP_FROM_SOURCE@", "1" if setup_from_source else "0")
    return text.replace("\n", "\r\n").encode("ascii")


class NewcWriter:
    def __init__(self, output: Path):
        self.handle = output.open("wb")
        self.inode = 1

    def close(self) -> None:
        self.handle.close()

    def _pad4(self) -> None:
        missing = (-self.handle.tell()) % 4
        if missing:
            self.handle.write(b"\0" * missing)

    def _header(self, name: str, mode: int, size: int) -> None:
        encoded = name.encode("utf-8") + b"\0"
        fields = (
            self.inode,
            mode,
            0,
            0,
            1,
            0,
            size,
            0,
            0,
            0,
            0,
            len(encoded),
            0,
        )
        self.handle.write(b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields))
        self.handle.write(encoded)
        self._pad4()
        self.inode += 1

    def add_bytes(self, name: str, data: bytes, mode: int = stat.S_IFREG | 0o644) -> None:
        self._header(name, mode, len(data))
        self.handle.write(data)
        self._pad4()

    def add_file(self, name: str, source: Path, mode: int = stat.S_IFREG | 0o644) -> None:
        size = source.stat().st_size
        self._header(name, mode, size)
        with source.open("rb") as src:
            shutil.copyfileobj(src, self.handle, length=1024 * 1024)
        self._pad4()

    def finish(self) -> None:
        trailer = b"TRAILER!!!\0"
        fields = (self.inode, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(trailer), 0)
        self.handle.write(b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields))
        self.handle.write(trailer)
        self._pad4()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(root: Path, source_root: Path, device_ini: Path, output: Path, system_id: str, image_name: str) -> None:
    nonce, work = parse_device_ini(device_ini)
    source_files = {
        "bootmgr": find_ci(source_root, "bootmgr"),
        "BCD": find_ci(source_root, "boot/BCD"),
        "boot.sdi": find_ci(source_root, "boot/boot.sdi"),
        "boot.wim": find_ci(source_root, "sources/boot.wim"),
    }
    # Fail before writing the cache if Setup cannot later find an installation image.
    try:
        find_ci(source_root, "sources/install.wim")
    except FileNotFoundError:
        find_ci(source_root, "sources/install.esd")
    if system_id == "windows-vista":
        find_ci(source_root, "sources/setup.exe")

    helpers = root / "zig-out/windows-source-mount"
    vendor = root / "tools/vendor/imdisk/2.1.2"
    required_helpers = [
        helpers / "usos-source-x86.exe",
        helpers / "usos-source-x86_64.exe",
        helpers / "usos-launch-x86.exe",
        helpers / "usos-launch-x86_64.exe",
    ]
    for arch in ("x86", "x86_64"):
        for ext in ("exe", "cpl", "sys"):
            required_helpers.append(vendor / f"imdisk-{arch}.{ext}")
    for path in required_helpers:
        if not path.is_file():
            raise FileNotFoundError(path)

    output.mkdir(parents=True, exist_ok=True)
    cpio_tmp = output / "boot.cpio.tmp"
    writer = NewcWriter(cpio_tmp)
    try:
        for name in ("bootmgr", "BCD", "boot.sdi", "boot.wim"):
            writer.add_file(name, source_files[name])
        startup = substitute_startup((root / "tools/windows_bios_startup.cmd").read_bytes(), nonce, system_id == "windows-vista")
        writer.add_bytes("usos-start.cmd", startup)
        writer.add_bytes("usos-source.ini", f"work_partuuid={work}\r\n".encode("ascii"))
        writer.add_bytes(
            "winpeshl.ini",
            b"[LaunchApp]\r\nAppPath=%SYSTEMROOT%\\System32\\usos-launch-%PROCESSOR_ARCHITECTURE%.exe\r\n",
        )
        writer.add_file("usos-source-x86.exe", helpers / "usos-source-x86.exe")
        writer.add_file("usos-source-x86_64.exe", helpers / "usos-source-x86_64.exe")
        writer.add_file("usos-launch-x86.exe", helpers / "usos-launch-x86.exe")
        writer.add_file("usos-launch-AMD64.exe", helpers / "usos-launch-x86_64.exe")
        for arch in ("x86", "x86_64"):
            for ext in ("exe", "cpl", "sys"):
                writer.add_file(f"imdisk-{arch}.{ext}", vendor / f"imdisk-{arch}.{ext}")
        writer.add_file("usos-imdisk-README.txt", vendor / "README.md")
        writer.add_file("usos-imdisk-LICENSE.txt", vendor / "LICENSE.md")
        writer.add_file("usos-imdisk-source.zip", vendor / "source.zip")
        writer.finish()
    finally:
        writer.close()
    if cpio_tmp.read_bytes()[:6] != b"070701":
        raise RuntimeError("invalid generated CPIO")
    cpio = output / "boot.cpio"
    cpio_tmp.replace(cpio)

    wimboot_source = root / "tools/vendor/wimboot/2.9.0/wimboot"
    wimboot = output / "wimboot"
    shutil.copyfile(wimboot_source, wimboot)
    manifest = output / "native-cache.ini"
    manifest.write_text(
        f"version=1\r\nsystem_id={system_id}\r\nimage_name={image_name}\r\n",
        encoding="ascii",
        newline="",
    )
    print(f"[PASS] native boot.cpio bytes={cpio.stat().st_size} sha256={sha256(cpio)}")
    print(f"[PASS] native wimboot bytes={wimboot.stat().st_size} sha256={sha256(wimboot)}")
    print(f"[PASS] native manifest image={image_name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--device-ini", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--system-id", required=True)
    parser.add_argument("--image-name", required=True)
    args = parser.parse_args()
    build(args.project_root.resolve(), args.source_root.resolve(), args.device_ini.resolve(), args.output_dir.resolve(), args.system_id, args.image_name)


if __name__ == "__main__":
    main()
