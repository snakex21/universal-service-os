"""MiniOS CSMWrap route (src/prep/csmwrap_target.zig) against the Alpine
step 610 on the same inputs.

The deterministic parts of tools/vista_csmwrap_target.sh (layout arithmetic,
the printf-built MBR, usos-csmwrap-target.ini) and tools/xp_csmwrap_esp.sh
(ESP start, free-slot search, ESP entry) are cut out of the scripts as they
are and run with sh; zig-out/bin/usosprep-csmwrap-plan computes the same
from the MiniOS code. Bytes and text must be identical.

Optional: USOS_TEST_WIN10X86_ISO_DIR (an extracted 32-bit Windows 10 ISO)
runs the NVMe staging-BCD edit (bcd_lowmem.apply, the code of
`usos-fb-ui --bcd-truncatememory`) on its boot\\bcd.

Needs: sh (Git Bash on Windows) with dd/od; the host tool built with
`zig build usosprep-csmwrap-plan`.
"""
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "tools" / "vista_csmwrap_target.sh"
ESP = ROOT / "tools" / "xp_csmwrap_esp.sh"
TOOL = ROOT / "zig-out" / "bin" / ("usosprep-csmwrap-plan.exe" if os.name == "nt" else "usosprep-csmwrap-plan")
MBR_CODE = ROOT / "zig-out" / "xp-geometry-fix-mbr" / "xp-geometry-fix-mbr-440.bin"


def block(text: str, first: str, last: str) -> str:
    """Lines from the one starting with `first` to the one starting with `last`."""
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if l.strip().startswith(first))
    end = next(i for i in range(start, len(lines)) if lines[i].strip().startswith(last))
    return "\n".join(lines[start:end + 1])


def alpine_script() -> str:
    t = TARGET.read_text(encoding="utf-8")
    e = ESP.read_text(encoding="utf-8")
    layout = block(t, "esp_start=$(( (total - ESP_TAIL", "windows_sectors=$((staging_start - windows_start))")
    le32 = block(t, "le32() {", "}")
    mbr = block(t, "mbr=$work/mbr.bin", '} > "$mbr"')
    sig = block(t, "signature_hex=$(od", "signature_hex=$(od")
    ini = block(t, "printf 'disk_signature=%s", "printf 'disk_signature=%s").replace('"$work/inject/$target_ini"', '"$work/ini"')
    esp_start = block(e, "start=$(( (total - TAIL", "end=$((start + ESP_SECTORS))")
    slot = block(e, "free=0", '[ "$free" -ne 0 ] || fail')
    entry = block(e, "{ printf '\\000\\376\\377\\377\\357", '{ printf')
    return "\n".join([
        "set -eu",
        "log() { :; }",
        'fail() { echo "FAIL $1" >&2; exit 1; }',
        'total=$1; signature=$2; target_bus=$3; LIB=$4; work=$5',
        "ESP_TAIL=133120", "STAGING_SECTORS=2097152", "ESP_SECTORS=131072", "TAIL=$ESP_TAIL",
        layout, le32, mbr, sig, ini,
        esp_start, slot,
        'entry=$work/entry.bin', entry,
        'dd if="$entry" of="$mbr" bs=1 seek=$((446 + 16 * (free - 1))) count=16 conv=notrunc 2>/dev/null',
        'echo "windows_start=$windows_start windows_sectors=$windows_sectors staging_start=$staging_start staging_sectors=$staging_sectors esp_start=$esp_start"',
    ]) + "\n"


@unittest.skipUnless(shutil.which("sh") and TOOL.exists(), "needs sh and zig-out/bin/usosprep-csmwrap-plan")
class MiniOsMatchesAlpine(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="minios-csm-"))
        self.lib = self.tmp / "lib"
        self.lib.mkdir()
        code = MBR_CODE.read_bytes() if MBR_CODE.exists() else bytes(random.Random(7).randrange(256) for _ in range(440))
        self.assertEqual(len(code), 440)
        (self.lib / "xp-geometry-fix-mbr-440.bin").write_bytes(code)
        self.script = self.tmp / "alpine.sh"
        self.script.write_text(alpine_script(), encoding="utf-8", newline="\n")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_case(self, total: int, signature: int, bus: str):
        a = self.tmp / f"a-{total}-{bus}"
        m = self.tmp / f"m-{total}-{bus}"
        a.mkdir()
        m.mkdir()
        sh = subprocess.run(["sh", str(self.script).replace("\\", "/"), str(total), str(signature), bus,
                             str(self.lib).replace("\\", "/"), str(a).replace("\\", "/")],
                            capture_output=True, text=True, check=False)
        self.assertEqual(sh.returncode, 0, sh.stderr)
        mo = subprocess.run([str(TOOL), str(total), f"{signature:08x}", bus, str(self.lib / "xp-geometry-fix-mbr-440.bin"),
                             str(m / "mbr.bin"), str(m / "ini")], capture_output=True, text=True, check=False)
        self.assertEqual(mo.returncode, 0, mo.stderr)
        self.assertEqual(sh.stdout.strip(), mo.stderr.strip(), "layout")
        self.assertEqual((a / "mbr.bin").read_bytes(), (m / "mbr.bin").read_bytes(), "final MBR bytes")
        self.assertEqual((a / "ini").read_bytes(), (m / "ini").read_bytes(), "usos-csmwrap-target.ini")

    def test_disks(self):
        rng = random.Random(610)
        totals = [33554432, 41943040, 268435456, 500118192, 1000215216, 1953525168, 4294967295]
        for total in totals:
            for bus in ("nvme", "other"):
                with self.subTest(total=total, bus=bus):
                    self.run_case(total, rng.randrange(1, 1 << 32), bus)

    def test_small_signature_keeps_leading_zeros(self):
        self.run_case(268435456, 0x0000abcd, "other")


@unittest.skipUnless(os.environ.get("USOS_TEST_WIN10X86_BCD") and TOOL.exists(), "set USOS_TEST_WIN10X86_BCD")
class StagingBcdEdit(unittest.TestCase):
    def test_truncatememory_on_the_iso_bcd(self):
        bcd = Path(os.environ["USOS_TEST_WIN10X86_BCD"])
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            code = tmp / "c.bin"
            code.write_bytes(bytes(440))
            out = tmp / "bcd.out"
            r = subprocess.run([str(TOOL), "268435456", "1", "nvme", str(code), str(tmp / "m"), str(tmp / "i"), str(bcd), str(out)],
                               capture_output=True, text=True, check=False)
            self.assertEqual(r.returncode, 0, r.stderr)
            data = out.read_bytes()
            self.assertEqual(data[:4], b"regf")
            self.assertGreater(len(data), bcd.stat().st_size - 1)


if __name__ == "__main__":
    unittest.main()
