"""Read-only unit tests for XP's free-space partition planner."""
import os
import struct
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AWK = os.environ.get("USOS_TEST_AWK", "C:/Program Files/Git/usr/bin/awk.exe" if os.name == "nt" else "awk")


def entry(start, size, kind=7):
    return struct.pack("<B3sB3sII", 0, bytes(3), kind, bytes(3), start, size).hex()


def snapshot(**changes):
    values = dict(version="2", size_bytes=str(120034123776), xpsetup_slot="1", xpsetup_start_lba="2048", xpsetup_sectors="4194304", xpsetup_reuse="no")
    values.update({f"mbr_entry{i}": "00" * 16 for i in range(1, 5)})
    values.update(changes)
    return "\n".join(f"{key}={value}" for key, value in values.items()) + "\n"


class PlanTests(unittest.TestCase):
    def plan(self, ok=True, **changes):
        result = subprocess.run([AWK, "-f", str(ROOT / "tools/xp_windows_partition_plan.awk")], input=snapshot(**changes), capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr + result.stdout)
        return dict(line.split("=", 1) for line in result.stdout.splitlines()) if ok else {}

    def test_empty_mbr(self):
        plan = self.plan()
        self.assertEqual(plan["windows_slot"], "1")
        self.assertEqual(plan["windows_start_lba"], "2048")

    def test_preserve_old_chs_partition(self):
        plan = self.plan(mbr_entry1=entry(63, 2000000), xpsetup_slot="2", xpsetup_start_lba="2000896")
        self.assertEqual(plan["windows_slot"], "2")
        self.assertEqual(int(plan["windows_start_lba"]), 2000896)

    def test_reuse(self):
        self.assertEqual(self.plan(mbr_entry1=entry(2048, 4194304, 12), xpsetup_reuse="yes")["windows_slot"], "1")

    def test_limit_128_gib(self):
        plan = self.plan(size_bytes=str(1024**4))
        self.assertEqual(int(plan["windows_start_lba"]) + int(plan["windows_sectors"]), 268435456)

    def test_does_not_extend_across_existing_partition(self):
        self.plan(False, mbr_entry3=entry(4196352, 10000000), mbr_entry4=entry(50000000, 1000000))

    def test_bounds_extension_at_next_partition(self):
        plan = self.plan(mbr_entry3=entry(30000000, 10000000))
        self.assertLessEqual(int(plan["windows_start_lba"]) + int(plan["windows_sectors"]), 30000000)

    def test_overlapping(self):
        self.plan(False, mbr_entry2=entry(1000000, 8000000))

    def test_occupied_setup_slot(self):
        self.plan(False, mbr_entry1=entry(2048, 1000000))

    def test_missing_primary_slot(self):
        self.plan(False, mbr_entry2=entry(5000000, 1000000), mbr_entry3=entry(7000000, 1000000), mbr_entry4=entry(9000000, 1000000))

    def test_no_space(self):
        self.plan(False, size_bytes=str(8 * 1024**3))

    def test_wrong_reuse(self):
        self.plan(False, xpsetup_reuse="yes")

    def test_beyond_disk(self):
        self.plan(False, xpsetup_start_lba="268435456")

    def test_gpt(self):
        self.plan(False, mbr_entry2=entry(1, 200000000, 238))

    def test_invalid_hex_and_version(self):
        self.plan(False, mbr_entry2="z" * 32)
        self.plan(False, version="1")


if __name__ == "__main__":
    unittest.main()
