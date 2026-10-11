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
    print("PASS windows_x86_csmwrap answer edit (arch + product key) + usb3 step")
    return 0


if __name__ == "__main__":
    sys.exit(main())
