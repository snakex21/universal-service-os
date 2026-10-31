#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One capacity preflight: closed-file logical bytes plus full declared reservations.

Reserved subtrees/files are never stat'ed or traversed: they can be active.
All unreserved files must be declared closed by the coordinating operator.
This is allocation planning, never a progress probe, and performs no cleanup.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat

spec = importlib.util.spec_from_file_location("pool_wim_oracle", Path(__file__).with_name("wim_oracle.py"))
oracle = importlib.util.module_from_spec(spec); spec.loader.exec_module(oracle)
GiB = 1024**3
CAP = 100 * GiB
MAX_CAP = 150 * GiB


def plan_limit(record: dict) -> int:
    """100GiB remains the default;150GiB is an explicit approved opt-in.

    Accept only the two coordinated operator budgets, never an arbitrary
    numeric override or a truthy value coerced to an integer.
    """
    value = record.get("cap_bytes", CAP)
    if type(value) is not int or value not in (CAP, MAX_CAP):
        raise ValueError("Plan cap_bytes must explicitly select100GiB or150GiB")
    return value


def audit(root: Path, reservations: list[dict], *, limit: int = CAP) -> dict:
    oracle.local(root)
    if root != oracle.RUNTIME or type(limit) is not int or not 0 < limit <= MAX_CAP:
        raise ValueError("Explicit WIM runtime and at most150GiB required")
    reserved = []
    for item in reservations:
        if set(item) != {"path", "bytes"} or type(item["bytes"]) is not int or not 0 < item["bytes"] <= limit:
            raise ValueError("A positive bounded exact reservation is required")
        relative = item["path"]
        if (not isinstance(relative, str) or not relative or Path(relative).drive or Path(relative).is_absolute()
            or ".." in Path(relative).parts or any(c in relative for c in ":,\r\n\0")):
            raise ValueError("A local runtime-relative reservation path is required")
        path = root / relative
        # Validate only ancestors: the reserved leaf itself may be an active
        # file, whose metadata is deliberately never inspected here.
        oracle.local(path.parent)
        if any(path == other or path.is_relative_to(other) or other.is_relative_to(path) for other, _ in reserved):
            raise ValueError("Reservations must be disjoint; do not count an ancestor and its children")
        reserved.append((path, item["bytes"]))
    def skipped(path):
        return any(path == other or path.is_relative_to(other) for other, _ in reserved)
    closed = count = 0
    opaque_reparses = []
    groups = {}
    pending = [root]
    while pending:
        folder = pending.pop()
        with os.scandir(folder) as entries:
            for entry in entries:
                path = Path(entry.path)
                if skipped(path): continue
                info = entry.stat(follow_symlinks=False)
                opaque = entry.is_symlink() or bool(getattr(info, "st_file_attributes", 0) & 0x400)
                if opaque:
                    # Native oracle fixtures may themselves be reparse
                    # objects. Charge only the owned leaf metadata; never
                    # open its target, recurse, or count another tree twice.
                    opaque_reparses.append(str(path.relative_to(root)))
                if stat.S_ISDIR(info.st_mode) and not opaque:
                    pending.append(path)
                elif stat.S_ISREG(info.st_mode) or opaque:
                    count += 1; closed += info.st_size
                    if count > 1_000_000: raise ValueError("Capacity file-count bound exceeded")
                    name = path.relative_to(root).parts[0]
                    groups[name] = groups.get(name, 0) + info.st_size
                else:
                    raise ValueError("Capacity tree contains a non-regular object")
    planned = sum(value for _, value in reserved)
    return {"schema": "usos-wim-pool-v1", "root": str(root), "cap_bytes": limit,
            "closed_file_count": count, "closed_logical_bytes": closed,
            "closed_top_level_bytes": groups, "reservations": reservations,
            "reserved_bytes": planned, "projected_total_bytes": closed + planned,
            "headroom_bytes": limit - closed - planned, "passed": closed + planned <= limit,
            "reserved_paths_not_traversed": True, "unreserved_files_declared_closed": True,
            "opaque_reparse_leaves_not_followed": opaque_reparses,
            "logical_not_sparse_allocated_accounting": True, "cleanup_performed": False}


def enforce(plan: Path, case: Path) -> dict:
    oracle.owned(plan); oracle.owned(case)
    record = json.loads(plan.read_text(encoding="utf-8"))
    if record.get("schema") != "usos-wim-pool-plan-v1" or record.get("unreserved_files_declared_closed") is not True:
        raise ValueError("An explicit frozen closed-files/reservations capacity plan is required")
    limit = plan_limit(record)
    covers = [row for row in record["reservations"] if case == oracle.RUNTIME / row["path"]
              or case.is_relative_to(oracle.RUNTIME / row["path"])]
    if len(covers) != 1:
        raise ValueError("This new firmware case has no whole-case reservation")
    result = audit(oracle.RUNTIME, record["reservations"], limit=limit)
    if not result["passed"]:
        raise ValueError("WIM aggregate pool would exceed the explicit plan cap_bytes")
    # Initial CLI audit reserves free space for ALL future scopes. Subsequent
    # operations charge their own full cap, not already-written scopes again.
    oracle.storage_guard(covers[0]["bytes"])
    return result


def enforce_incremental(plan: Path, case: Path, growth_bytes: int, *, closed_scope: bool = False) -> dict:
    """Grow one explicitly closed reservation without charging its base twice.

    Only the selected, declared-closed reservation is traversed. Other
    reservations remain opaque to audit(), including any running VM scope.
    The coordinating caller must establish completed pinned prerequisite
    receipts before asserting closed_scope; elapsed time is not that proof.
    """
    oracle.owned(plan); oracle.owned(case)
    if closed_scope is not True or type(growth_bytes) is not int or not 0 < growth_bytes <= 2*GiB:
        raise ValueError("Explicit closed-scope declaration and at most2GiB growth required")
    record = json.loads(plan.read_text(encoding="utf-8"))
    if record.get("schema") != "usos-wim-pool-plan-v1" or record.get("unreserved_files_declared_closed") is not True:
        raise ValueError("Approved frozen capacity plan required")
    limit = plan_limit(record)
    covers = [row for row in record["reservations"] if case == oracle.RUNTIME / row["path"]
              or case.is_relative_to(oracle.RUNTIME / row["path"])]
    if len(covers) != 1:
        raise ValueError("Incremental case must belong to exactly one whole reservation")
    result = audit(oracle.RUNTIME, record["reservations"], limit=limit)
    if not result["passed"]:
        raise ValueError("Aggregate approved pool cap exceeded")
    selected = covers[0]
    scope = oracle.local(oracle.RUNTIME / selected["path"])
    existing = count = 0
    pending = [scope] if scope.exists() else []
    while pending:
        folder = pending.pop()
        with os.scandir(folder) as entries:
            for entry in entries:
                # Windows DirEntry.stat reports st_nlink=0 from cached find
                # data; lstat asks for the real ordinary-file link count.
                info = Path(entry.path).lstat()
                if entry.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                    raise ValueError("Closed incremental scope may not contain links/reparse points")
                if stat.S_ISDIR(info.st_mode):
                    pending.append(Path(entry.path))
                elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                    existing += info.st_size; count += 1
                    if count > 1_000_000:
                        raise ValueError("Closed incremental scope file bound exceeded")
                else:
                    raise ValueError("One ordinary file link per closed-scope artifact required")
    if existing + growth_bytes > selected["bytes"]:
        raise ValueError("Closed artifacts plus incremental growth exceed whole-scope cap")
    # Preserve100GiB actual free; charge only the genuinely new bounded files.
    oracle.storage_guard(growth_bytes)
    result.update(incremental_scope=selected["path"], incremental_scope_explicitly_closed=True,
                  incremental_existing_bytes=existing, incremental_file_count=count,
                  incremental_growth_bytes=growth_bytes, incremental_scope_limit=selected["bytes"],
                  only_selected_closed_scope_traversed=True)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True); parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    oracle.owned(args.plan); oracle.owned(args.out)
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    if plan.get("schema") != "usos-wim-pool-plan-v1" or plan.get("unreserved_files_declared_closed") is not True:
        raise ValueError("Coordinated closed-files declaration required before any capacity scan")
    result = audit(oracle.RUNTIME, plan["reservations"], limit=plan_limit(plan))
    oracle.storage_guard(result["reserved_bytes"])
    oracle.save(args.out, result)
    print(json.dumps(result)); raise SystemExit(0 if result["passed"] else 1)
