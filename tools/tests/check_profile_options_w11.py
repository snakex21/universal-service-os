"""Check a rendered Windows 10/11 answer profile against offline registry hives.

Usage:
  python check_profile_options_w11.py AUTOUNATTEND.XML HIVE_DIR [--user Tester]

HIVE_DIR holds hives extracted from the installed disk:
  SOFTWARE, SYSTEM, DEFAULT            (Windows\\System32\\config)
  Default_NTUSER.DAT                   (Users\\Default\\NTUSER.DAT)
  <user>_NTUSER.DAT                    (Users\\<user>\\NTUSER.DAT)
  optional: root_listing.txt (one file name per line of C:\\ root, for hiberfil.sys)
  optional: UnattendGC_setupact.log (Windows\\Panther\\UnattendGC\\setupact.log: RunSynchronous
            exit codes and the JoinWorkgroup result)

Every `reg add` in the specialize RunSynchronous commands is checked:
  HKLM\\SOFTWARE\\...  -> SOFTWARE hive, HKLM\\SYSTEM\\... -> SYSTEM (CurrentControlSet = ControlSet001)
  HKU\\.DEFAULT\\...    -> DEFAULT hive
  HKU\\USOSDefault\\... -> Default_NTUSER.DAT and <user>_NTUSER.DAT (the user copy is reported
                          separately so values Windows rewrites at first logon show up)
Plus autologon, workgroup and hiberfil.sys absence. Prints PASS/FAIL per value; exit 1 on any
FAIL in the Default/HKLM checks (user-copy differences are reported as NOTE, not failures).
Requires python-registry (`from Registry import Registry`).
"""
import argparse
import os
import re
import shlex
import sys
import xml.etree.ElementTree as ET

from Registry import Registry

NS = {"u": "urn:schemas-microsoft-com:unattend"}


def reg_adds(xml_path):
    root = ET.parse(xml_path).getroot()
    out = []
    for settings in root.findall("u:settings", NS):
        if settings.get("pass") != "specialize":
            continue
        for path in settings.iter("{urn:schemas-microsoft-com:unattend}Path"):
            cmd = path.text or ""
            if cmd.lower().startswith("cmd.exe /c "):
                cmd = cmd[len("cmd.exe /c "):]
            for part in cmd.split(" & "):
                part = part.strip()
                m = re.match(r"(?i)(reg(\.exe)?)\s+add\s+(.*)", part)
                if not m:
                    continue
                toks = shlex.split(m.group(3), posix=True)
                key = toks[0]
                opts = {}
                i = 1
                while i < len(toks):
                    t = toks[i].lower()
                    if t in ("/v", "/t", "/d"):
                        opts[t] = toks[i + 1]
                        i += 2
                    else:
                        i += 1
                out.append((key, opts.get("/v"), opts.get("/t", "REG_SZ"), opts.get("/d", "")))
    return out


def open_hive(path):
    return Registry.Registry(path) if os.path.exists(path) else None


def read_value(hive, subkey, name):
    try:
        k = hive.open(subkey)
    except Registry.RegistryKeyNotFoundException:
        return ("nokey", None)
    try:
        return ("ok", k.value(name).value())
    except Registry.RegistryValueNotFoundException:
        return ("noval", None)


def expected(typ, data):
    if typ.upper() == "REG_DWORD":
        return int(data, 0)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xml")
    ap.add_argument("hives")
    ap.add_argument("--user", default="Tester")
    a = ap.parse_args()
    h = lambda n: open_hive(os.path.join(a.hives, n))
    software, system, default = h("SOFTWARE"), h("SYSTEM"), h("DEFAULT")
    dnt, unt = h("Default_NTUSER.DAT"), h(a.user + "_NTUSER.DAT")
    fails = 0
    notes = 0

    def report(tag, ok, label, got, want):
        nonlocal fails, notes
        if ok:
            print(f"PASS  {tag:9} {label} = {got!r}")
        elif tag == "user":
            notes += 1
            print(f"NOTE  {tag:9} {label} = {got!r} (want {want!r}; changed for/at first logon)")
        else:
            fails += 1
            print(f"FAIL  {tag:9} {label} = {got!r} (want {want!r})")

    seen = set()
    for key, name, typ, data in reg_adds(a.xml):
        if (key, name) in seen:
            print(f"NOTE  dup       {key}\\{name} added twice in specialize")
            continue
        seen.add((key, name))
        want = expected(typ, data)
        up = key.upper()
        targets = []
        if up.startswith("HKLM\\SOFTWARE\\"):
            targets = [("HKLM", software, key[len("HKLM\\SOFTWARE\\"):])]
        elif up.startswith("HKLM\\SYSTEM\\"):
            sub = key[len("HKLM\\SYSTEM\\"):]
            sub = re.sub(r"(?i)^CurrentControlSet", "ControlSet001", sub)
            targets = [("HKLM", system, sub)]
        elif up.startswith("HKU\\.DEFAULT\\"):
            targets = [(".DEFAULT", default, key[len("HKU\\.DEFAULT\\"):])]
        elif up.startswith("HKU\\USOSDEFAULT\\"):
            sub = key[len("HKU\\USOSDefault\\"):]
            targets = [("Default", dnt, sub), ("user", unt, sub)]
        else:
            print(f"SKIP  {key}\\{name} (unmapped root)")
            continue
        for tag, hive, sub in targets:
            if hive is None:
                print(f"SKIP  {tag:9} {key}\\{name} (hive missing)")
                continue
            st, got = read_value(hive, sub, name)
            report(tag, st == "ok" and got == want, f"{key}\\{name}", got if st == "ok" else st, want)

    if software is not None:
        wl = "Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
        for name, want in (("AutoAdminLogon", "1"), ("DefaultUserName", a.user)):
            st, got = read_value(software, wl, name)
            report("HKLM", st == "ok" and got == want, f"Winlogon\\{name}", got if st == "ok" else st, want)
    if system is not None:
        p = "ControlSet001\\Services\\Tcpip\\Parameters"
        st, got = read_value(system, p, "Hostname")
        print(f"INFO  HKLM      Tcpip Hostname = {got!r}")
        st, got = read_value(system, "ControlSet001\\Control\\Power", "HibernateEnabled")
        report("HKLM", st == "ok" and got == 0, "Control\\Power\\HibernateEnabled", got if st == "ok" else st, 0)
    xml_text = open(a.xml, encoding="utf-8").read()
    if software is not None and "<DisableWER>1</DisableWER>" in xml_text:
        st, got = read_value(software, "Microsoft\\Windows\\Windows Error Reporting", "Disabled")
        report("HKLM", st == "ok" and got == 1, "Windows Error Reporting\\Disabled", got if st == "ok" else st, 1)
    gc = os.path.join(a.hives, "UnattendGC_setupact.log")
    if os.path.exists(gc):
        log = open(gc, encoding="utf-8-sig", errors="replace").read()
        found = log.count("Found RunSynchronous command:")
        codes = re.findall(r"Process returned with exit code (0x[0-9a-fA-F]+)", log)
        bad = [c for c in codes if int(c, 16) != 0]
        report("log", found == len(codes) and found > 0 and not bad,
               "specialize RunSynchronous exit codes", f"{found} commands, {len(codes)} exits, nonzero={bad}", "all 0x0")
        m = re.search(r"JoinWorkgroup>([^<]+)<", xml_text)
        if m:
            ok = f"Joining workgroup [{m.group(1)}]" in log and "NetJoinDomain succeeded" in log
            report("log", ok, f"JoinWorkgroup {m.group(1)}", ok, True)
    listing = os.path.join(a.hives, "root_listing.txt")
    if os.path.exists(listing):
        names = [l.strip().lower() for l in open(listing, encoding="utf-8", errors="replace")]
        report("disk", "hiberfil.sys" not in names, "C:\\hiberfil.sys absent", "hiberfil.sys" not in names, True)

    print(f"\n{fails} FAIL, {notes} NOTE")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
