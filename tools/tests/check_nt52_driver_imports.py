"""Resolve the XP driver set (USB3 backport, KMDF, GenAHCI) against a Windows
Server 2003 x86 source, following export forwarders (ntoskrn8.sys forwards
most of its exports to ntoskrnl.exe): an import is resolved only when the
chain ends at a real export of a module that exists on the target.

    python tools/tests/check_nt52_driver_imports.py --source-iso PATH_TO_2003_CD1.iso [--json out.json]

Read-only; extracts the kernel, HAL and inbox modules to a scratch folder.
"""
from __future__ import annotations
from pathlib import Path
import argparse, json, struct, subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from xp_driver_overlay import DRIVERS  # noqa: E402

SEVEN = 'C:/Program Files/7-Zip/7z.exe'
# The USB3 backport and KMDF, as the NT 5.2 overlay ships them (the system's
# own StorPort and ACPI are kept; GenAHCI rides on the system StorPort).
NT52_SELECTED = ['ACPI/acpi.sys', 'Dependencies/ntoskrn8.sys', 'KMDF/wdf01000.sys', 'KMDF/wdfldr.sys', 'SATA/genahci.sys',
                 *['USB3/' + n for n in ('ksecd8.sys', 'ucx01000.sys', 'usbd8.sys', 'usbhub3.sys', 'usbxhci.sys', 'wpprecor.sys')]]
INBOX = {'ntoskrnl.exe': 'NTKRNLMP.EX_', 'hal.dll': 'HALMACPI.DL_', 'wmilib.sys': 'WMILIB.SY_',
         'storport.sys': 'STORPORT.SY_', 'usbd.sys': 'USBD.SY_', 'usbport.sys': 'USBPORT.SY_',
         'hidclass.sys': 'HIDCLASS.SY_', 'hidparse.sys': 'HIDPARSE.SY_'}


def pe(path: Path):
    b = path.read_bytes(); u = lambda o: struct.unpack_from('<I', b, o)[0]
    p = u(60); opt = p + 24; plus = struct.unpack_from('<H', b, opt)[0] == 0x20b
    dd = opt + (112 if plus else 96)
    sections = opt + struct.unpack_from('<H', b, p + 20)[0]

    def off(v):
        for i in range(struct.unpack_from('<H', b, p + 6)[0]):
            vs, va, rs, raw = struct.unpack_from('<IIII', b, sections + i * 40 + 8)
            if va <= v < va + max(vs, rs):
                return raw + v - va
        raise ValueError((path, v))

    def string(v):
        n = off(v); return b[n:b.index(b'\0', n)].decode('ascii')
    exports: dict[str, str | None] = {}
    imports: list[tuple[str, str]] = []
    erva, esize = u(dd), u(dd + 4)
    if erva:
        e = off(erva); names = off(u(e + 32)); ords = off(u(e + 36)); funcs = off(u(e + 28))
        for i in range(u(e + 24)):
            name = string(u(names + i * 4))
            rva = u(funcs + 4 * struct.unpack_from('<H', b, ords + 2 * i)[0])
            exports[name] = string(rva) if erva <= rva < erva + esize else None  # forwarder text
    if u(dd + 8):
        i = off(u(dd + 8)); step = 8 if plus else 4
        while u(i) or u(i + 12):
            mod = string(u(i + 12)).lower(); t = off(u(i) or u(i + 16))
            while True:
                val = struct.unpack_from('<Q' if plus else '<I', b, t)[0]
                if not val:
                    break
                imports.append((mod, '#%d' % (val & 0xffff) if val >> (63 if plus else 31) else string((val & 0xffffffff) + 2)))
                t += step
            i += 20
    return exports, imports


def resolve(tables, mod, name, depth=0):
    """None when resolved; else the missing (module, function) at the end of the chain."""
    if depth > 8 or mod not in tables or name not in tables[mod][0]:
        return (mod, name)
    target = tables[mod][0][name]
    if target is None:
        return None
    tmod, tname = target.split('.', 1)
    tmod = tmod.lower() + ('' if '.' in tmod else '.exe' if tmod.lower() == 'ntoskrnl' else '.dll' if tmod.lower() == 'hal' else '.sys')
    return resolve(tables, tmod, tname, depth + 1)


def check(iso: Path, work: Path) -> dict:
    subprocess.run([SEVEN, 'e', '-y', str(iso), *['I386\\' + n for n in INBOX.values()], '-o' + str(work)], check=True, stdout=subprocess.DEVNULL)
    tables = {}
    for name, packed in INBOX.items():
        subprocess.run([SEVEN, 'e', '-y', str(work / packed), '-o' + str(work)], check=True, stdout=subprocess.DEVNULL)
        # The expanded file keeps its own name (NTKRNLMP.EX_ -> ntkrnlmp.exe).
        stem = packed.rsplit('.', 1)[0].lower()
        plain = next(p for p in work.iterdir() if p.stem.lower() == stem and not p.name.endswith('_'))
        tables[name] = pe(plain)
    for rel in NT52_SELECTED:
        tables[Path(rel).name.lower()] = pe(DRIVERS / rel)
    report = {}
    for rel in NT52_SELECTED:
        name = Path(rel).name.lower()
        missing = sorted({m for m in (resolve(tables, mod, fn) for mod, fn in tables[name][1]) if m})
        report[name] = {'imports': len(tables[name][1]), 'missing': missing}
    return report


def main() -> int:
    p = argparse.ArgumentParser(); p.add_argument('--source-iso', type=Path, required=True); p.add_argument('--json', type=Path)
    a = p.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        report = check(a.source_iso, Path(tmp))
    if a.json:
        a.json.write_text(json.dumps(report, indent=2))
    bad = {k: v['missing'] for k, v in report.items() if v['missing']}
    for k, v in report.items():
        print(f"{k}: imports={v['imports']} missing={len(v['missing'])} {v['missing'][:12]}")
    if bad:
        print('FAIL: unresolved imports (forwarders followed)')
        return 1
    print('PASS: every import of the NT 5.2 driver set resolves on this source, export forwarders followed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
