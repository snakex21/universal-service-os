#!/usr/bin/env python3
"""Fetch Fedora's Secure Boot OVMF (Microsoft UEFI CA 2011 + 2023 enrolled).

Test-only input for run_qemu_secure_boot.py; nothing here ships on the USB
stick. The RPM is pinned by SHA-256 and unpacked with the zstd CLI into
tools/cache/secure-boot (git-ignored):

    OVMF_CODE.secboot.fd   2 MiB, SMM build (q35,smm=on + secure pflash)
    OVMF_VARS.secboot.fd   Red Hat PK, Microsoft KEK/db (2011 and 2023), DBX
"""
from __future__ import annotations

import hashlib
import shutil
import struct
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CACHE = ROOT / "tools" / "cache" / "secure-boot"
URL = "https://kojipkgs.fedoraproject.org/packages/edk2/20260812/8.fc44/noarch/edk2-ovmf-20260812-8.fc44.noarch.rpm"
RPM_SHA256 = "4edaeca4129f0680d3cba6d9ff17806ba3ee5ca0f5fcede4849ad0b4dfcdd243"
WANTED = {
    "usr/share/edk2/ovmf/OVMF_CODE.secboot.fd": "a66de0c7f19d144b53caa7c7cd2bd2ffcd1a335e0c3c1f6b636a6257fed7ecab",
    "usr/share/edk2/ovmf/OVMF_VARS.secboot.fd": "63c76c8468979e7f50fcb4e9169451530667db6a9c0760c28c7a4e13bbf4988d",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rpm_payload(rpm: bytes) -> bytes:
    if rpm[:4] != b"\xed\xab\xee\xdb":
        raise SystemExit("not an RPM")
    pos = 96
    for align in (True, False):  # signature header (8-aligned), then main header
        if rpm[pos:pos + 3] != b"\x8e\xad\xe8":
            raise SystemExit("bad RPM header")
        count, size = struct.unpack(">II", rpm[pos + 8:pos + 16])
        pos += 16 + count * 16 + size
        if align:
            pos = (pos + 7) // 8 * 8
    payload = rpm[pos:]
    if payload[:4] != b"\x28\xb5\x2f\xfd":
        raise SystemExit("expected a zstd RPM payload")
    zstd = shutil.which("zstd") or shutil.which("zstd.exe")
    if not zstd:
        raise SystemExit("zstd CLI is required to unpack the Fedora RPM")
    return subprocess.run([zstd, "-d", "-c"], input=payload, capture_output=True, check=True).stdout


def cpio_files(data: bytes):
    i = 0
    while i < len(data):
        fields = [int(data[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        size, name_size = fields[6], fields[11]
        name = data[i + 110:i + 110 + name_size - 1].decode()
        start = (i + 110 + name_size + 3) // 4 * 4
        i = (start + size + 3) // 4 * 4
        if name == "TRAILER!!!":
            return
        yield name.lstrip("./"), data[start:start + size]


def main() -> int:
    CACHE.mkdir(parents=True, exist_ok=True)
    targets = {name: CACHE / Path(name).name for name in WANTED}
    if all(path.exists() and sha256(path.read_bytes()) == WANTED[name] for name, path in targets.items()):
        print(f"[PASS] cached Secure Boot OVMF in {CACHE}")
        return 0
    rpm_path = CACHE / Path(URL).name
    if not rpm_path.exists() or sha256(rpm_path.read_bytes()) != RPM_SHA256:
        print(f"[FETCH] {URL}")
        rpm_path.write_bytes(urllib.request.urlopen(URL, timeout=300).read())
    rpm = rpm_path.read_bytes()
    if sha256(rpm) != RPM_SHA256:
        raise SystemExit("edk2-ovmf RPM SHA-256 mismatch")
    found = 0
    for name, content in cpio_files(rpm_payload(rpm)):
        if name in WANTED:
            if sha256(content) != WANTED[name]:
                raise SystemExit(f"{name} SHA-256 mismatch")
            targets[name].write_bytes(content)
            found += 1
    if found != len(WANTED):
        raise SystemExit("OVMF files missing from the RPM")
    print(f"[PASS] Secure Boot OVMF unpacked into {CACHE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
