"""Host-only harness checks; no QEMU process and no physical disk mapping."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import unittest
from unittest.mock import patch
import uuid

SOURCE = Path(__file__).resolve().parents[1] / "minios/uefi_case.py"
spec = importlib.util.spec_from_file_location("minios_platform_case", SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def setUpModule():
    m.ROOT.mkdir(parents=True, exist_ok=True)

def load_helper(name):
    helper_spec = importlib.util.spec_from_file_location("minios_" + name, SOURCE.with_name(name + ".py"))
    helper = importlib.util.module_from_spec(helper_spec)
    helper_spec.loader.exec_module(helper)
    return helper


class Guards(unittest.TestCase):
    def test_published_evidence_maps_only_complete_path_prefixes(self):
        helper=load_helper('collect_evidence')
        roots=[(Path(r'R:\portable'),'evidence')]
        self.assertEqual(helper.portable(r'R:\portable\run\target.raw',roots),'evidence/run/target.raw')
        with self.assertRaises(ValueError): helper.portable(r'R:\portable-other\private.raw',roots)

    def test_published_evidence_rejects_unmapped_private_and_unc_paths(self):
        helper=load_helper('collect_evidence')
        for value in (r'S:\private\data',r'\\server\private', '/private/data'):
            with self.subTest(value=value),self.assertRaises(ValueError): helper.portable(value,[])

    def test_published_evidence_keeps_opaque_volume_guid_without_host_path(self):
        helper=load_helper('collect_evidence')
        value=r'\\?\Volume{12345678-1234-1234-1234-123456789abc}'+'\\'
        self.assertEqual(helper.portable(value,[]),'nt-volume:12345678-1234-1234-1234-123456789abc')

    def test_published_evidence_sanitizes_paths_inside_captured_json(self):
        helper=load_helper('collect_evidence')
        value=json.dumps({'result':r'R:\portable\case\result.json'})
        mapped=helper.portable(value,[(Path(r'R:\portable'),'evidence')])
        self.assertEqual(json.loads(mapped),{'result':'evidence/case/result.json'})

    def test_ram_bisection_requires_adjacent_failure(self):
        helper = load_helper("ram_case")
        helper.case_api.ROOT=m.ROOT
        root = m.ROOT / ("_unit-" + uuid.uuid4().hex)
        root.mkdir()
        try:
            for memory in (64, 48, 56, 52, 50, 51):
                run = root / f"run-{memory}m"; run.mkdir()
                (run / "completed.json").write_text(json.dumps({"qemu_only": True, "application_pass": memory >= 52}))
            with patch.object(helper.case_api, "execute", side_effect=AssertionError("No guest expected")):
                result = helper.bisect(root, 420)
            self.assertEqual((result["minimum_mib"], result["adjacent_failure_mib"]), (52, 51))
        finally: shutil.rmtree(root)

    def test_export_read_lock_allows_read_but_denies_write(self):
        helper = load_helper("verify_case")
        root = m.ROOT / ("_unit-" + uuid.uuid4().hex)
        root.mkdir()
        image = root / "lock-fixture.bin"; image.write_bytes(b"own fixture")
        try:
            with helper.read_lock(image):
                self.assertEqual(image.read_bytes(), b"own fixture")
                with self.assertRaises(PermissionError):
                    with image.open("r+b"): pass
            with image.open("r+b"): pass
        finally: shutil.rmtree(root)

    def test_rejects_physical_or_external_and_dotdot(self):
        for path in (Path(r"\\.\PhysicalDrive0"), Path(r"C:\Windows\target.raw"), m.ROOT,
                     m.ROOT / ".." / "escape", Path(str(m.ROOT) + "-other") / "case",
                     m.ROOT / "case,bad", m.ROOT / "case\ncontrol", m.ROOT / "case\0control"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                m.checked(path)

    def test_accepts_exact_owned_child(self):
        self.assertEqual(m.checked(m.ROOT / "unit-case" / "image.raw"), m.ROOT / "unit-case" / "image.raw")

    def test_short_fat_names(self):
        e = m.FatBuilder.entry("BOOTIA32.EFI", 0x12345, 0x20000)
        self.assertEqual(e[:11], b"BOOTIA32EFI")
        self.assertEqual(struct.unpack_from("<H", e, 20)[0], 1)
        self.assertEqual(struct.unpack_from("<H", e, 26)[0], 0x2345)
        self.assertEqual(struct.unpack_from("<I", e, 28)[0], 0x20000)
        with self.assertRaises(ValueError): m.FatBuilder.entry("TOO-LONG-NAME.BIN", 2, 0)

    def test_large_fixture_is_streamed_and_over100mib(self):
        total = 0
        for block in m.large_blocks():
            self.assertLessEqual(len(block), 65536)
            total += len(block)
        self.assertEqual(total, 128 * 1024**2 + 123)
        self.assertGreater(total, 100 * 1024**2)


class OwnedImages(unittest.TestCase):
    def setUp(self):
        m.ROOT.mkdir(parents=True, exist_ok=True)
        self.root = m.checked(m.ROOT / ("_unit-" + uuid.uuid4().hex))
        self.root.mkdir(exist_ok=False)

    def tearDown(self):
        # Resolve and verify the exact exclusively-created test root before
        # recursive deletion. It never contains an active VM or shared base.
        target = self.root.resolve()
        if target.parent != m.ROOT.resolve() or not target.name.startswith("_unit-"):
            raise ValueError("Refusing cleanup outside exact unit-test root")
        m.checked(target)
        shutil.rmtree(target)

    def test_fat32_boot_parameters_and_closed_log_extraction(self):
        disk = self.root / "fat.raw"
        fat = m.FatBuilder(disk)
        text = b"USOSPREP synthetic harness log\n"
        fat.add("USOSPREP.LOG", len(text), [text])
        fat.finish()
        with disk.open("rb") as f:
            mbr = f.read(512)
            self.assertEqual(mbr[510:], b"\x55\xaa")
            self.assertEqual(mbr[450], 0xef)
            start, size = struct.unpack_from("<II", mbr, 454)
            f.seek(start * 512); bpb = f.read(512)
            self.assertEqual(bpb[82:90], b"FAT32   ")
            reserved = struct.unpack_from("<H", bpb, 14)[0]
            spf = struct.unpack_from("<I", bpb, 36)[0]
            clusters = (size - reserved - bpb[16] * spf) // bpb[13]
            self.assertGreaterEqual(clusters, 65525)
            self.assertLess(clusters, spf * 512 // 4)
            f.seek((start + 6) * 512); self.assertEqual(f.read(512), bpb)
        output = self.root / "extracted.log"
        self.assertTrue(m.extract_log(disk, output))
        self.assertEqual(output.read_bytes(), text)

    def test_uefi_prepare_exact_manifest_and_no_overwrite(self):
        efi = self.root / "dummy-harness-only.efi"
        efi.write_bytes(b"Own test fixture; no executable payload")
        case = self.root / "uefi"
        m.prepare(case, "ia32", "gpt", efi, 512 * 1024**2)
        prepared = json.loads((case / "prepared.json").read_text())
        expected = json.loads((case / "manifest.json").read_text())
        small_hash = hashlib.sha256(bytes(range(64))).hexdigest()
        self.assertEqual(prepared["hashes"]["small"], small_hash)
        self.assertEqual(len(expected["files"]), 1005)
        self.assertEqual(expected["files"]["Fixtures/item-0000.txt"]["sha256"], small_hash)
        self.assertEqual(expected["files"]["Fixtures/Nested/large.bin"]["sha256"], prepared["hashes"]["large"])
        with (case / "target-base.raw").open("rb") as f:
            marker = f.read(512)
        self.assertTrue(marker.startswith(b"USOSPREP TARGET v1\n" + prepared["token"].encode() + b"\n"))
        with self.assertRaises(FileExistsError): m.prepare(case, "ia32", "gpt", efi, 512 * 1024**2)

    def test_bios_explicit_drive_configuration(self):
        program = self.root / "dummy-harness-only.img"
        with program.open("xb") as f: f.truncate(1024 * 1024)
        case = self.root / "bios"
        m.prepare(case, "bios", "mbr", program, 512 * 1024**2)
        with (case / "esp-base.raw").open("rb") as f:
            f.seek(1024 * 512); cfg = f.read(512)
            f.seek(2048 * 512); small = f.read(64)
        self.assertEqual(cfg[:16], b"USOSPREP BIOS v1")
        self.assertEqual(struct.unpack_from("<IIQ", cfg, 16), (1, 512, 1024 * 1024))
        self.assertEqual(cfg[128:130], b"\x81\x80")
        self.assertEqual(small, bytes(range(64)))
        self.assertEqual(struct.unpack_from("<QQ", cfg, 96), (2056 * 512, m.LARGE_SIZE))

    def test_cleanup_refuses_no_closed_guest(self):
        (self.root/"prepared.json").write_text('{"qemu_only":true}')
        image=self.root/"target-base.raw"; image.write_bytes(b"owned unit fixture")
        with self.assertRaises(ValueError): m.cleanup(self.root)
        self.assertTrue(image.exists())

    def test_cleanup_exact_allowlist_keeps_evidence_and_unknown_files(self):
        (self.root/"prepared.json").write_text('{"qemu_only":true}')
        run=self.root/"run-64m"; run.mkdir()
        (run/"completed.json").write_text('{"qemu_only":true,"returncode":33}')
        (run/"USOSPREP.LOG").write_text("USOSPREP PASS; synthetic test fixture\n")
        image=self.root/"target-base.raw"; image.write_bytes(b"own base unit fixture")
        cow=run/"target.qcow2"; cow.write_bytes(b"own overlay unit fixture")
        unknown=self.root/"not-allowlisted.raw"; unknown.write_bytes(b"must remain")
        result=m.cleanup(self.root)
        self.assertEqual(result["state"],"complete")
        self.assertFalse(image.exists()); self.assertFalse(cow.exists())
        self.assertTrue(unknown.exists()); self.assertTrue((run/"USOSPREP.LOG").exists())
        plan=json.loads((self.root/"cleanup.json").read_text())
        self.assertEqual(len(plan["files"]),2)
        self.assertEqual(plan["files"][0]["sha256"],hashlib.sha256(b"own base unit fixture").hexdigest())

    def simulate_process(self, events):
        (self.root/"prepared.json").write_text('{"arch":"x86_64"}')
        class Process:
            def __init__(self): self.events=iter(events); self.kills=0; self.waits=[]
            def wait(self,timeout=None):
                self.waits.append(timeout); event=next(self.events)
                if isinstance(event,BaseException): raise event
                return event
            def kill(self): self.kills+=1
        process=Process()
        def log(_source,destination): destination.write_bytes(b"USOSPREP PASS; synthetic fixture\n"); return True
        with patch.object(m,"run_command"), patch.object(m.shutil,"copyfile"), patch.object(m,"hash_file",return_value="0"*64), patch.object(m,"extract_log",side_effect=log), patch.object(m.subprocess,"Popen",return_value=process):
            result=m.execute(self.root,64,120)
        return result,process,json.loads((self.root/"run-64m/completed.json").read_text())

    def test_interrupt_kills_and_waits_owned_child_and_records_failure(self):
        result,process,receipt=self.simulate_process([KeyboardInterrupt(),-9])
        self.assertFalse(result); self.assertEqual(process.kills,1)
        self.assertEqual(process.waits,[120,None]); self.assertTrue(receipt["interrupted"])

    def test_failure_status_cannot_pass_even_with_pass_text(self):
        result,process,receipt=self.simulate_process([35])
        self.assertFalse(result); self.assertEqual(process.kills,0)
        self.assertEqual(receipt["returncode"],35); self.assertFalse(receipt["application_pass"])


if __name__ == "__main__": unittest.main()
