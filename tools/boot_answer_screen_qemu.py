#!/usr/bin/env python3
"""Click through the XP answer-file screen of the USOS UEFI menu in QEMU/OVMF.

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
            check(f"back ({how}) does not reopen the answer screen", f"list {ANSWER_TITLE}" not in seen, str(seen))
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
        check("three rows: manual, usos-xp.ini, .sif", [r.split(" | ")[0] for r in observed] == ["xp_manual", "xp_settings", "file"], str(observed))
        check("manual installation row always present", bool(observed) and observed[0] == "xp_manual | No answer file (manual installation)", str(observed))
        check("usos-xp.ini row selected by default", state == (1, 3), str(state))
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

        # 4. Image list -> Esc -> systems list.
        chunk = key("esc", r"\[UI_SCREEN\]")
        seen = screens(chunk)
        check("image list Esc returns to the systems", bool(seen) and seen[-1] == systems_title, f"{seen} vs {systems_title}")
        golden.append(f"images-esc\tscreen\t{seen[-1] if seen else '-'}")
        shot("systems")

        # 5. The same pattern without an answer screen: Windows 10 (empty
        # Unattended folder, one runnable UEFI method). Back from whatever
        # follows the image must land on the image list, not reopen it.
        key("home")
        chunk = key("down") + key("ret", r"\[UI_SCREEN\]", 8)
        seen = screens(chunk)
        if seen and seen[-1] == "list Windows 10":
            chunk = key("ret", r"\[UI_SCREEN\]", 15)
            opened = screens(chunk)
            golden.append(f"win10-open\tscreen\t{opened[-1] if opened else '-'}")
            shot("win10-next")
            if opened and opened[-1].startswith("summary"):
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
                if nxt and nxt[-1].startswith("summary"):
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
    text = "# UEFI XP answer-file screen click-through (tools/boot_answer_screen_qemu.py), language en\n" + "\n".join(observed) + "\n"
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
