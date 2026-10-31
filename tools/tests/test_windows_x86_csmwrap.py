"""Host test: the InstallTo edit of tools/windows_x86_csmwrap.c (answer-test mode).

    python tools/tests/test_windows_x86_csmwrap.py [path-to-usos-x86-csmwrap.exe]
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "zig-out" / "windows-modern" / "usos-x86-csmwrap.exe"
GOLDEN = ROOT / "src" / "flow" / "answer" / "testdata" / "golden" / "full.windows-10.x86.xml"
WANT = "<InstallTo><DiskID>1</DiskID><PartitionID>2</PartitionID></InstallTo>"


def run(text: str | None, modern: bool = False) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.xml"
        out = Path(tmp) / "out.xml"
        if text is not None:
            src.write_text(text, encoding="utf-8")
        code = subprocess.run([str(EXE), "answer-test", str(src) if text is not None else "-", str(out), "1", "2"] + (["modern"] if modern else []),
                              capture_output=True).returncode
        assert code == 0, code
        return out.read_text(encoding="utf-8")


NS = "{urn:schemas-microsoft-com:unattend}"
ZERO_KEY = "00000-00000-00000-00000-00000"


def setup_components(xml: str) -> list:
    """Well-formed check + the x86 Microsoft-Windows-Setup components."""
    root = ET.fromstring(xml.encode("utf-8"))
    return [c for c in root.iter(NS + "component")
            if c.get("name") == "Microsoft-Windows-Setup" and c.get("processorArchitecture") == "x86"]


def setup_key(component) -> tuple[str | None, str | None]:
    pk = component.find(NS + "UserData/" + NS + "ProductKey")
    if pk is None:
        return None, None
    key, ui = pk.find(NS + "Key"), pk.find(NS + "WillShowUI")
    return (key.text or "").strip() if key is not None else "", ui.text if ui is not None else None


def check_setup(xml: str, want_key: str | None, want_ui: str | None = None) -> None:
    """X470 2026-10-11 regression: what 32-bit Setup reads (its own x86
    component) has InstallTo = the USOS disk and a product key it accepts."""
    components = setup_components(xml)
    assert len(components) == 1, len(components)
    install_to = components[0].findall(NS + "ImageInstall/" + NS + "OSImage/" + NS + "InstallTo")
    assert len(install_to) == 1 and install_to[0].findtext(NS + "DiskID") == "1" and install_to[0].findtext(NS + "PartitionID") == "2"
    key, ui = setup_key(components[0])
    assert key == want_key, (key, want_key)
    if want_ui:
        assert ui == want_ui, ui
    assert key != "", "an empty <Key> must never reach Setup"


def key_regressions() -> None:
    goldens = sorted((ROOT / "src" / "flow" / "answer" / "testdata" / "golden").glob("*.xml"))
    assert len(goldens) > 20
    for path in goldens:
        text = path.read_text(encoding="utf-8")
        own = re.search(r"<UserData>.*?<ProductKey>\s*<Key>([^<]*)</Key>", text, re.S)
        own_key = own.group(1).strip() if own else None
        arch = re.search(r'processorArchitecture="([^"]+)"', text).group(1)
        for modern in (False, True):
            if arch == "arm64":
                continue  # not for this helper (x86 media only)
            edited = run(text, modern)
            # Every profile-rendered answer: amd64-only ones are retargeted.
            assert 'processorArchitecture="amd64"' not in edited, path.name
            want = own_key if own_key else (ZERO_KEY if modern else None)
            check_setup(edited, want, "Always" if want == ZERO_KEY else None)
    golden = GOLDEN.read_text(encoding="utf-8")
    real_key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"
    # Generic key (the Win10 Pro generic setup key): intact, either Setup.
    generic = golden.replace(real_key, "VK7JG-NPHTM-C97JM-9MPGT-3V66T")
    for modern in (False, True):
        check_setup(run(generic, modern), "VK7JG-NPHTM-C97JM-9MPGT-3V66T", "OnError")
    # Empty key in every spelling: 8.x / 10 -> Setup's own key page; Vista /
    # 7 / 2008 -> no ProductKey at all (their Setup rejects an empty key).
    for empty in ("<Key></Key>", "<Key/>", "<Key> \r\n </Key>", ""):
        text = golden.replace("<Key>" + real_key + "</Key>", empty)
        check_setup(run(text, True), ZERO_KEY, "Always")
        check_setup(run(text, False), None)
    # No ProductKey and no UserData at all.
    bare = re.sub(r"<UserData>.*?</UserData>", "", golden, flags=re.S)
    check_setup(run(bare, True), ZERO_KEY, "Always")
    check_setup(run(bare, False), None)
    # No answer and no Setup component: still a key page on 8.x / 10.
    check_setup(run(None, True), ZERO_KEY, "Always")
    check_setup(run(None, False), None)
    no_setup = '<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="oobeSystem"/></unattend>'
    check_setup(run(no_setup, True), ZERO_KEY, "Always")
    # The X470 case: a generator answer with amd64 components only (and a
    # Shell-Setup <ProductKey> string in specialize, which stays as it is).
    amd64 = golden.replace('processorArchitecture="x86"', 'processorArchitecture="amd64"')
    amd64 = amd64.replace("</unattend>", '<settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" '
                          'publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ProductKey>' + real_key +
                          "</ProductKey></component></settings></unattend>")
    edited = run(amd64, True)
    check_setup(edited, real_key, "OnError")
    assert "<ProductKey>" + real_key + "</ProductKey>" in edited and "amd64" not in edited
    # Both architectures present: nothing retargeted (x86 already there).
    both = golden.replace("</unattend>", '<settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" '
                          'publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"/></settings></unattend>')
    edited = run(both, True)
    check_setup(edited, real_key)
    assert edited.count('processorArchitecture="amd64"') == 1
    # UTF-16 amd64-only answer (schneegans-style generator output).
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.xml"; out = Path(tmp) / "out.xml"
        src.write_bytes(b"\xff\xfe" + amd64.replace('encoding="utf-8"', 'encoding="utf-16"').encode("utf-16-le"))
        assert subprocess.run([str(EXE), "answer-test", str(src), str(out), "1", "2", "modern"]).returncode == 0
        check_setup(out.read_text(encoding="utf-8"), real_key, "OnError")


def main() -> int:
    golden = GOLDEN.read_text(encoding="utf-8")
    edited = run(golden)
    assert edited.count(WANT) == 1
    assert edited.index("<ImageInstall><OSImage>" + WANT) < edited.index("<UserData>")
    assert edited.replace("<ImageInstall><OSImage>" + WANT + "<WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>", "") == golden
    with_image = golden.replace("<UserData>", "<ImageInstall><OSImage><InstallFrom/></OSImage></ImageInstall><UserData>", 1)
    edited = run(with_image)
    assert "<OSImage>" + WANT + "<InstallFrom/>" in edited
    assert run(golden.replace("<UserData>", "<ImageInstall><OSImage><InstallTo/></OSImage></ImageInstall><UserData>", 1)).count("<InstallTo") == 1
    minimal = run(None)
    assert WANT in minimal and 'processorArchitecture="x86"' in minimal
    no_setup = '<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="oobeSystem"/></unattend>'
    edited = run(no_setup)
    assert edited.index('<settings pass="oobeSystem"/>') < edited.index('<settings pass="windowsPE">') < edited.index("</unattend>") and WANT in edited
    # Safety: the answer's own disk settings never reach Setup (only the disk
    # chosen in the USOS menu may be written).
    hostile = golden.replace("<UserData>", '<DiskConfiguration><WillShowUI>OnError</WillShowUI><Disk wcm:action="add"><DiskID>0</DiskID>'
                             '<WillWipeDisk>true</WillWipeDisk></Disk></DiskConfiguration><ImageInstall><OSImage><InstallTo><DiskID>0</DiskID>'
                             '<PartitionID>1</PartitionID></InstallTo><InstallToAvailablePartition>false</InstallToAvailablePartition>'
                             '</OSImage></ImageInstall><UserData>', 1)
    edited = run(hostile)
    assert "DiskConfiguration" not in edited and "WillWipeDisk" not in edited and "InstallToAvailablePartition" not in edited
    assert edited.count("<InstallTo>") == 1 and WANT in edited
    # One Setup component per architecture: each gets the target.
    both = golden.replace('processorArchitecture="x86"', 'processorArchitecture="amd64"', 1)
    both = both.replace("</settings>", golden[golden.index('<component name="Microsoft-Windows-Setup"'):golden.index("</component>", golden.index('<component name="Microsoft-Windows-Setup"')) + 12] + "</settings>", 1)
    assert run(both).count(WANT) == both.count('"Microsoft-Windows-Setup"')
    # A UTF-16 answer is converted (no second disk question).
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.xml"; out = Path(tmp) / "out.xml"
        src.write_bytes(b"\xff\xfe" + golden.replace('encoding="utf-8"', 'encoding="utf-16"').encode("utf-16-le"))
        assert subprocess.run([str(EXE), "answer-test", str(src), str(out), "1", "2"]).returncode == 0
        converted = out.read_text(encoding="utf-8")
        assert WANT in converted and 'encoding="utf-8"' in converted and "utf-16" not in converted
        # The Vista CSMWrap installer's servicing-only answer (UTF-16, no
        # settings): windowsPE settings go after <servicing>, before </unattend>.
        servicing = ('<?xml version="1.0" encoding="utf-16"?>\r\n<unattend xmlns="urn:schemas-microsoft-com:unattend"><servicing>'
                     '<package action="install"><source location="X:\\k.cab"/></package></servicing></unattend>\r\n')
        src.write_bytes(b"\xff\xfe" + servicing.encode("utf-16-le"))
        assert subprocess.run([str(EXE), "answer-test", str(src), str(out), "1", "2"]).returncode == 0
        converted = out.read_text(encoding="utf-8")
        assert converted.index("</servicing>") < converted.index('<settings pass="windowsPE">') < converted.index("</unattend>")
        assert WANT in converted and 'encoding="utf-8"' in converted
    key_regressions()
    script = (ROOT / "tools" / "windows_x86_csmwrap.cmd").read_text(encoding="utf-8")
    # The Setup version decides the product key handling.
    assert 'before "%USOS_ANSWER%" "%~dp0usos-csmwrap-unattend.xml" "%USOS_SETUP%"' in script
    # USB 3 step: after a good Setup, before the staging entry is removed;
    # KMDF before the driver packages; NT 6.1 only.
    usb3 = script.index("call :usb3")
    assert script.index("setup-returned") < usb3 < script.index('usos-x86-csmwrap.exe" after')
    assert script.index("/Add-Package") < script.index("/Add-Driver")
    assert 'if not "%USOS_NT%"=="6.1" exit /b 0' in script and "/ForceUnsigned" in script
    # A user package dropped as an unpacked folder (docs/network-win7.md, an
    # Intel I211 e1r62x86 INF) is installed without editing any file list:
    # DISM /Add-Driver runs recursively over the whole Win7 driver trees, and
    # the driver step no longer depends on the optional KMDF update.
    assert script.index('if not "%USOS_NT%"=="6.1" exit /b 0') < script.index("/Add-Driver")
    assert 'for %%D in ("%USOS_DATA%") do set "USOS_USER_DRV=%%~dD\\Drivers\\Windows 7"' in script
    section = script[script.index("\n:usb3\n"):script.index("\n:usb3_done\n")]
    add_driver = [line for line in section.splitlines() if line.startswith("dism.exe") and "/Add-Driver" in line]
    assert len(add_driver) == 3, add_driver
    assert '/Driver:"%USOS_DRV%\\Net" /Recurse /ForceUnsigned' in add_driver[0]
    assert '/Driver:"%USOS_DRV%" /Recurse /ForceUnsigned' in add_driver[1]
    assert '/Driver:"%USOS_USER_DRV%" /Recurse /ForceUnsigned' in add_driver[2]
    # Without KMDF 1.11 only the bundled Net subtree is added: the bundled USB 3
    # packages (whose xHCI service could not start) never switch off usosusb.
    assert 'if "%USOS_DISM%"=="0" set "USOS_KMDF_OK=1"' in section
    no_kmdf = "\n".join(line for line in section[section.index(":usb3_drivers"):section.index(":usb3_bundled")].splitlines()
                        if not line.startswith("rem "))
    assert "if defined USOS_KMDF_OK goto usb3_bundled" in no_kmdf
    assert "USOS_USB3_INSTALLED" not in no_kmdf and '/Driver:"%USOS_DRV%"' not in no_kmdf
    # Missing / broken KMDF: a note, not a jump past the driver packages.
    before_drivers = section.split(":usb3_drivers")[0]
    assert "goto usb3_done" not in before_drivers
    assert before_drivers.count("goto usb3_drivers") == 2 and "still added" in before_drivers
    # The bundled tree decides USOS_USB3_INSTALLED (the usosusb fallback); the
    # user tree only logs its own exit code.
    bundled, user = section.split(":usb3_user_drivers")
    assert "USOS_USB3_INSTALLED=1" in bundled and "USOS_USB3_INSTALLED" not in user
    # The Win10 x86 WinPE has neither fc.exe nor findstr.exe (find only): any
    # call of them fails, so a check built on them silently skips its step
    # (usosmpart readback 2026-10-14). The readback uses the helper instead.
    code = [line for line in script.splitlines() if not line.lstrip().lower().startswith(("rem ", "::"))]
    for tool in ("fc", "fc.exe", "findstr", "findstr.exe", "comp", "comp.exe", "certutil"):
        bad = [line for line in code if re.search(r'(?<![\w.%~-])' + re.escape(tool) + r'(?![\w.-])', line, re.I)]
        assert not bad, (tool, bad)
    mpart = script[script.index("\n:mpart\n"):script.index("\n:mpart_reg\n")]
    assert r'usos-x86-csmwrap.exe" samefile "%~dp0usosmpart-x86.sys" "%USOS_T%\Windows\System32\drivers\usosmpart.sys"' in mpart
    assert mpart.index(" samefile ") < mpart.index("readback mismatch") < mpart.index("reg load")
    # samefile on the host: equal, different (same size), shorter, missing.
    with tempfile.TemporaryDirectory() as tmp:
        a, b, c, d = (Path(tmp) / n for n in ("a.sys", "b.sys", "c.sys", "d.sys"))
        blob = bytes(range(256)) * 700  # spans more than one 64 KiB read
        a.write_bytes(blob); b.write_bytes(blob); c.write_bytes(blob[:-1] + b"\x00"); d.write_bytes(blob[:-1])
        same = lambda x, y: subprocess.run([str(EXE), "samefile", str(x), str(y)], capture_output=True).returncode
        assert same(a, b) == 0 and same(a, c) == 1 and same(a, d) == 1 and same(d, a) == 1
        assert same(a, Path(tmp) / "missing.sys") == 1 and same(Path(tmp) / "missing.sys", a) == 1
        e = Path(tmp) / "e.sys"; e.write_bytes(b""); f = Path(tmp) / "f.sys"; f.write_bytes(b"")
        assert same(e, f) == 0 and same(e, a) == 1
    poweroff_regressions(script)
    print("PASS windows_x86_csmwrap answer edit (arch + product key) + usb3 step + mpart readback (no fc/findstr) + 8/10 power-off")
    return 0


def poweroff_regressions(script: str) -> None:
    """X470 2026-10-31 (B261031-195000, docs/nvme-nt6-2026-10-12.md section 21):
    Windows 8 / 8.1 / 10 x86 end the WinPE with a power-off (cold boot next),
    Vista / 7 / 2008 x86 and an unreadable version keep the warm restart."""
    final = script[script.index("echo [USOS] phase=finalize-target-boot"):script.index("\n:disk_report\n")]
    # Version from the helper's target record, read after "stick".
    assert final.index('csmwrap.exe" stick') < final.index('csmwrap.exe" target "%TEMP%\\usos-target.txt" >nul')
    assert 'if not errorlevel 1 for /f "usebackq tokens=2" %%A in ("%TEMP%\\usos-target.txt") do set "USOS_FINAL_NT=%%A"' in final
    on = [line for line in final.splitlines() if line.endswith('set "USOS_POWEROFF=1"')]
    assert on == ['if "%USOS_FINAL_NT%"=="6.2" set "USOS_POWEROFF=1"', 'if "%USOS_FINAL_NT%"=="6.3" set "USOS_POWEROFF=1"',
                  'if "%USOS_FINAL_NT%"=="10.0" set "USOS_POWEROFF=1"'], on
    assert final.index('set "USOS_POWEROFF="') < final.index('set "USOS_POWEROFF=1"')
    assert 'if defined USOS_POWEROFF ("%~dp0usos-x86-csmwrap.exe" after poweroff) else ("%~dp0usos-x86-csmwrap.exe" after)' in final
    code = [line for line in final.splitlines() if line and not line.startswith("rem ")]
    assert code.count("wpeutil shutdown") == 1 and code.count("wpeutil reboot") == 1, code
    # A failed "after" stops before either; the power-off path jumps past the reboot.
    fail = code.index('if not "%USOS_FINALIZE_RESULT%"=="0" exit /b %USOS_FINALIZE_RESULT%')
    assert fail < code.index("if defined USOS_POWEROFF goto poweroff_after_success") < code.index("wpeutil reboot")
    assert code.index("wpeutil reboot") < code.index(":poweroff_after_success") < code.index("wpeutil shutdown")
    # Phase lines before the last log copy (the stick log shows them).
    log = code.index('"%~dp0usos-log-x86.exe"')
    assert code.index('if "%USOS_FINALIZE_RESULT%"=="0" if defined USOS_POWEROFF echo [USOS] phase=poweroff-after-success') < log
    assert code.index('if "%USOS_FINALIZE_RESULT%"=="0" if not defined USOS_POWEROFF echo [USOS] phase=reboot-after-success') < log < fail
    # Only the end of the flow changed: the NVMe lowmem WinPE restart stays a reboot.
    assert script.count("wpeutil shutdown") == 1 and script.count("wpeutil reboot") == 2
    # The helper: "after poweroff" shows the Polish notice for 15 s; plain "after" is unchanged.
    src = (ROOT / "tools" / "windows_x86_csmwrap.c").read_text(encoding="ascii")
    notice = src[src.index("static DWORD WINAPI notice_poweroff"):src.index("static DWORD WINAPI notice(")]
    text = notice.encode("ascii").decode("unicode_escape")
    for want in ("Komputer zostanie teraz wyłączony", "przyciskiem zasilania", "kontynuować instalację",
                 "Wyjmij pendrive USOS", "wyłączy się sam za 15 sekund", "USOS - Windows bez CSM"):
        assert want in text, want
    assert "#define USOS_POWEROFF_NOTICE_MS 15000" in src
    after = src[src.index('lstrcmpiW(args[1], L"after") == 0'):]
    assert 'BOOL poweroff = arg_count == 3 && lstrcmpiW(args[2], L"poweroff") == 0;' in after
    assert "CreateThread(0, 0, poweroff ? notice_poweroff : notice, 0, 0, 0)" in after
    assert "WaitForSingleObject(t, poweroff ? USOS_POWEROFF_NOTICE_MS : 120000)" in after
    assert after.index('write_mbr(s, "staging partition entry removed")') < after.index("CreateThread")


if __name__ == "__main__":
    sys.exit(main())
