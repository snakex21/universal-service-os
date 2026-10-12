"""Every write onto the USOS stick ESP goes through usos_stick_write.

X470 2026-10-12 (B261012-104904-642A5621): the Windows XP flow stopped at
"Detecting disks" with "cannot write Legacy XP staging status to ESP". The
read-only ESP change (640a6b1, tools/stick_write.sh) remounts /mnt/esp
read-only while a menu waits for the user, and usos_xp_menu still wrote its
traces (xp_stage_set menu-launch, menu-hardware.txt, the renderer's stderr)
under EFI/USOS-XP in that window. A write is safe in either mode only through
usos_stick_write (rw -> write -> sync -> back to ro when it was ro; a plain
pass-through when the ESP is read-write), so this test requires every write
whose target is on the ESP to use it, in every micro-Linux script and the
framebuffer renderer.

Writes recognised: > / >> redirections, cp / mv destinations, rm, mkdir,
touch, tee, ln, sfdisk/mkfs output redirection. Targets on the ESP: /mnt/esp
literals and every variable assigned (transitively) from one. A write is
accepted when the same line runs usos_stick_write, or when it sits inside a
"writer" function whose every call goes through usos_stick_write.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'tools'

SKIP_DIRS = ('tools/vendor/', 'tools/tests/', 'tools/cache/', 'tools/toolchains/')
# The helper itself.
SKIP_FILES = {'tools/stick_write.sh'}

# Writer functions: their bodies write onto the ESP; every call of them must
# go through usos_stick_write (checked below).
WRITER_FUNCTIONS = {
    'w9x_logs_to_esp',
    'xp_stage_write',
    'xp_run_logged_copy',
    'persist_legacy_xp_stop_write',
    'xp_menu_trace_write',
    'vista_csmwrap_log_write',
    'vista_disk_log_write',
    'usos_esp_append',
    'usos_esp_put',
}

# Write sites that are not onto the stick ESP although a variable name says so
# (rel path, substring of the line) with the reason.
NOT_ESP = {
}

ASSIGN = re.compile(r'(?:^|[\s;(])(?:export\s+|local\s+)?([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\'[^\']*\'|\$\{[^}]*\}[^\s;]*|[^\s;]+)')
WRITE_CMD = re.compile(r'(?:^|[\s;|&(!{])(cp|mv|rm|mkdir|touch|tee|ln|install)\s+([^;|&)]*)')
REDIRECT = re.compile(r'(?<![<>&0-9])([0-9]?)(>>?)\s*("[^"]*"|\'[^\']*\'|[^\s;|&)]+)')
FUNC = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{')


def scripts():
    for path in sorted(TOOLS.rglob('*.sh')):
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith(SKIP_DIRS) or rel in SKIP_FILES:
            continue
        yield rel, path


def code_of(line):
    stripped = line.lstrip()
    if stripped.startswith('#'):
        return ''
    # Drop trailing comments (" #" outside quotes, good enough here).
    out, quote = [], None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in '\'"':
            quote = ch
        elif ch == '#' and (i == 0 or line[i - 1] in ' \t'):
            break
        out.append(ch)
    return ''.join(out)


def logical_lines(text):
    """(first line number, joined code) with backslash continuations."""
    buf, start = '', None
    for number, raw in enumerate(text.splitlines(), 1):
        code = code_of(raw)
        if start is None:
            start = number
        if code.rstrip().endswith('\\'):
            buf += code.rstrip()[:-1] + ' '
            continue
        buf += code
        yield start, buf
        buf, start = '', None
    if buf:
        yield start, buf


def on_esp(target, esp_vars):
    if '/mnt/esp' in target:
        return True
    for var in re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', target):
        if var in esp_vars:
            return True
    return False


def write_targets(code):
    targets = []
    for _, op, target in REDIRECT.findall(code):
        if target.startswith('&') or target in ('/dev/null', '/dev/console'):
            continue
        targets.append(target)
    for cmd, rest in WRITE_CMD.findall(code):
        args = [a for a in re.findall(r'"[^"]*"|\'[^\']*\'|[^\s]+', rest) if not a.startswith('-')]
        args = [a for a in args if not re.match(r'^[0-9]?>', a)]
        if not args:
            continue
        if cmd in ('cp', 'mv', 'ln', 'install'):
            targets.append(args[-1])
        else:
            targets.extend(args)
    return targets


def function_spans(text):
    """name -> (first, last) line numbers of top-level-ish function bodies."""
    spans = {}
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = FUNC.match(line)
        if not match:
            continue
        depth, end = 0, index
        for j in range(index, len(lines)):
            code = code_of(lines[j])
            depth += code.count('{') - code.count('}')
            if depth <= 0 and j > index or (j == index and code.rstrip().endswith('}') and depth <= 0):
                end = j
                break
        else:
            end = len(lines) - 1
        spans[match.group(1)] = (index + 1, end + 1)
    return spans


LIB_REF = re.compile(r'/usr/lib/usos/((?:pipeline/(?:steps/)?)?[A-Za-z0-9_]+\.sh)')
RO_START = re.compile(r'\busos_stick_ro\b(?!\s*\(\))|stick_release\.sh\s+ro\b')
RO_END = re.compile(r'\busos_stick_rw\b(?!\s*\(\))')

# Exported across scripts (set by one, used by others).
CROSS_FILE_ESP = {'USOS_XP_ESP_DIR', 'USOS_XP_TRACE_DIR'}


def file_esp_variables(text):
    values = {}
    for _, code in logical_lines(text):
        for name, value in ASSIGN.findall(code):
            values.setdefault(name, []).append(value)
    esp = set(CROSS_FILE_ESP)
    changed = True
    while changed:
        changed = False
        for name, vals in values.items():
            if name in esp:
                continue
            for value in vals:
                if '/mnt/esp' in value or any(re.search(r'\$\{?' + re.escape(v) + r'\b', value) for v in esp):
                    esp.add(name)
                    changed = True
                    break
    return esp


def load():
    files = {}
    for rel, path in scripts():
        text = path.read_text(encoding='utf-8', errors='replace')
        lines = dict(logical_lines(text))
        files[rel] = {'text': text, 'lines': lines, 'spans': function_spans(text),
                      'esp': file_esp_variables(text)}
    functions = {}
    for rel, info in files.items():
        for name, span in info['spans'].items():
            functions.setdefault(name, []).append((rel, span))
    return files, functions


def ro_closure(files, functions):
    """(rel, line) pairs that can run while the stick ESP is read-only."""
    reach = set()
    work = []

    def add_lines(rel, first, last):
        for number in range(first, last + 1):
            if (rel, number) not in reach:
                reach.add((rel, number))
                work.append((rel, number))

    # Seeds: from each read-only remount to the matching read-write remount
    # or the end of the enclosing function.
    for rel, info in files.items():
        for number, code in info['lines'].items():
            if not RO_START.search(code) or FUNC.match(code):
                continue
            enclosing = [span for span in info['spans'].values() if span[0] < number <= span[1]]
            if rel == 'tools/stick_write.sh':
                continue
            last = min(enclosing, key=lambda s: s[1] - s[0])[1] if enclosing else max(info['lines'])
            for later in sorted(n for n in info['lines'] if number < n <= last):
                if RO_END.search(info['lines'][later]):
                    last = later
                    break
            add_lines(rel, number, last)
    seen_funcs, seen_files = set(), set()
    while work:
        rel, number = work.pop()
        code = files[rel]['lines'].get(number, '')
        if not code:
            continue
        for word in set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', code)):
            if word in functions and word not in seen_funcs:
                seen_funcs.add(word)
                for frel, (first, last) in functions[word]:
                    add_lines(frel, first, last)
        for lib in LIB_REF.findall(code):
            frel = 'tools/' + lib
            if frel in files and frel not in seen_files:
                seen_files.add(frel)
                add_lines(frel, 1, max(files[frel]['lines'] or [1]))
    return reach, seen_funcs, seen_files


def violations(only_ro=True):
    files, functions = load()
    reach, _, _ = ro_closure(files, functions)
    found = []
    for rel, info in files.items():
        writer_lines = set()
        for name in WRITER_FUNCTIONS:
            if name in info['spans']:
                first, last = info['spans'][name]
                writer_lines.update(range(first, last + 1))
        for number, code in info['lines'].items():
            if not code.strip():
                continue
            if only_ro and (rel, number) not in reach:
                continue
            hits = [t for t in write_targets(code) if on_esp(t, info['esp'])]
            if not hits:
                continue
            if 'usos_stick_write' in code or number in writer_lines:
                continue
            if any(rel == r and s in code for (r, s) in NOT_ESP):
                continue
            found.append(f'{rel}:{number}: {code.strip()}')
    return found, files, functions


class EspWritesGoThroughTheHelper(unittest.TestCase):
    def test_every_esp_write_uses_usos_stick_write(self):
        found, _, _ = violations()
        self.assertEqual(found, [], '\n' + '\n'.join(found))

    def test_esp_variables_are_recognised(self):
        files, _ = load()
        self.assertTrue({'W9X_DIR', 'request'} <= files['tools/w9x_csmwrap_prepare.sh']['esp'])
        self.assertIn('VISTA_CSMWRAP_DIR', files['tools/vista_csmwrap_prepare.sh']['esp'])
        self.assertIn('USOS_XP_TRACE_DIR', files['tools/xp_menu_ui.sh']['esp'])

    def test_read_only_closure_covers_every_flow(self):
        # The flows that wait or run long with the ESP read-only, and what
        # they call: a regression here means the closure lost a flow.
        files, functions = load()
        _, funcs, libs = ro_closure(files, functions)
        for name in ('stop', 'persist_legacy_xp_stop', 'usos_xp_choose_disk', 'usos_xp_confirm', 'xp_stage_set',
                     'w9x_phase1_run', 'nt4_vm_install', 'posready_vm_install', 'usos_stick_flush'):
            self.assertIn(name, funcs)
        for lib in ('tools/image_disk_target.sh', 'tools/nt4_csmwrap_target.sh', 'tools/posready_csmwrap_target.sh',
                    'tools/w9x_csmwrap_target.sh', 'tools/dos_csmwrap_target.sh', 'tools/xp_csmwrap_esp.sh',
                    'tools/xp_disk_overview.sh'):
            self.assertIn(lib, libs)

    def test_writer_functions_are_only_called_through_the_helper(self):
        files, _ = load()
        bad = []
        for rel, info in files.items():
            for number, code in info['lines'].items():
                for name in WRITER_FUNCTIONS:
                    if not re.search(r'(?<![A-Za-z0-9_])' + name + r'(?![A-Za-z0-9_(])', code):
                        continue
                    if re.match(r'^\s*' + name + r'\s*\(\)', code):
                        continue
                    if re.search(r'usos_stick_write\s+(?:[A-Za-z_]+=\S+\s+)*' + name + r'\b', code):
                        continue
                    if re.search(r'command -v ' + name, code):
                        continue
                    bad.append(f'{rel}:{number}: {code.strip()}')
        self.assertEqual(bad, [])

    def test_scripts_that_write_the_esp_load_the_helper(self):
        # A script run as its own process (sh script.sh) does not inherit
        # shell functions: it sources stick_write.sh itself.
        missing = []
        for rel, path in scripts():
            text = path.read_text(encoding='utf-8', errors='replace')
            if 'usos_stick_write' not in text:
                continue
            if rel in ('tools/micro_linux_init.sh',) or 'stick_write.sh' in text:
                continue
            # Sourced libraries (no shebang, functions only) rely on init.
            if not text.startswith('#!'):
                continue
            missing.append(rel)
        self.assertEqual(missing, [])

    def test_init_loads_the_helper_before_any_flow(self):
        init = (TOOLS / 'micro_linux_init.sh').read_text(encoding='utf-8')
        self.assertIn('stick_write.sh', init)
        self.assertLess(init.index('stick_write.sh'), init.index('mount -t proc proc /proc'))

    def test_renderer_never_writes_the_esp(self):
        # usos-fb-ui runs while the ESP is read-only (the menu wait); its
        # trace goes to tmpfs and usos_xp_menu appends it afterwards.
        bad = []
        for path in (ROOT / 'src' / 'platform' / 'linux').rglob('*.zig'):
            text = path.read_text(encoding='utf-8', errors='replace')
            for number, line in enumerate(text.splitlines(), 1):
                if '/mnt/esp' in line and re.search(r'CREAT|WRONLY|RDWR|createFile|writeFile', line):
                    bad.append(f'{path.relative_to(ROOT).as_posix()}:{number}')
        self.assertEqual(bad, [])




STUB_MOUNT = r'''#!/bin/sh
echo "mount $*" >> "$FAKE_LOG"
[ "$1" = -o ] || exit 1
mode=${2#remount,}
awk -v mp="$3" -v mode="$mode" '$2 == mp { sub(/^r[ow]/, mode, $4) } { print }' "$FAKE_MOUNTS" > "$FAKE_MOUNTS.new" && mv "$FAKE_MOUNTS.new" "$FAKE_MOUNTS"
# A read-only ESP: the trace directory is gone, so any write into it fails.
case "$mode" in
    ro) mv "$FAKE_ESP" "$FAKE_ESP.ro" ;;
    rw) mv "$FAKE_ESP.ro" "$FAKE_ESP" ;;
esac
'''

# The renderer stub: it must run with the ESP read-only, writes its stderr
# and its own trace (as fb_menu_trace.zig does), then selects item 1.
STUB_UI = r'''#!/bin/sh
. "$USOS_LIB_DIR/stick_write.sh"
echo "ui-mode=$(usos_stick_mode)" >> "$FAKE_LOG"
echo stub-render-stderr >&2
[ -f "$USOS_XP_MENU_TMP_TRACE" ] && echo stub-renderer-trace >> "$USOS_XP_MENU_TMP_TRACE"
echo 1
'''


class XpMenuBehaviour(unittest.TestCase):
    """usos_xp_menu with the real xp_stage_set: the ESP read-only only for the
    renderer, every trace written outside that window (X470 2026-10-12)."""

    def test_menu_traces_around_the_read_only_wait(self):
        import os
        import shutil
        import subprocess
        import tempfile
        sh = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'bin').mkdir()
            for name, body in (('mount', STUB_MOUNT), ('sync', '#!/bin/sh\nexit 0\n'), ('fake-ui', STUB_UI)):
                (tmp / 'bin' / name).write_text(body, encoding='ascii', newline='\n')
                (tmp / 'bin' / name).chmod(0o755)
            mounts = tmp / 'mounts'
            mounts.write_text('/dev/sdb1 /mnt/esp vfat rw,noatime 0 0\n', encoding='ascii', newline='\n')
            log = tmp / 'log'
            log.write_text('', encoding='ascii')
            trace = tmp / 'trace'
            trace.mkdir()
            state = tmp / 'state.txt'
            state.write_text('title=T\nitem=Disk|x\n', encoding='ascii', newline='\n')
            script = f'''
enable_emergency_input() {{ :; }}
stop() {{ echo "STOP: $1"; exit 99; }}
. "{(TOOLS / 'stick_write.sh').as_posix()}"
. "{(TOOLS / 'legacy_xp_staging.sh').as_posix()}"
. "{(TOOLS / 'xp_menu_ui.sh').as_posix()}"
usos_xp_menu "{state.as_posix()}" || exit 1
echo "result=$USOS_MENU_RESULT mode=$(usos_stick_mode)"
'''
            env = dict(os.environ, FAKE_MOUNTS=mounts.as_posix(), FAKE_LOG=log.as_posix(), FAKE_ESP=trace.as_posix(),
                       USOS_STICK_PROC_MOUNTS=mounts.as_posix(), USOS_LIB_DIR=TOOLS.as_posix(),
                       USOS_XP_TRACE_DIR=trace.as_posix(), USOS_XP_ESP_DIR=trace.as_posix(),
                       USOS_XP_MENU_RUN=tmp.as_posix(), USOS_XP_MENU_TMP_TRACE=(tmp / 'menu-trace.log').as_posix(),
                       USOS_FB_UI=(tmp / 'bin' / 'fake-ui').as_posix(),
                       PATH=(tmp / 'bin').as_posix() + os.pathsep + os.environ.get('PATH', ''))
            out = subprocess.run([sh, '-c', script], capture_output=True, text=True, env=env, timeout=120)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertIn('result=1 mode=rw', out.stdout)
            calls = log.read_text(encoding='ascii').splitlines()
            self.assertEqual(calls, ['mount -o remount,ro /mnt/esp', 'ui-mode=ro', 'mount -o remount,rw /mnt/esp'])
            events = (trace / 'menu-events.log').read_text(encoding='ascii')
            for expected in ('menu=', 'stub-render-stderr', 'stub-renderer-trace', 'menu-return=0 selected=1'):
                self.assertIn(expected, events)
            self.assertIn('phase=menu-selected', (trace / 'legacy-xp-staging-status.txt').read_text(encoding='ascii'))
            self.assertTrue((trace / 'menu-hardware.txt').exists())
            self.assertFalse((tmp / 'menu-trace.log').exists())


if __name__ == '__main__':
    unittest.main()
