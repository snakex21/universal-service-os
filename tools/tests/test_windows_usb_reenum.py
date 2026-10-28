"""Host test: usos-usbreenum (tools/windows_usb_reenum.c) and the :usbfix
step of tools/windows_x86_csmwrap.cmd.

    python tools/tests/test_windows_usb_reenum.py [path-to-usos-usbreenum.exe]

- wiring: :mpart calls :usbfix after the offline registration; the build adds
  the helper to modern-support.cpio;
- :usbfix on a stand-in target (cmd.exe on this host): a new
  SetupComplete.cmd calls the helper; a second run changes nothing; an
  existing SetupComplete.cmd of the image keeps its lines, the call first;
- the helper: x86 PE with only kernel32 / advapi32 / setupapi / cfgmgr32
  imports; "report" on this host is read-only (stdout, no log file) and ends
  with "done", exit 0. The fix mode is not run on the host (it restarts USB
  storage devices); it was run in QEMU (docs/usb-multipartition-2026-10-14.md).
"""
from __future__ import annotations

import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = Path(os.environ.get("USOS_MAIN_CHECKOUT", r"C:\Users\ASRock\Desktop\usos-x470-98se"))
SCRIPT = (ROOT / "tools" / "windows_x86_csmwrap.cmd").read_text(encoding="utf-8")


def helper() -> Path | None:
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    built = ROOT / "zig-out" / "windows-modern" / "usos-usbreenum.exe"
    if built.exists():
        return built
    for base in (ROOT, MAIN):
        zig = base / "tools" / "zig" / "zig.exe"
        if not zig.exists():
            continue
        out = Path(tempfile.mkdtemp()) / "usos-usbreenum.exe"
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(base / "tools" / "cache" / "zig-global"), ZIG_LOCAL_CACHE_DIR=str(out.parent / "zc"))
        subprocess.run([str(zig), "cc", "-target", "x86-windows.vista-gnu", "-Os", "-nostdlib", "-fno-stack-protector", "-fno-builtin",
                        "-I" + str(base / "tools" / "zig" / "lib" / "libc" / "include" / "any-windows-any"), str(ROOT / "tools" / "windows_usb_reenum.c"),
                        "-Wl,--entry,entry", "-lkernel32", "-ladvapi32", "-lsetupapi", "-lcfgmgr32", "-o", str(out)], env=env, check=True)
        return out
    return None


def imports(pe: bytes) -> set[str]:
    """DLL names of a PE32 import directory."""
    off = struct.unpack_from("<I", pe, 0x3C)[0]
    assert pe[off:off + 4] == b"PE\0\0"
    machine = struct.unpack_from("<H", pe, off + 4)[0]
    assert machine == 0x14C, hex(machine)
    sections = struct.unpack_from("<H", pe, off + 6)[0]
    opt = off + 24
    assert struct.unpack_from("<H", pe, opt)[0] == 0x10B
    imp_rva = struct.unpack_from("<I", pe, opt + 104)[0]
    shdr = opt + struct.unpack_from("<H", pe, off + 20)[0]

    def file_off(rva: int) -> int:
        for i in range(sections):
            s = shdr + 40 * i
            vsize, va, rsize, raw = struct.unpack_from("<IIII", pe, s + 8)
            if va <= rva < va + max(vsize, rsize):
                return raw + rva - va
        raise ValueError(rva)

    names, p = set(), file_off(imp_rva)
    while True:
        name_rva = struct.unpack_from("<I", pe, p + 12)[0]
        if not name_rva:
            return names
        q = file_off(name_rva)
        names.add(pe[q:pe.index(b"\0", q)].decode().lower())
        p += 20


def usbfix_block() -> str:
    start = SCRIPT.index("\n:usbfix\n")
    end = SCRIPT.index("\nexit /b 0", SCRIPT.index("\n:usbfix_new\n")) + len("\nexit /b 0")
    return SCRIPT[start + 1:end]


def run_usbfix(tmp: Path) -> str:
    cmd = tmp / "t.cmd"
    body = '@echo off\nset "USOS_T=%s"\ncall :usbfix\nexit /b 0\n' % (tmp / "T") + usbfix_block() + "\n"
    cmd.write_bytes(body.replace("\r\n", "\n").replace("\n", "\r\n").encode("ascii"))
    # Windows' own find.exe first (a Git / MSYS find on PATH is another tool).
    system = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32")
    env = dict(os.environ, PATH=system + os.pathsep + os.environ.get("PATH", ""))
    r = subprocess.run(["cmd", "/d", "/c", str(cmd)], capture_output=True, text=True, env=env)
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
    return r.stdout


def main() -> int:
    # Wiring.
    mpart = SCRIPT[SCRIPT.index("\n:mpart\n"):SCRIPT.index("\n:mpart_reg\n")]
    assert mpart.index("reg unload HKLM\\USOS_SYS") < mpart.index("call :usbfix")
    build = (ROOT / "tools" / "build_windows_native_support.py").read_text(encoding="utf-8")
    assert "writer.add_file('usos-usbreenum.exe', helpers / 'usos-usbreenum.exe')" in build
    assert "windows_usb_reenum.c" in build and "x86-windows.vista-gnu" in build
    # :usbfix on a stand-in target.
    call = '"%SystemRoot%\\Setup\\Scripts\\usos-usbreenum.exe"'
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        (tmp / "T" / "Windows").mkdir(parents=True)
        out = run_usbfix(tmp)
        assert "helper missing; skipped" in out and not (tmp / "T" / "Windows" / "Setup").exists()
        (tmp / "usos-usbreenum.exe").write_bytes(b"MZ-stand-in")
        out = run_usbfix(tmp)
        sc = tmp / "T" / "Windows" / "Setup" / "Scripts" / "SetupComplete.cmd"
        assert "SetupComplete.cmd written" in out, out
        assert (sc.parent / "usos-usbreenum.exe").read_bytes() == b"MZ-stand-in"
        first = sc.read_text(encoding="ascii")
        lines = [l for l in first.splitlines() if l.strip()]
        assert lines[0] == "@echo off" and call in lines and lines[-1] == "exit /b 0", first
        assert lines.index(call) < len(lines) - 1
        run_usbfix(tmp)
        assert sc.read_text(encoding="ascii") == first
        # The image's own SetupComplete.cmd (ending with exit): kept, the call
        # goes first so it runs.
        own = "@echo off\r\nrem image\r\nstart-something.exe\r\nexit\r\n"
        sc.write_bytes(own.encode("ascii"))
        out = run_usbfix(tmp)
        assert "call added before" in out, out
        after = sc.read_bytes().decode("ascii")
        assert after == call + "\r\n" + own, after
        assert not (sc.parent / "SetupComplete.cmd.usos").exists()
        run_usbfix(tmp)
        assert sc.read_bytes().decode("ascii") == after
    # The helper.
    exe = helper()
    if exe is None:
        print("SKIP helper build/run: no zig toolchain (tools/zig) and no zig-out build")
    else:
        dlls = imports(exe.read_bytes())
        assert dlls <= {"kernel32.dll", "advapi32.dll", "setupapi.dll", "cfgmgr32.dll"}, dlls
        before = set(Path(os.environ.get("SystemDrive", "C:") + "\\").iterdir())
        r = subprocess.run([str(exe), "report"], capture_output=True, timeout=300)
        assert r.returncode == 0, r.returncode
        text = r.stdout.decode("mbcs", "replace")
        assert "mode=report" in text and text.rstrip().endswith("[USBREENUM] done"), text[-400:]
        assert "removed for a fresh install" not in text and "restart =" not in text
        assert set(Path(os.environ.get("SystemDrive", "C:") + "\\").iterdir()) == before, "report wrote to the system drive"
    print("PASS usos-usbreenum: :usbfix wiring + SetupComplete.cmd (new / existing / idempotent) + helper imports and read-only report")
    return 0


if __name__ == "__main__":
    sys.exit(main())
