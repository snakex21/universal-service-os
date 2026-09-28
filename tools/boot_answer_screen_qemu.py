#!/usr/bin/env python3
"""Click through the XP answer-file screen (the answer-profile manager) of the
USOS UEFI menu in QEMU/OVMF.

Called by tools/tests/run_uefi_answer_screen.ps1 with a copy of the boot-ui
test disk whose DATA has an XP image, an active usos-xp.ini and test.sif
(attached with -snapshot, so QEMU never writes to it). Input: keyboard
(Enter/Esc/Backspace/arrows through the monitor; Esc and Backspace are also
what handheld firmware sends for pad B) and a USB mouse through QMP (right
click, and a click on the footer Esc hint, which goes through the same hit
test as a touch tap; QEMU's usb-tablet delivers no taps to OVMF, see
artifacts/boot-ui/input-results.json hint_back for tablet). QEMU emulates no gamepad; the USB pad path
maps B to the same menu event (src/platform/uefi/input.zig padEvent).

The menu traces its screens on the serial port: [UI_SCREEN] list|summary
<title>, [UI_LIST] ... selected=/rows=, [UI_ROW] <kind> | <title> on the
answer screen, [UI_FIELD] <label> = <value> on the summary and
[XP_CMDLINE] <kernel options> when XP starts (the test ESP has no XP kernel,
so the start stops right after). The observed rows are compared with
tools/tests/golden/uefi_answer_screen.tsv (--update rewrites it).

Answer profiles (docs/answer-profiles.md): "+ Add a new profile" opens the
form ([UI_SCREEN] form <title>, [UI_FORM] ...); the test types a name and a
user with the keyboard, saves ([PROFILE] saved <stem> on the ESP, which
-snapshot keeps off the disk image), uses the profile (summary, command line
usos.xp_settings=plan, [PROFILE] staged), edits it with F2 (pad X), leaves
the editor with Esc without saving, and deletes it with Delete (pad Y) after
the confirmation list.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from boot_input_qemu import Qmp, point
from boot_ui_screens import OVMF_CODE, OVMF_VARS, QEMU, WORK, Monitor, free_port, wait_serial

WIDTH, HEIGHT = 1280, 800
ANSWER_TITLE = "Unattended setup"
XP_TITLE = "Windows XP"
failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(("PASS " if condition else "FAIL ") + name + ("" if condition else f"  {detail}"))
    if not condition:
        failures.append(name)


class Serial:
    def __init__(self, path: Path):
        self.path = path
        self.mark = 0

    def text(self) -> str:
        return self.path.read_text(encoding="utf-8", errors="replace") if self.path.exists() else ""

    def since(self) -> str:
        return self.text()[self.mark:]

    def reset(self) -> None:
        self.mark = len(self.text())

    def wait(self, pattern: str, timeout: float = 20) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = self.since()
            if re.search(pattern, chunk):
                time.sleep(0.8)
                return self.since()
            time.sleep(0.3)
        return self.since()


def screens(chunk: str) -> list[str]:
    return [m.strip() for m in re.findall(r"\[UI_SCREEN\] ([^\r\n]*)", chunk)]


def last_list(chunk: str) -> tuple[int, int] | None:
    states = re.findall(r"\[UI_LIST\] first=\d+ selected=(\d+) visible=\d+ rows=(\d+)", chunk)
    return (int(states[-1][0]), int(states[-1][1])) if states else None


def rows(chunk: str) -> list[str]:
    return [m.strip() for m in re.findall(r"\[UI_ROW\] ([^\r\n]*)", chunk)]


def fields(chunk: str) -> dict[str, str]:
    return {m[0].strip(): m[1].strip() for m in re.findall(r"\[UI_FIELD\] ([^=\r\n]*) = ([^\r\n]*)", chunk)}


def forms(chunk: str) -> list[str]:
    return [m.strip() for m in re.findall(r"\[UI_FORM\] ([^\r\n]*)", chunk)]


def cmdline(chunk: str) -> str:
    found = re.findall(r"\[XP_CMDLINE\] ([^\r\n]*)", chunk)
    return found[-1] if found else ""


def run(disk: Path, out: Path) -> list[str]:
    WORK.mkdir(parents=True, exist_ok=True)
    serial_path = WORK / "serial-answer-screen.log"
    if serial_path.exists():
        serial_path.unlink()
    port, qmp_port = free_port(), free_port()
    vars_copy = WORK / "vars-answer-screen.fd"
    shutil.copyfile(OVMF_VARS, vars_copy)
    args = [
        str(QEMU), "-name", "USOS-answer-screen", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none", "-rtc", "base=localtime",
        "-display", "none", "-device", f"VGA,edid=on,xres={WIDTH},yres={HEIGHT}",
        "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
        "-serial", f"file:{serial_path.as_posix()}",
        "-drive", f"if=none,id=usos,file={disk.as_posix()},format=vpc,snapshot=on",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1",
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
        "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}",
        "-device", "qemu-xhci,id=xhci", "-device", "usb-mouse,id=mouse0,bus=xhci.0",
        "-no-shutdown",
    ]
    stderr = open(WORK / "qemu-answer-screen.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    golden: list[str] = []
    shot_index = 0
    try:
        monitor = Monitor(port)
        qmp = Qmp(qmp_port)
        serial = Serial(serial_path)

        def shot(name: str) -> None:
            nonlocal shot_index
            shot_index += 1
            monitor.shot(out / f"answer-{shot_index:02d}-{name}.png")

        def key(name: str, expect: str | None = None, timeout: float = 20) -> str:
            serial.reset()
            monitor.key(name, 0.3)
            return serial.wait(expect, timeout) if expect else (time.sleep(3) or serial.since())

        def mouse(x: int, y: int, button: str, expect: str) -> str:
            serial.reset()
            point(qmp, "mouse", WIDTH, HEIGHT, x, y)
            qmp.click(button, None)
            return serial.wait(expect)

        def answer_screen(chunk: str, label: str) -> None:
            state = last_list(chunk)
            observed = rows(chunk)
            check(f"{label}: answer screen shown", f"list {ANSWER_TITLE}" in screens(chunk), str(screens(chunk)))
            golden.append(f"{label}\tscreen\t{ANSWER_TITLE}\tselected={state[0] if state else '?'}\trows={state[1] if state else '?'}")
            for index, row in enumerate(observed):
                golden.append(f"{label}\trow{index}\t{row}")

        def back_to_images(chunk: str, how: str) -> None:
            seen = screens(chunk)
            check(f"back ({how}) returns to the image list", bool(seen) and seen[-1] == f"list {XP_TITLE}", str(seen))
            # A pointer move may redraw the answer screen (footer hints follow
            # the input device) before the Back; it must not come after it.
            images = max((i for i, s in enumerate(seen) if s == f"list {XP_TITLE}"), default=-1)
            check(f"back ({how}) does not reopen the answer screen", images >= 0 and f"list {ANSWER_TITLE}" not in seen[images:], str(seen))
            golden.append(f"back-{how}\tscreen\t{seen[-1] if seen else '-'}")

        wait_serial(serial_path, "USOS MANUAL FLOW BOOT PASS", 300)
        time.sleep(6)
        # Home -> Windows systems; find Windows XP by the images screen title.
        chunk = key("ret", r"\[UI_SCREEN\] list")
        systems_title = screens(chunk)[-1] if screens(chunk) else ""
        found = False
        for downs in range(0, 12):
            key("home")
            for _ in range(downs):
                monitor.key("down", 0.4)
            chunk = key("ret", r"\[UI_SCREEN\] list", 8)
            seen = screens(chunk)
            if seen and seen[-1] == f"list {XP_TITLE}":
                found = True
                break
            key("esc")  # another system's images (or its notice): back to the systems
        check("Windows XP image list reached", found, systems_title)
        if not found:
            return golden
        shot("xp-images")

        # 1. Enter: the single XP method is taken without asking -> answer screen.
        chunk = key("ret", r"\[UI_ROW\]")
        answer_screen(chunk, "open")
        state = last_list(chunk)
        observed = rows(chunk)
        check("rows: manual, usos-xp.ini, .sif, add profile", [r.split(" | ")[0] for r in observed] == ["xp_manual", "xp_settings", "file", "add"], str(observed))
        check("manual installation row always present", bool(observed) and observed[0] == "xp_manual | No answer file (manual installation)", str(observed))
        check("usos-xp.ini row selected by default", state == (1, 4), str(state))
        check("key never on screen", "AAAAA" not in chunk, "")
        shot("answer-default")

        # 2. Back in every way the menu offers it -> image list (bug 2).
        back_to_images(key("esc", r"\[UI_SCREEN\]"), "esc")
        shot("back-esc")
        key("ret", r"\[UI_ROW\]")
        back_to_images(key("backspace", r"\[UI_SCREEN\]"), "backspace")
        key("ret", r"\[UI_ROW\]")
        back_to_images(mouse(WIDTH // 2, HEIGHT // 2, "right", r"\[UI_SCREEN\]"), "right-click")
        key("ret", r"\[UI_ROW\]")
        back_to_images(mouse(int(WIDTH * 0.195), HEIGHT - 22, "left", r"\[UI_SCREEN\]"), "footer-tap")
        shot("back-tap")

        # 3. Each row: summary text, Back to the answer screen, start -> command line.
        def row_flow(label: str, moves: list[str], summary_value: str, must: list[str], must_not: list[str]) -> None:
            chunk = key("ret", r"\[UI_ROW\]")
            for move in moves:
                monitor.key(move, 0.6)
            chunk = key("ret", r"\[UI_SCREEN\] summary")
            values = fields(chunk)
            answer = values.get("Answer file", "")
            check(f"{label}: summary answer file", answer == summary_value, repr(answer))
            golden.append(f"{label}\tsummary\tAnswer file = {answer}")
            shot(f"{label}-summary")
            # Back from the summary -> answer screen (it was shown).
            chunk = key("esc", r"\[UI_ROW\]")
            check(f"{label}: back from summary returns to the answer screen", f"list {ANSWER_TITLE}" in screens(chunk), str(screens(chunk)))
            state = last_list(chunk)
            for move in moves:
                monitor.key(move, 0.6)
            key("ret", r"\[UI_SCREEN\] summary")
            chunk = key("ret", r"\[XP_CMDLINE\]", 30)
            line = cmdline(chunk)
            check(f"{label}: XP start command line traced", bool(line), chunk[-400:])
            for token in must:
                check(f"{label}: command line has {token}", token in line, line)
            for token in must_not:
                check(f"{label}: command line lacks {token}", token not in line, line)
            options = " ".join(t for t in line.split() if t.startswith(("usos.legacy_unattended_hex", "usos.xp_settings")))
            golden.append(f"{label}\tcmdline\t{options or '-'}")
            time.sleep(4)
            shot(f"{label}-start")
            # The test ESP has no XP kernel: dismiss the error; the menu
            # returns to the answer screen.
            chunk = key("ret", r"\[UI_ROW\]")
            check(f"{label}: after the stopped start the answer screen is back", f"list {ANSWER_TITLE}" in screens(chunk), str(screens(chunk)))
            key("esc", r"\[UI_SCREEN\]")  # -> image list for the next row

        row_flow("manual", ["up"], "No answer file (manual installation)", ["usos.xp_settings=off"], ["usos.legacy_unattended_hex"])
        row_flow("settings", [], "usos-xp.ini: Jan Kowalski, USOS-TEST", [], ["usos.xp_settings", "usos.legacy_unattended_hex"])
        row_flow("sif", ["down"], "test.sif (merged into the automatic answer)", ["usos.legacy_unattended_hex=746573742e736966"], ["usos.xp_settings"])

        # 3b. Answer profiles: add, use, edit, back from the editor, delete.
        def type_text(text: str) -> None:
            for c in text:
                name = {"-": "minus", " ": "spc", ".": "dot", "#": "shift-3"}.get(c, c.lower())
                monitor.key(("shift-" + name) if c.isupper() else name, 0.35)

        chunk = key("ret", r"\[UI_ROW\]")
        chunk = key("end", r"\[UI_ROW_SELECTED\]", 8)
        check("profiles: End selects the add row", "[UI_ROW_SELECTED] add" in chunk, chunk[-300:])
        chunk = key("ret", r"\[UI_SCREEN\] form", 15)
        opened = screens(chunk)
        check("profiles: + Add opens the editor", bool(opened) and opened[-1] == "form New answer profile", str(opened))
        golden.append(f"profile-add\tscreen\t{opened[-1] if opened else '-'}")
        check("profiles: editor starts on the user field", "selected index=1 label=User name" in "\n".join(forms(chunk)), str(forms(chunk)))
        shot("profile-new")
        # Save with an empty name: the name gets the selection (required).
        key("end", None)
        monitor.key("up", 0.5)
        chunk = key("ret", r"\[UI_FORM\]", 8)
        # Name field: Enter opens the keyboard, type, Enter closes.
        chunk = key("home", r"\[UI_FORM\] selected", 8)
        key("ret", r"\[UI_FORM\] edit", 8)
        shot("profile-keyboard")
        type_text("Test")
        chunk = key("ret", r"\[UI_FORM\]", 5)
        monitor.key("down", 0.5)
        key("ret", r"\[UI_FORM\] edit", 8)
        type_text("Tester")
        chunk = key("ret", r"\[UI_FORM\]", 5)
        values = "\n".join(forms(serial.text()))
        check("profiles: name typed", "label=Profile name value=Test" in values, values[-500:])
        check("profiles: user typed", "label=User name value=Tester" in values, values[-500:])
        shot("profile-filled")
        # The bottom of the XP form: "Use for" and "Appearance and extras".
        key("end", r"\[UI_FORM\] selected", 8)
        monitor.key("up", 0.5)
        chunk = key("up", r"\[UI_FORM\] selected", 8)
        shot("profile-extras")
        check("profiles: XP editor ends with the resolution tweak", "label=Screen resolution value=Automatic" in "\n".join(forms(chunk)), "\n".join(forms(chunk))[-400:])
        chunk = key("down", r"\[UI_FORM\] selected", 8)
        chunk = key("ret", r"\[UI_ROW\]", 15)
        check("profiles: Save writes the profile on the ESP", "[PROFILE] saved test" in chunk, chunk[-400:])
        observed = rows(chunk)
        golden.append("profile-saved\trows\t" + ",".join(r.split(" | ")[0] for r in observed))
        check("profiles: the new profile is listed", [r.split(" | ")[0] for r in observed] == ["xp_manual", "xp_settings", "profile", "file", "add"], str(observed))
        check("profiles: the row shows the name", "profile | Test" in observed, str(observed))
        shot("profile-listed")

        # Use it: summary, start, command line with usos.xp_settings=plan.
        state = last_list(chunk)
        check("profiles: the saved profile is selected", state is not None and state[0] == 2, str(state))
        chunk = key("ret", r"\[UI_SCREEN\] summary")
        answer = fields(chunk).get("Answer file", "")
        check("profiles: summary names the profile", answer.startswith("Profile Test: Tester"), repr(answer))
        golden.append(f"profile-use\tsummary\tAnswer file = {answer}")
        chunk = key("ret", r"\[XP_CMDLINE\]", 30)
        line = cmdline(chunk)
        check("profiles: XP start passes usos.xp_settings=plan", "usos.xp_settings=plan" in line, line)
        check("profiles: the profile was rendered on the ESP", "[PROFILE] staged Test for windows-xp format=nt5_settings" in chunk, chunk[-600:])
        golden.append("profile-use\tcmdline\t" + (" ".join(t for t in line.split() if t.startswith(("usos.legacy_unattended_hex", "usos.xp_settings"))) or "-"))
        time.sleep(4)
        chunk = key("ret", r"\[UI_ROW\]")

        # Edit (F2 = pad X): computer name, Save.
        monitor.key("home", 0.5)
        monitor.key("down", 0.5)
        chunk = key("down", r"\[UI_ROW_SELECTED\]", 8)
        check("profiles: profile row selected for editing", "[UI_ROW_SELECTED] profile" in chunk, chunk[-300:])
        chunk = key("f2", r"\[UI_SCREEN\] form", 15)
        check("profiles: F2 opens the editor", "form Answer profile" in screens(chunk), str(screens(chunk)))
        golden.append(f"profile-edit\tscreen\t{screens(chunk)[-1] if screens(chunk) else '-'}")
        for _ in range(3):
            monitor.key("down", 0.4)
        key("ret", r"\[UI_FORM\] edit", 8)
        type_text("PC-1")
        key("ret", r"\[UI_FORM\]", 5)
        key("end", None)
        monitor.key("up", 0.5)
        chunk = key("ret", r"\[UI_ROW\]", 15)
        check("profiles: edit saved", "[PROFILE] saved test" in chunk, chunk[-400:])
        check("profiles: edited row detail", any(r.startswith("profile | Test") for r in rows(chunk)), str(rows(chunk)))
        check("profiles: computer name in the saved profile", "label=Computer name value=PC-1" in "\n".join(forms(serial.text())), "")
        shot("profile-edited")

        # Back from the editor (Esc) saves nothing.
        chunk = key("f2", r"\[UI_SCREEN\] form", 15)
        chunk = key("esc", r"\[UI_ROW\]", 15)
        check("profiles: Esc leaves the editor without saving", f"list {ANSWER_TITLE}" in screens(chunk) and "[PROFILE] saved" not in chunk, chunk[-300:])
        golden.append(f"profile-edit-esc\tscreen\t{screens(chunk)[-1] if screens(chunk) else '-'}")

        # Delete (Delete = pad Y): confirmation, Keep first, then Delete.
        chunk = key("delete", r"\[UI_SCREEN\] list", 15)
        check("profiles: Delete asks first", "list Delete profile" in screens(chunk), str(screens(chunk)))
        golden.append(f"profile-delete\tscreen\t{screens(chunk)[-1] if screens(chunk) else '-'}")
        shot("profile-delete-confirm")
        chunk = key("ret", r"\[UI_ROW\]", 15)
        check("profiles: Keep keeps the profile", "profile | Test" in rows(chunk) and "[PROFILE] deleted" not in chunk, str(rows(chunk)))
        # The selection stays on the profile row after Keep.
        chunk = key("delete", r"\[UI_SCREEN\] list", 15)
        monitor.key("down", 0.5)
        chunk = key("ret", r"\[UI_ROW\]", 15)
        check("profiles: Delete removes the profile", "[PROFILE] deleted test" in chunk, chunk[-400:])
        observed = rows(chunk)
        check("profiles: list without the profile", [r.split(" | ")[0] for r in observed] == ["xp_manual", "xp_settings", "file", "add"], str(observed))
        golden.append("profile-deleted\trows\t" + ",".join(r.split(" | ")[0] for r in observed))
        shot("profile-deleted")
        key("esc", r"\[UI_SCREEN\]")  # -> image list

        # 4. Image list -> Esc -> systems list.
        chunk = key("esc", r"\[UI_SCREEN\]")
        seen = screens(chunk)
        check("image list Esc returns to the systems", bool(seen) and seen[-1] == systems_title, f"{seen} vs {systems_title}")
        golden.append(f"images-esc\tscreen\t{seen[-1] if seen else '-'}")
        shot("systems")

        # 5a. The edition pick list of the Windows 10 editor (the placeholder
        # ISO has no readable install image: the usual Windows 10 editions,
        # then "Type manually..."): pick Pro, type a value, Y/Del back to
        # "(Setup asks)", X/F2 types again, Esc saves nothing.
        def edition_flow() -> None:
            key("end", r"\[UI_ROW_SELECTED\]", 8)
            chunk = key("ret", r"\[UI_SCREEN\] form", 15)
            check("edition: + Add opens the Windows 10 editor", "form New answer profile" in screens(chunk), str(screens(chunk)))
            last = (forms(chunk) or ["-"])[-1]
            for _ in range(20):
                if "label=Edition" in last:
                    break
                chunk = key("down", r"\[UI_FORM\] selected", 8)
                last = (forms(chunk) or ["-"])[-1]
            check("edition: the Edition row starts at Setup asks", "label=Edition value=(Setup asks)" in last, last)
            golden.append("edition-row\tform\t" + re.sub(r"^selected index=\d+ ", "", last))
            chunk = key("ret", r"\[UI_LIST\]", 10)
            opened = screens(chunk)
            check("edition: Enter opens the pick list", bool(opened) and opened[-1] == "list Edition", str(opened))
            shot("edition-picker")
            for _ in range(4):
                monitor.key("down", 0.35)
            chunk = key("ret", r"\[UI_FORM\] changed", 10)
            picked = "label=Edition value=Pro" in "\n".join(forms(chunk))
            check("edition: Pro picked from the list", picked, "\n".join(forms(chunk))[-300:])
            golden.append("edition-pick\tform\t" + ("Pro" if picked else "-"))
            # The last option types on the keyboard.
            key("ret", r"\[UI_LIST\]", 10)
            key("end", None)
            chunk = key("ret", r"\[UI_FORM\] edit", 10)
            check("edition: Type manually opens the keyboard", "[UI_FORM] edit" in chunk and "label=Edition" in chunk, chunk[-300:])
            type_text("Pro N")
            key("ret", r"\[UI_FORM\]", 5)
            values = "\n".join(forms(serial.text()))
            check("edition: typed value shown", "label=Edition value=Pro N" in values, values[-300:])
            shot("edition-typed")
            chunk = key("delete", r"\[UI_FORM\] changed", 8)
            check("edition: Y/Del goes back to Setup asks", "label=Edition value=(Setup asks)" in "\n".join(forms(chunk)), "\n".join(forms(chunk))[-300:])
            chunk = key("f2", r"\[UI_FORM\] edit", 8)
            check("edition: X/F2 opens the keyboard", "[UI_FORM] edit" in chunk, chunk[-300:])
            type_text("Home")
            key("ret", r"\[UI_FORM\]", 5)
            values = "\n".join(forms(serial.text()))
            typed = "label=Edition value=Home" in values
            check("edition: X/F2 typed value", typed, values[-300:])
            golden.append("edition-typed\tform\t" + ("Home" if typed else "-"))
            chunk = key("esc", r"\[UI_ROW\]", 15)
            check("edition: Esc leaves the editor without saving", f"list {ANSWER_TITLE}" in screens(chunk) and "[PROFILE] saved" not in chunk, chunk[-300:])
            key("home", r"\[UI_ROW_SELECTED\]", 8)

        # 5. Windows 10 (empty Unattended folder): the answer screen now
        # offers the profiles; Back from whatever follows the image must land
        # on the image list, not reopen it.
        key("home")
        chunk = key("down") + key("ret", r"\[UI_SCREEN\]", 8)
        seen = screens(chunk)
        if seen and seen[-1] == "list Windows 10":
            chunk = key("ret", r"\[UI_SCREEN\]", 15)
            opened = screens(chunk)
            golden.append(f"win10-open\tscreen\t{opened[-1] if opened else '-'}")
            shot("win10-next")
            if opened and opened[-1] == f"list {ANSWER_TITLE}":
                observed = rows(chunk)
                golden.append("win10-answer\trows\t" + ",".join(r.split(" | ")[0] for r in observed))
                check("Windows 10: answer screen with manual and add rows", [r.split(" | ")[0] for r in observed] == ["no_answer", "add"], str(observed))
                edition_flow()
                chunk = key("esc", r"\[UI_SCREEN\]")
                seen = screens(chunk)
                check("Windows 10: Back from the answer screen", bool(seen) and seen[-1] in ("list Windows 10", "list Boot method"), str(seen))
                golden.append(f"win10-back\tscreen\t{seen[-1] if seen else '-'}")
            elif opened and opened[-1].startswith("summary"):
                chunk = key("esc", r"\[UI_SCREEN\]")
                seen = screens(chunk)
                check("Windows 10: Back from the summary returns to the image list", bool(seen) and seen[-1] == "list Windows 10", str(seen))
                golden.append(f"win10-back\tscreen\t{seen[-1] if seen else '-'}")
            elif opened and opened[-1] == "list Boot method":
                # Several methods: Back from the summary still returns to the
                # method list (the answer screen is skipped, no files).
                chunk = key("ret", r"\[UI_SCREEN\]", 15)
                nxt = screens(chunk)
                golden.append(f"win10-method\tscreen\t{nxt[-1] if nxt else '-'}")
                if nxt and nxt[-1] == f"list {ANSWER_TITLE}":
                    observed = rows(chunk)
                    golden.append("win10-answer\trows\t" + ",".join(r.split(" | ")[0] for r in observed))
                    check("Windows 10: answer screen with manual and add rows", [r.split(" | ")[0] for r in observed] == ["no_answer", "add"], str(observed))
                    edition_flow()
                    chunk = key("ret", r"\[UI_SCREEN\] summary", 15)
                    nxt = screens(chunk)
                    golden.append(f"win10-summary\tscreen\t{nxt[-1] if nxt else '-'}")
                    chunk = key("esc", r"\[UI_SCREEN\]")
                    seen = screens(chunk)
                    check("Windows 10: Back from the summary returns to the answer screen", bool(seen) and seen[-1] == f"list {ANSWER_TITLE}", str(seen))
                    golden.append(f"win10-back-summary\tscreen\t{seen[-1] if seen else '-'}")
                    chunk = key("esc", r"\[UI_SCREEN\]")
                    seen = screens(chunk)
                    check("Windows 10: Back from the answer screen returns to the method list", bool(seen) and seen[-1] == "list Boot method", str(seen))
                    golden.append(f"win10-back\tscreen\t{seen[-1] if seen else '-'}")
                    chunk = key("esc", r"\[UI_SCREEN\]")
                    seen = screens(chunk)
                    check("Windows 10: Back from the methods returns to the image list", bool(seen) and seen[-1] == "list Windows 10", str(seen))
                    golden.append(f"win10-back2\tscreen\t{seen[-1] if seen else '-'}")
                elif nxt and nxt[-1].startswith("summary"):
                    chunk = key("esc", r"\[UI_SCREEN\]")
                    seen = screens(chunk)
                    check("Windows 10: Back from the summary returns to the method list", bool(seen) and seen[-1] == "list Boot method", str(seen))
                    golden.append(f"win10-back\tscreen\t{seen[-1] if seen else '-'}")
                    chunk = key("esc", r"\[UI_SCREEN\]")
                    seen = screens(chunk)
                    check("Windows 10: Back from the methods returns to the image list", bool(seen) and seen[-1] == "list Windows 10", str(seen))
                    golden.append(f"win10-back2\tscreen\t{seen[-1] if seen else '-'}")
        else:
            golden.append(f"win10-open\tscreen\tnot reached {seen}")

        # 6. Tools -> Theme -> Create or edit a theme (docs/menu-themes.md):
        # name, accent colour, a contrast failure that blocks Save, then Save.
        for _ in range(4):
            key("esc")
        key("left")
        chunk = key("ret", r"\[UI_SCREEN\] list", 10)
        check("themes: Utilities list", "list Utilities" in screens(chunk), str(screens(chunk)))
        monitor.key("down", 0.4)
        monitor.key("down", 0.4)
        chunk = key("ret", r"\[UI_SCREEN\] list", 10)
        check("themes: Theme page", "list Theme" in screens(chunk), str(screens(chunk)))
        monitor.key("home", 0.5)
        chunk = key("ret", r"\[UI_SCREEN\] form", 15)
        check("themes: editor opens", "form Theme editor" in screens(chunk), str(screens(chunk)))
        golden.append(f"theme-editor\tscreen\t{screens(chunk)[-1] if screens(chunk) else '-'}")
        shot("theme-editor")
        key("ret", r"\[UI_FORM\] edit", 8)
        type_text("mine")
        key("ret", r"\[UI_FORM\]", 5)
        monitor.key("down", 0.4)
        monitor.key("down", 0.4)
        for _ in range(8):
            monitor.key("right", 0.4)
        chunk = key("down", r"\[UI_FORM\] selected", 8)
        values = "\n".join(forms(serial.text()))
        check("themes: element Accent chosen", "label=Element value=Accent\n" in values + "\n" or "label=Element value=Accent" in values, values[-400:])

        def set_colour(hex_value: str) -> str:
            key("ret", r"\[UI_FORM\] edit", 8)
            for _ in range(7):
                monitor.key("backspace", 0.3)
            type_text(hex_value)
            return key("ret", r"\[UI_FORM\]", 5)

        def last_contrast() -> str:
            found = re.findall(r"\[THEME_EDIT\] contrast ([^\r\n]*)", serial.text())
            return found[-1].strip() if found else ""

        chunk = set_colour("#101923")
        check("themes: an accent like the panels breaks a contrast rule", last_contrast() not in ("", "ok"), last_contrast())
        golden.append(f"theme-editor\tcontrast\t{last_contrast()}")
        shot("theme-contrast-bad")
        key("end", None)
        monitor.key("up", 0.5)
        chunk = key("ret", r"\[UI_SCREEN\]", 10)
        check("themes: Save refused while a rule fails", "[THEME_EDIT] saved" not in serial.text(), "")
        key("ret", r"\[UI_SCREEN\] form", 10)  # dismiss the notice
        monitor.key("home", 0.5)
        for _ in range(3):
            monitor.key("down", 0.4)
        chunk = set_colour("#FF9E40")
        check("themes: contrast ok again", last_contrast() == "ok", last_contrast())
        shot("theme-contrast-ok")
        key("end", None)
        monitor.key("up", 0.5)
        chunk = key("ret", r"\[THEME_EDIT\] saved", 15)
        check("themes: saved on the ESP", "[THEME_EDIT] saved mine" in chunk, chunk[-300:])
        golden.append("theme-editor\tsaved\t" + ("mine" if "[THEME_EDIT] saved mine" in chunk else "-"))
        shot("theme-saved")
        chunk = key("ret", r"\[UI_SCREEN\] list", 10)
        check("themes: back on the Theme page", "list Theme" in screens(chunk), str(screens(chunk)))
        shot("theme-page-after")
        try:
            monitor.command("quit")
        except ConnectionError:
            pass
    finally:
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.copyfile(serial_path, out / "serial-answer-screen.log") if serial_path.exists() else None
    return golden


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--golden", type=Path, required=True)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    observed = run(args.disk, args.out)
    text = "# UEFI answer-file screen (answer-profile manager) and theme editor click-through (tools/boot_answer_screen_qemu.py), language en\n" + "\n".join(observed) + "\n"
    (args.out / "uefi_answer_screen.tsv").write_text(text, encoding="utf-8", newline="\n")
    if args.update:
        args.golden.write_text(text, encoding="utf-8", newline="\n")
        print(f"[GOLDEN] wrote {args.golden}")
    else:
        expected = args.golden.read_text(encoding="utf-8") if args.golden.exists() else ""
        check("golden rows match", expected == text, f"diff {args.out / 'uefi_answer_screen.tsv'} {args.golden}")
    print("FAILED" if failures else "ALL PASS", len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
