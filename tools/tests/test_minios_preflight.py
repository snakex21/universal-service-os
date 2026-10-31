"""Pre-WIM accounting/configuration guards; no VM or target writes."""
import importlib.util
import contextlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

path = Path(__file__).resolve().parents[1] / "minios/preflight_case.py"
spec = importlib.util.spec_from_file_location("minios_preflight_unit", path)
case = importlib.util.module_from_spec(spec)
spec.loader.exec_module(case)


class Accounting(unittest.TestCase):
    def test_bios_counts_entire_reserved_arena_instead_of_live_requests(self):
        log = "USOSPREP FINAL current=0 peak=400000\nHEAP physical_current=0 physical_peak=410000 extent_peak=420000 reserved=900000\n"
        result = case.own_memory(log, {"own_stack_already_in_allocator_peak":False,
            "loaded_image_bytes":150000,"own_stack_reserved_bytes":250000,
            "thunk_and_bootstrap_low_memory_budget_bytes":131072})
        self.assertEqual(result["conservative_own_bytes"],1431072)
        self.assertEqual(result["physical_heap"]["reserved"],900000)

    def test_uefi_does_not_double_count_the_owned_stack(self):
        result = case.own_memory("alloc_peak=1500000\n", {"own_stack_already_in_allocator_peak":True,
            "loaded_image_bytes":160000,"untracked_entry_stack_budget_bytes":4096})
        self.assertEqual(result["conservative_own_bytes"],1664096)

    def test_missing_leaked_inconsistent_and_overbudget_metrics_are_rejected(self):
        bios={"own_stack_already_in_allocator_peak":False,"loaded_image_bytes":150000,
              "own_stack_reserved_bytes":250000,"thunk_and_bootstrap_low_memory_budget_bytes":131072}
        for log in ("", "peak=9\n", "peak=10\nHEAP physical_current=1 physical_peak=11 extent_peak=11 reserved=12\n",
                    "peak=20\nHEAP physical_current=0 physical_peak=19 extent_peak=19 reserved=20\n",
                    "peak=1\nHEAP physical_current=0 physical_peak=1 extent_peak=1 reserved=16777216\n"):
            with self.subTest(log=log), self.assertRaises(ValueError): case.own_memory(log,bios)

    def test_unknown_profile_and_unsafe_case_name_fail_before_disk_preparation(self):
        args=dict(workspace=Path("unused"),arch="bios",profile="scale-firmware",memory=2,
                  cpu="486",timeout=180,qemu=Path("unused"),source=Path("unused"),
                  artifacts=Path("unused"),bios_elf=Path("unused"))
        with self.assertRaises(ValueError): case.run(name="../escape",**args)
        args["profile"]="wim"
        with self.assertRaises(ValueError): case.run(name="guard",**args)
        args["profile"]="scale-firmware";args["arch"]="x86_64"
        with self.assertRaises(ValueError): case.run(name="guard",expect_entropy_refusal=True,**args)

    def test_explicit_oracle_resume_never_reexecutes_vm_or_replaces_completed_case(self):
        with tempfile.TemporaryDirectory(prefix="_unit-preflight-resume-",dir=path.parents[2]/"zig-out") as tmp:
            root=Path(tmp);directory=root/"cases/closed";run=directory/"run-2m";run.mkdir(parents=True)
            (directory/"prepared.json").write_text(json.dumps({"arch":"bios","profile":"scale-firmware"}))
            (run/"completed.json").write_text(json.dumps({"application_pass":True,"returncode":33,"timed_out":False}))
            (run/"USOSPREP.LOG").write_text("peak=400000\nHEAP physical_current=0 physical_peak=410000 extent_peak=420000 reserved=900000\n")
            (directory/"program-footprint.json").write_text(json.dumps({"own_stack_already_in_allocator_peak":False,
                "loaded_image_bytes":150000,"own_stack_reserved_bytes":250000,
                "thunk_and_bootstrap_low_memory_budget_bytes":131072}))
            argv=["case","--workspace",str(root),"--name","closed","--arch","bios","--profile","scale-firmware",
                "--memory","2","--cpu","486","--qemu-dir",str(root),"--source-root",str(root),"--resume-windows"]
            with mock.patch("sys.argv",argv),mock.patch.object(case.api,"configure"),mock.patch.object(case.verification,"configure"),\
                 mock.patch.object(case.api,"checked",side_effect=lambda p:p),mock.patch.object(case.api,"execute") as execute,\
                 mock.patch.object(case,"host_oracle_mutex",side_effect=contextlib.nullcontext),\
                 mock.patch.object(case.firmware,"verify_closed_windows",return_value={"windows_files_and_chkdsk_pass":True,"independent_structure_pass":True}) as verify:
                case.main()
                execute.assert_not_called()
                self.assertEqual(verify.call_args.kwargs["attempt"],2)
                self.assertIs(verify.call_args.kwargs["reuse_export"],True)
                value=json.loads((directory/"preflight-completed.json").read_text())
                self.assertTrue(value["resumed_only_windows"])
                with self.assertRaises(ValueError):case.main()

if __name__=="__main__":unittest.main()
