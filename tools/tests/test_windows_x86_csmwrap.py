"""Host test: the InstallTo edit of tools/windows_x86_csmwrap.c (answer-test mode).

    python tools/tests/test_windows_x86_csmwrap.py [path-to-usos-x86-csmwrap.exe]
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "zig-out" / "windows-modern" / "usos-x86-csmwrap.exe"
GOLDEN = ROOT / "src" / "flow" / "answer" / "testdata" / "golden" / "full.windows-10.x86.xml"
WANT = "<InstallTo><DiskID>1</DiskID><PartitionID>2</PartitionID></InstallTo>"


def run(text: str | None) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.xml"
        out = Path(tmp) / "out.xml"
        if text is not None:
            src.write_text(text, encoding="utf-8")
        code = subprocess.run([str(EXE), "answer-test", str(src) if text is not None else "-", str(out), "1", "2"],
                              capture_output=True).returncode
        assert code == 0, code
        return out.read_text(encoding="utf-8")


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
    script = (ROOT / "tools" / "windows_x86_csmwrap.cmd").read_text(encoding="utf-8")
    # USB 3 step: after a good Setup, before the staging entry is removed;
    # KMDF before the driver packages; NT 6.1 only.
    usb3 = script.index("call :usb3")
    assert script.index("setup-returned") < usb3 < script.index('usos-x86-csmwrap.exe" after')
    assert script.index("/Add-Package") < script.index("/Add-Driver")
    assert 'if not "%USOS_NT%"=="6.1" exit /b 0' in script and "/ForceUnsigned" in script
    print("PASS windows_x86_csmwrap answer edit + usb3 step")
    return 0


if __name__ == "__main__":
    sys.exit(main())
