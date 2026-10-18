"""Host test: CSMWrap 3.1.2-usos11 patch 0010 (SeaBIOS NVMe runtime re-arm).

    python tools/tests/csmwrap/test_csmwrap_nvme_rearm.py

Static checks of the patch text (the code itself runs in the QEMU test
run_csmwrap_nvme_rearm_qemu.py): the re-arm runs before every INT 13h
transfer; a running controller with SeaBIOS's admin queue is used as it is,
one running another admin queue is refused before anything is written; the
re-arm allocates nothing at runtime, uses the BDF kept in struct nvme_ctrl
(struct pci_device is POST-only), disables before reprogramming AQA/ASQ/ACQ,
resets head/tail/phase and doorbells 0-3, creates CQ 1 before SQ 1; FUA only
after a re-arm. Also: the usos11 manifest hashes match the vendored files and
tools/xp_csmwrap_esp.sh pins the manifest binary.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
VENDOR = ROOT / "tools/vendor/csmwrap/3.1.2-usos11"
PATCH = VENDOR / "patches/0010-nvme-runtime-rearm.patch"


def file_part(text: str, name: str) -> tuple[str, str]:
    """(added lines, new-side lines) of one file in the patch."""
    start = text.index(f"--- a/{name}")
    nxt = text.find("\ndiff -ruN ", start)
    part = text[start:nxt if nxt >= 0 else len(text)]
    lines = part.splitlines()[2:]
    added = "\n".join(l[1:] for l in lines if l.startswith("+"))
    new = "\n".join(l[1:] for l in lines if l[:1] in ("+", " "))
    return added, new


def func(src: str, signature: str) -> str:
    body = src[src.index(signature):]
    end = body.find("\n}\n")  # the hunk may end inside the function
    return body if end < 0 else body[:end + 2]


def main() -> int:
    text = PATCH.read_text(encoding="utf-8")
    hdr_added, _ = file_part(text, "seabios/src/hw/nvme-int.h")
    assert "u16 bdf;" in hdr_added and "u8 rearmed;" in hdr_added
    added, new = file_part(text, "seabios/src/hw/nvme.c")

    rearm = func(new, "nvme_runtime_rearm(struct nvme_ctrl *ctrl)\n{")
    for bad in ("malloc", "zalloc", "free(", "ctrl->pci"):
        assert bad not in rearm, bad
    # running + ours -> 0, running + foreign -> -1, both before any write
    first_write = rearm.index("pci_config_writew")
    assert rearm.index("return 0;") < first_write
    assert rearm.index("other queues, not touched") < first_write
    running = re.search(r"\(cc & \(NVME_CC_EN \| NVME_CC_SHN_MASK\)\) == NVME_CC_EN\s*"
                        r"&& \(csts & \(NVME_CSTS_RDY \| NVME_CSTS_FATAL \| NVME_CSTS_SHST_MASK\)\)\s*"
                        r"== NVME_CSTS_RDY", rearm)
    assert running, "running test must exclude SHN requested/reported and fatal"
    # a 64-bit BAR above 4 GiB is refused
    assert "PCI_BASE_ADDRESS_1" in rearm
    # order: disable -> RDY 0 -> queue state -> AQA/ASQ/ACQ -> enable -> RDY 1 -> CQ -> SQ
    order = [rearm.index(k) for k in (
        "reg->cc = 0;", "nvme_wait_csts_rdy(ctrl, 0)", "ctrl->admin_cq.phase = ctrl->io_cq.phase = 1;",
        "reg->aqa = ", "reg->asq = (u32)", "reg->acq = (u32)", "reg->cc = NVME_CC_EN", "nvme_wait_csts_rdy(ctrl, 1)",
        "NVME_SQE_OPC_ADMIN_CREATE_IO_CQ", "NVME_SQE_OPC_ADMIN_CREATE_IO_SQ", "ctrl->rearmed = 1;")]
    assert order == sorted(order), order
    for idx, q in ((0, "admin_sq"), (1, "admin_cq"), (2, "io_sq"), (3, "io_cq")):
        assert f"&ctrl->{q}.common, {idx}, ctrl->{q}." in rearm, q
    assert "(1 << 16) | 1" in rearm  # SQ 1 -> CQ 1, contiguous
    # called before the transfer loop
    rw = func(new, "nvme_cmd_readwrite(struct nvme_namespace *ns, struct disk_op_s *op, int write)\n{")
    assert rw.index("nvme_runtime_rearm(ns->ctrl)") < rw.index("for (i = 0;")
    # BDF stored at POST, FUA only after a re-arm, only on writes
    assert "ctrl->bdf = pci->bdf;" in added
    assert re.search(r"if \(write && ns->ctrl->rearmed\)\s*io_read->dword\[12\] \|= 1U << 30;", added)

    manifest = json.loads((VENDOR / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "3.1.2-usos11"
    for name, digest in manifest["patches"].items():
        assert hashlib.sha256((VENDOR / "patches" / name).read_bytes()).hexdigest() == digest, name
    assert len(manifest["patches"]) == len(list((VENDOR / "patches").glob("*.patch"))) == 11
    efi = hashlib.sha256((VENDOR / "csmwrapx64.efi").read_bytes()).hexdigest()
    assert efi == manifest["files"]["csmwrapx64.efi"]
    # the release pins moved to 3.1.2-usos15 (same 0010 file, test_csmwrap_wheel15.py)
    assert (ROOT / "tools/vendor/csmwrap/3.1.2-usos15/patches" / "0010-nvme-runtime-rearm.patch").read_bytes() == (VENDOR / "patches" / "0010-nvme-runtime-rearm.patch").read_bytes()
    print("CSMWRAP-NVME-REARM-TEST-PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
