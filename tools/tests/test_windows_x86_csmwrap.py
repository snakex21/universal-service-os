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
    assert edited.index('<settings pass="windowsPE">') < edited.index('<settings pass="oobeSystem"/>') and WANT in edited
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
