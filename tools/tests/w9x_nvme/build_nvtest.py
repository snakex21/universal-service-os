"""Build NVTEST.EXE (tools/tests/w9x_nvme/nvtest.c) with the WDK 7.1 x86
compiler: Win32 console program, no C runtime, PE 4.00 so Windows 95/98/Me
load it. Test asset only (run_w9x_nvme_qemu.py).

    python tools/tests/w9x_nvme/build_nvtest.py OUT_DIR [--wdk WDKROOT]
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def wdk_root(given: str | None) -> Path:
    for cand in (given, os.environ.get("WDKROOT"), ROOT / "tools" / "WinDDK71",
                 Path.home() / "Desktop" / "universal-service-os" / "tools" / "WinDDK71"):
        if cand and (Path(cand) / "bin" / "x86" / "x86" / "cl.exe").is_file():
            return Path(cand)
    raise SystemExit("WDK 7.1 not found (set WDKROOT)")


def build(out: Path, wdk: Path) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    bin_ = wdk / "bin" / "x86" / "x86"
    env = dict(os.environ)
    env["PATH"] = str(bin_) + os.pathsep + str(wdk / "bin" / "x86") + os.pathsep + env.get("PATH", "")
    obj = out / "nvtest.obj"
    exe = out / "NVTEST.EXE"
    subprocess.run([str(bin_ / "cl.exe"), "/nologo", "/c", "/O1", "/GS-", "/W3", "/Zl",
                    "/I", str(wdk / "inc" / "api"), "/I", str(wdk / "inc" / "crt"),
                    "/D_X86_=1", "/Di386=1", "/DWIN32", "/D_WIN32_WINNT=0x0400", "/DWINVER=0x0400",
                    "/Fo" + str(obj), str(HERE / "nvtest.c")], check=True, env=env, cwd=out)
    subprocess.run([str(bin_ / "link.exe"), "/nologo", "/NODEFAULTLIB", "/ENTRY:NvMain", "/SUBSYSTEM:CONSOLE,4.00",
                    "/OSVERSION:4.0", "/FIXED:NO", "/OUT:" + str(exe), str(obj),
                    str(wdk / "lib" / "wxp" / "i386" / "kernel32.lib"), str(wdk / "lib" / "wxp" / "i386" / "user32.lib")],
                   check=True, env=env, cwd=out)
    subprocess.run([sys.executable, str(ROOT / "tools" / "nt4" / "pe_nt4_version.py"), "--version", "4.00", str(exe)],
                   check=True, stdout=subprocess.DEVNULL)
    return exe


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("out", type=Path)
    p.add_argument("--wdk")
    a = p.parse_args()
    print(build(a.out, wdk_root(a.wdk)))
