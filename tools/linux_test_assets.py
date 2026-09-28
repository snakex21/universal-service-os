#!/usr/bin/env python3
"""Download the official Linux ISOs used by the USOS Linux ISO boot tests.

Files go to %LOCALAPPDATA%\\USOS\\test-assets\\linux (outside the repo; no
distro ISO is ever committed). Every ISO is checked against the SHA-256 the
distribution publishes next to it; the result (URL, checksum URL, SHA-256,
size) is written to manifest.json in the same folder.

Usage: python tools/linux_test_assets.py [name ...]    (no name: all)
       python tools/linux_test_assets.py --list
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "USOS" / "test-assets" / "linux"

# name: (iso url, checksum url, file name inside the checksum file)
ASSETS: dict[str, tuple[str, str, str]] = {
    "ubuntu-desktop": (
        "https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso",
        "https://releases.ubuntu.com/24.04/SHA256SUMS",
        "ubuntu-24.04.5.1-desktop-amd64.iso",
    ),
    "ubuntu-server": (
        "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso",
        "https://releases.ubuntu.com/24.04/SHA256SUMS",
        "ubuntu-24.04.5-live-server-amd64.iso",
    ),
    "mint": (
        "https://mirrors.edge.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-xfce-64bit.iso",
        "https://mirrors.edge.kernel.org/linuxmint/stable/22.3/sha256sum.txt",
        "linuxmint-22.3-xfce-64bit.iso",
    ),
    "debian13-netinst": (
        "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso",
        "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS",
        "debian-13.7.0-amd64-netinst.iso",
    ),
    "debian12-netinst": (
        "https://cdimage.debian.org/cdimage/archive/latest-oldstable/amd64/iso-cd/debian-12.15.0-amd64-netinst.iso",
        "https://cdimage.debian.org/cdimage/archive/latest-oldstable/amd64/iso-cd/SHA256SUMS",
        "debian-12.15.0-amd64-netinst.iso",
    ),
    "debian13-live": (
        "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.7.0-amd64-standard.iso",
        "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/SHA256SUMS",
        "debian-live-13.7.0-amd64-standard.iso",
    ),
    "fedora": (
        "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-Live-44-1.7.x86_64.iso",
        "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-44-1.7-x86_64-CHECKSUM",
        "Fedora-Workstation-Live-44-1.7.x86_64.iso",
    ),
    "fedora-netinst": (
        "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-44-1.7.iso",
        "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/iso/Fedora-Everything-44-1.7-x86_64-CHECKSUM",
        "Fedora-Everything-netinst-x86_64-44-1.7.iso",
    ),
    "systemrescue": (
        "https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/13.02/systemrescue-13.02-amd64.iso/download",
        "https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/13.02/systemrescue-13.02-amd64.iso.sha256/download",
        "systemrescue-13.02-amd64.iso",
    ),
    "gparted": (
        "https://downloads.sourceforge.net/gparted/gparted-live-1.8.1-6-amd64.iso",
        "https://gparted.org/gparted-live/stable/CHECKSUMS.TXT",
        "gparted-live-1.8.1-6-amd64.iso",
    ),
    "clonezilla": (
        "https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable/3.3.3-37/clonezilla-live-3.3.3-37-amd64.iso/download",
        "https://clonezilla.org/downloads/stable/data/CHECKSUMS.TXT",
        "clonezilla-live-3.3.3-37-amd64.iso",
    ),
}

UA = {"User-Agent": "Wget/1.21 (usos-test-assets)"}


def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read().decode("utf-8", "replace")


def published_sha256(text: str, file_name: str) -> str:
    # GNU style "<hash>  name", BSD/Fedora style "SHA256 (name) = <hash>".
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"^SHA256 \((.+)\) = ([0-9a-fA-F]{64})$", line)
        if m and m.group(1) == file_name:
            return m.group(2).lower()
        m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(\S+)$", line)
        if m and os.path.basename(m.group(2)) == file_name:
            return m.group(1).lower()
    raise SystemExit(f"no SHA-256 for {file_name} in the published checksum file")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path) -> None:
    part = dest.with_suffix(dest.suffix + ".part")
    for attempt in range(1, 6):
        try:
            have = part.stat().st_size if part.exists() else 0
            headers = dict(UA)
            if have:
                headers["Range"] = f"bytes={have}-"
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=120) as resp:
                mode = "ab" if have and resp.status == 206 else "wb"
                with part.open(mode) as out:
                    while chunk := resp.read(4 << 20):
                        out.write(chunk)
            part.replace(dest)
            return
        except Exception as exc:  # network hiccup: resume
            print(f"  attempt {attempt} failed: {exc}", flush=True)
            time.sleep(5 * attempt)
    raise SystemExit(f"download failed: {url}")


def main(argv: list[str]) -> int:
    if "--list" in argv:
        for name, (url, _, _) in ASSETS.items():
            print(f"{name}\t{url}")
        return 0
    names = argv or list(ASSETS)
    ROOT.mkdir(parents=True, exist_ok=True)
    manifest_path = ROOT / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    for name in names:
        url, sums_url, file_name = ASSETS[name]
        dest = ROOT / file_name
        expected = published_sha256(fetch_text(sums_url), file_name)
        if dest.exists() and manifest.get(name, {}).get("sha256") == expected:
            print(f"{name}: present, verified earlier", flush=True)
            continue
        if not dest.exists():
            print(f"{name}: downloading {url}", flush=True)
            download(url, dest)
        actual = sha256_file(dest)
        if actual != expected:
            dest.rename(dest.with_suffix(".bad"))
            raise SystemExit(f"{name}: SHA-256 mismatch ({actual} != {expected})")
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        manifest[name] = {
            "file": file_name,
            "url": url,
            "checksum_url": sums_url,
            "sha256": actual,
            "size": dest.stat().st_size,
            "verified": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        manifest_path.write_text(json.dumps(manifest, indent=2))
        print(f"{name}: OK {actual}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
