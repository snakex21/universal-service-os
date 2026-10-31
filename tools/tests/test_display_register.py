"""Host test: USOSRES registration without a USOS answer (user decision
2026-10-22, docs/display-policy.md).

    python tools/tests/test_display_register.py [path-to-usos-x86-csmwrap.exe]

1. tools/windows_display_register.h through usos-x86-csmwrap.exe
   display-test: the staged-files check, the \\USOS\\NT6 DACL and the Run
   value on a scratch key under HKCU standing for the Default user hive root
   (no elevation; RegLoadKeyW of Users\\Default\\NTUSER.DAT around it is the
   same pattern as hideesp's SYSTEM hive).
2. Wiring: the x86 CSMWrap cmd calls "display" after Setup on every version,
   the Vista x64 installer calls the header on the CSMWrap path.
3. vista_csmwrap_target.sh 2b stages for no answer and a user's answer
   (auto), keeps a user's own <Display>, and a USOS answer's request.
4. prepare_xp_ntfs_target.sh: XP / Server 2003 without usos-xp.ini and with
   a user's own .sif (auto), a .sif with [Display] keeps its mode.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "zig-out" / "windows-modern" / "usos-x86-csmwrap.exe"
KEY = r"Software\USOS-display-register-test"
RUN = "HKCU\\" + KEY + r"\Software\Microsoft\Windows\CurrentVersion\Run"
SH = shutil.which("sh") or r"C:\Program Files\Git\usr\bin\sh.exe"
ENV = dict(os.environ, PATH=str(Path(SH).parent) + os.pathsep + os.environ.get("PATH", ""))
DATA = r"%SystemDrive%\USOS\NT6\USOSRES.EXE"


def shell(code: str) -> subprocess.CompletedProcess:
    return subprocess.run([SH, "-c", code], cwd=ROOT, env=ENV, capture_output=True)


def quote(p) -> str:
    return "'" + str(p).replace("\\", "/") + "'"


def reg(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    r = subprocess.run(["reg", *args], capture_output=True, text=True, errors="replace")
    if check:
        assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r


def run_value() -> tuple[str, str] | None:
    r = reg("query", RUN, "/v", "USOSDisplay", check=False)
    if r.returncode:
        return None
    for line in r.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0] == "USOSDisplay":
            return parts[1], parts[2]
    return None


def helper(tmp: Path) -> None:
    assert EXE.is_file(), EXE
    root = tmp / "vol"
    nt6 = root / "USOS" / "NT6"
    reg("delete", "HKCU\\" + KEY, "/f", check=False)
    try:
        nt6.mkdir(parents=True)
        arg = str(root) + "\\"
        # Not staged: nothing written, no DACL.
        code = subprocess.run([str(EXE), "display-test", arg, KEY]).returncode
        assert code == 2, code
        assert run_value() is None
        (nt6 / "USOSRES.EXE").write_bytes(b"own helper fixture")
        code = subprocess.run([str(EXE), "display-test", arg, KEY]).returncode
        assert code == 2, code  # DISPLAY.TXT missing: still not staged
        (nt6 / "DISPLAY.TXT").write_bytes(b"autoxauto\r\n")
        code = subprocess.run([str(EXE), "display-test", arg, KEY]).returncode
        assert code == 1300, code  # staged, DACL on 3 objects, written
        assert run_value() == ("REG_EXPAND_SZ", DATA), run_value()
        code = subprocess.run([str(EXE), "display-test", arg, KEY]).returncode
        assert code == 1301, code  # present
        # An older value (REG_SZ, expanded drive, as specialize writes it) is replaced.
        reg("add", RUN, "/v", "USOSDisplay", "/t", "REG_SZ", "/d", r"C:\USOS\NT6\USOSRES.EXE", "/f")
        code = subprocess.run([str(EXE), "display-test", arg, KEY]).returncode
        assert code == 1300, code
        assert run_value() == ("REG_EXPAND_SZ", DATA), run_value()
        acl = subprocess.run(["icacls", str(nt6)], capture_output=True, text=True, errors="replace").stdout
        assert "(OI)(CI)(M)" in acl and "(OI)(CI)(F)" in acl, acl
        # Authenticated Users may create the log / markers next to the helper.
        (nt6 / "USOSRES.LOG").write_bytes(b"x")
        print("[helper] not staged -> nothing; staged -> Run value REG_EXPAND_SZ, DACL, idempotent")
    finally:
        reg("delete", "HKCU\\" + KEY, "/f", check=False)


def wiring() -> None:
    cmd = (ROOT / "tools/windows_x86_csmwrap.cmd").read_text(encoding="utf-8")
    call = '"%~dp0usos-x86-csmwrap.exe" display\n'
    assert call in cmd
    assert cmd.index('call :mpart\n') < cmd.index(call) < cmd.index('"%~dp0usos-x86-csmwrap.exe" after')
    assert "if errorlevel 1 echo [USOS] display: not registered" in cmd  # never fatal
    c = (ROOT / "tools/windows_x86_csmwrap.c").read_text(encoding="utf-8")
    assert '#include "windows_display_register.h"' in c and 'L"display") == 0) ExitProcess(display_register())' in c
    vista = (ROOT / "tools/windows_vista_install.c").read_text(encoding="utf-8")
    assert '#include "windows_display_register.h"' in vista and "usos_display_register(target->root,&acl)" in vista
    assert vista.index("usos_display_register(") > vista.index("if(csmwrap){\n  if(!csm_esp_start)")
    print("[wiring] x86 cmd display step, Vista x64 installer (CSMWrap path)")


def nt6_block(tmp: Path, answer: bytes | None) -> tuple[Path, bytes]:
    lib = tmp / "lib-nt6"
    lib.mkdir(exist_ok=True)
    shutil.copy(ROOT / "tools/display_profile.sh", lib / "display_profile.sh")
    (lib / "USOSRES.EXE").write_bytes(b"own helper fixture")
    work = tmp / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir()
    path = ""
    if answer is not None:
        path = str(work / "answer.xml")
        Path(path).write_bytes(answer)
    text = (ROOT / "tools/vista_csmwrap_target.sh").read_text()
    block = text[text.index("# 2b. Display"):text.index("# 3. The PE10 donor")]
    pre = 'fail() { echo "$*" >&2; exit 1; }; log() { echo "LOG $*"; }; modprobe() { :; }; mount() { :; }; umount() { :; }; '
    env = "LIB=" + quote(lib) + " work=" + quote(work) + " ANSWER_XML=" + quote(path) + " windows_node=/dev/null USOS_DISPLAY_NATIVE_FILE=" + quote(tmp / "native.txt") + "; "
    r = shell(pre + env + block)
    assert r.returncode == 0, r.stderr
    return work / "windows/USOS/NT6", r.stdout


def nt6(tmp: Path) -> None:
    (tmp / "native.txt").write_bytes(b"1920x1080\r\n")
    for answer, note in ((None, b"no answer: auto"), (b"<unattend><settings pass=\"oobeSystem\"/></unattend>\n", b"user answer without a display request")):
        folder, out = nt6_block(tmp, answer)
        assert (folder / "DISPLAY.TXT").read_bytes() == b"autoxauto\r\nnative=1920x1080\r\n", out
        assert (folder / "USOSRES.EXE").read_bytes() == b"own helper fixture"
        assert note in out and b"DISPLAY request=autoxauto apply=first-sign-in" in out, out
    user_display = b"<unattend><Display><HorizontalResolution>1280</HorizontalResolution><VerticalResolution>1024</VerticalResolution></Display></unattend>\n"
    folder, out = nt6_block(tmp, user_display)
    assert not folder.exists() and b"its mode is kept" in out, out
    usos = b"<!-- USOS-DISPLAY=1280x1024x32 -->\n<unattend><Display><HorizontalResolution>1280</HorizontalResolution></Display><Path>cmd.exe /c if exist &quot;%SystemDrive%\\USOS\\NT6\\USOSRES.EXE&quot; reg.exe add</Path></unattend>\n"
    folder, _ = nt6_block(tmp, usos)
    assert (folder / "DISPLAY.TXT").read_bytes() == b"1280x1024x32\r\nnative=1920x1080\r\n"
    print("[nt6] no answer / user answer -> auto + native; user <Display> kept; USOS request unchanged")


def nt5(tmp: Path) -> None:
    sys.path.insert(0, str(ROOT / "tools/tests"))
    from test_nt4_flow import function_text
    lib = tmp / "lib-nt5"
    lib.mkdir()
    shutil.copy(ROOT / "tools/display_profile.sh", lib / "display_profile.sh")
    (lib / "USOSRES.EXE").write_bytes(b"own helper fixture")
    script = ROOT / "tools/prepare_xp_ntfs_target.sh"
    funcs = function_text(script, "usos_nt52_display_stage") + "; " + function_text(script, "usos_nt52_display_only_cmd") + "; "
    pre = 'fail() { echo "$*" >&2; exit 1; }; SCRIPT_DIR=' + quote(lib) + " USOS_DISPLAY_NATIVE_FILE=" + quote(tmp / "none") + "; "
    sif = tmp / "user.sif"
    for system, folder_name, custom in (("windows-xp", "XP", ""), ("windows-server-2003", "AMD64", ""), ("windows-xp", "XP", "user")):
        setup = tmp / ("vol-" + system + custom) / "USOS" / folder_name
        setup.mkdir(parents=True)
        cmd = setup / "usos-users.cmd"
        custom_env = ""
        if custom:
            sif.write_bytes(b"[Unattended]\r\nUnattendMode=FullUnattended\r\n[Display]\r\nBitsPerPel=32\r\n")
            custom_env = "XP_CUSTOM_SIF=" + quote(sif)
        env = "NT5_SYSTEM=" + system + " XP_USER_SETTINGS= " + custom_env + "; "
        run = 'line=$(usos_nt52_display_stage ' + quote(setup) + ') && [ -n "$line" ] && usos_nt52_display_only_cmd "$line" > ' + quote(cmd)
        r = shell(pre + env + funcs + run)
        assert r.returncode == 0, r.stderr
        assert (setup / "DISPLAY.TXT").read_bytes() == b"autoxauto\r\n"
        want = (b'@echo off\r\nrem USOS: display helper registration at setup end (docs/display-policy.md).\r\n'
                b'set USOS_LOG=%SystemRoot%\\usos-users.log\r\n'
                b'if exist "%SystemDrive%\\USOS\\' + folder_name.encode() + b'\\USOSRES.EXE" reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" /v USOSDisplay /t REG_SZ /d "%SystemDrive%\\USOS\\' + folder_name.encode() + b'\\USOSRES.EXE" /f >> "%USOS_LOG%" 2>&1\r\n'
                b'exit /b 0\r\n')
        assert cmd.read_bytes() == want, cmd.read_bytes()
    # A user's .sif that sets the resolution keeps it; Windows 2000 uses vesa.cmd.
    setup = tmp / "vol-fixed" / "USOS" / "XP"
    setup.mkdir(parents=True)
    sif.write_bytes(b"[Display]\r\n  xresolution = 1280\r\nYResolution=1024\r\n")
    for env in ("NT5_SYSTEM=windows-xp XP_USER_SETTINGS= XP_CUSTOM_SIF=" + quote(sif) + "; ", "NT5_SYSTEM=windows-2000 XP_USER_SETTINGS= XP_CUSTOM_SIF=; "):
        r = shell(pre + env + funcs + 'line=$(usos_nt52_display_stage ' + quote(setup) + '); [ -z "$line" ]')
        assert r.returncode == 0, r.stderr
        assert not (setup / "DISPLAY.TXT").exists()
    text = script.read_text()
    assert text.count('usos_nt52_display_only_cmd "$display_line" >') == 2
    print("[nt5] XP / 2003 without settings and with a user .sif -> auto; .sif [Display] kept; 2000 unchanged")


def main() -> int:
    out = ROOT / "artifacts" / "display-register"
    out.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="reg-", dir=out))
    try:
        wiring()
        nt6(tmp)
        nt5(tmp)
        helper(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("DISPLAY_REGISTER_TEST PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
