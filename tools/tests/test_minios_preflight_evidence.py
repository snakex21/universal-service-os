"""Reject misleading acceptance and premature cleanup without opening a disk."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]/"minios"
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
evidence=load("preflight_evidence_unit","preflight_evidence.py")
cleanup=load("preflight_cleanup_unit","cleanup_preflight.py")


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.expected={"files":{"sample":{"size":3,"sha256":"f"*64}},"directories":["empty"]}
        self.value={key:True for key in ("passed","readonly_chkdsk_pass","readonly_file_tree_pass",
            "disk_is_readonly","source_ntfs_boot_signature","temporary_dos_alias_removed","dismounted")}
        self.value.update(kind="windows-readonly-chkdsk",chkdsk_issued=True,access="ReadOnly",chkdsk_flags=[],repair_flags_used=False,chkdsk_exit=0,
            chkdsk_timeout=False,image_bytes=123,source_sha256_before="s",source_sha256_after="s",
            vhd_sha256_before="v",vhd_sha256_after="v",manifest_sha256_before="m",manifest_sha256_after="m",
            chkdsk_target_guard=dict(passed=True,boot=False,system=False,readonly=True,
                bus_type="File Backed Virtual",actual_disk_bytes=123,expected_image_bytes=123),
            file_tree=dict(passed=True,extra=[],different=[],missing=[],file_count=1,directory_count=1,directories=["empty"],writes_to_volume=False,
                files=[dict(path="sample",size=3,sha256="f"*64)]))

    def test_complete_readonly_receipt_and_exact_sha_are_accepted(self):
        evidence.validate_windows(self.value,self.expected,123,"s",0)
        with self.assertRaises(ValueError):evidence.validate_windows(self.value,self.expected,123,"s",3)

    def test_repair_flags_changed_hash_and_fake_pass_are_rejected(self):
        for key,value in (("chkdsk_flags",["/f"]),("source_sha256_after","changed"),
                          ("dismounted",False),("chkdsk_exit",3),("repair_flags_used",True),
                          ("chkdsk_issued",False),("kind","not-a-windows-verifier")):
            row=copy.deepcopy(self.value);row[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):evidence.validate_windows(row,self.expected,123,"s",0)

    def test_physical_and_wrong_size_guards_cannot_be_hidden_by_pass(self):
        for key,value in (("bus_type","SATA"),("actual_disk_bytes",124),("boot",True),("readonly",False)):
            row=copy.deepcopy(self.value);row["chkdsk_target_guard"][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):evidence.validate_windows(row,self.expected,123,"s",0)

    def test_missing_duplicate_and_changed_file_hash_are_rejected(self):
        for files in ([],self.value["file_tree"]["files"]*2,[dict(path="sample",size=3,sha256="0"*64)]):
            row=copy.deepcopy(self.value);row["file_tree"]["files"]=files
            with self.subTest(files=files),self.assertRaises(ValueError):evidence.validate_windows(row,self.expected,123,"s",0)
        row=copy.deepcopy(self.value);row["file_tree"]["directories"]=["wrong-empty"]
        with self.assertRaises(ValueError):evidence.validate_windows(row,self.expected,123,"s",0)

    def test_cleanup_refuses_draft_and_other_milestone_report(self):
        with tempfile.TemporaryDirectory(prefix="_unit-preflight-",dir=ROOT.parents[1]/"zig-out") as tmp:
            root=Path(tmp);(root/"validation").mkdir()
            path=root/"validation/final-report-pre-cleanup.md"
            for text in ("# MiniOS preflight przed 1b-2\nStatus: W TOKU", "# MiniOS 1b-1\nStatus: RAPORT KOŃCOWY"):
                path.write_text(text,encoding="utf-8")
                with self.subTest(text=text),self.assertRaises(ValueError):cleanup.report_ready(root)
            path.write_text("# MiniOS — preflight przed 1b-2\nStatus: RAPORT KOŃCOWY",encoding="utf-8")
            self.assertEqual(cleanup.report_ready(root)["path"],"validation/final-report-pre-cleanup.md")

    def test_published_index_refuses_absolute_device_or_profile_paths(self):
        for text in (r"C:\Users\private\data",r"\\?\Volume{a}",r"\\server\share"):
            with self.subTest(text=text),self.assertRaises(ValueError):evidence.base.assert_portable({"nested":[text]})

if __name__=="__main__":unittest.main()
