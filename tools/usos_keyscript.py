"""USOS key scripts for USOSKBC.COM (src/platform/bios/msdos/usoskbc.S).

Source: src/platform/bios/msdos/keys/<name>.txt, one step per line:

    wait "text"     until the text is on the text-mode screen (then 0.5 s)
    gone "text"     until the text is no longer on the screen
    gfx             until the BIOS video mode is a graphics mode
    pix X Y W H HASH [TIMEOUT]
                    until VGA mode 12h shows a picture: plane 0 of the
                    rectangle at byte column X (8 pixels each), line Y, W
                    bytes x H lines hashes to HASH (pixel_hash); then 0.5 s.
                    After TIMEOUT seconds (default 900) the script goes on
                    anyway. Pick black-and-white areas (white = all planes
                    set) away from the mouse pointer (screen centre).
    delay 2.5       seconds
    key enter       one key; modifiers as in alt+p, shift+tab, ctrl+c
    type "C:\\WIN"  one key per character
    # comment

Binary (<NAME>.KEY): "UKS1", then ops: 1 len text (wait), 5 len text (gone),
4 (gfx), 2 word ticks (delay), 3 n set-1 bytes... word BIOS key (key),
6 word offset, byte rows, byte width, dword hash, word checks (pix; one
check every 4 ticks).
The TSR appends the end op (0).

    python tools/usos_keyscript.py --out DIR      (builds every script)
"""
from pathlib import Path
import argparse, shlex, struct

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'src/platform/bios/msdos/keys'
TICKS_PER_SECOND = 18.2065
SETTLE_TICKS = 18

# name -> (set-1 make code, extended, ascii, shifted ascii)
KEYS = {
    'esc': (0x01, False, 0x1b, 0x1b), 'backspace': (0x0e, False, 0x08, 0x08), 'tab': (0x0f, False, 0x09, 0),
    'enter': (0x1c, False, 0x0d, 0x0d), 'space': (0x39, False, 0x20, 0x20),
    'up': (0x48, True, 0, 0), 'down': (0x50, True, 0, 0), 'left': (0x4b, True, 0, 0), 'right': (0x4d, True, 0, 0),
    'home': (0x47, True, 0, 0), 'end': (0x4f, True, 0, 0), 'pgup': (0x49, True, 0, 0), 'pgdn': (0x51, True, 0, 0),
    'del': (0x53, True, 0, 0), 'ins': (0x52, True, 0, 0),
}
for i in range(10):
    KEYS['f%d' % (i + 1)] = (0x3b + i, False, 0, 0)
ROWS = [(0x02, '1234567890-=', '!@#$%^&*()_+'), (0x10, 'qwertyuiop[]', 'QWERTYUIOP{}'),
        (0x1e, "asdfghjkl;'`", 'ASDFGHJKL:"~'), (0x2b, '\\zxcvbnm,./', '|ZXCVBNM<>?')]
CHARS = {}
for base, plain, shifted in ROWS:
    for i, (a, b) in enumerate(zip(plain, shifted)):
        CHARS[a] = (base + i, False)
        CHARS[b] = (base + i, True)
        if a.isalpha():
            KEYS[a] = (base + i, False, ord(a), ord(b))
        else:
            KEYS[a] = (base + i, False, ord(a), ord(b))
CHARS[' '] = (0x39, False)
MODS = {'shift': 0x2a, 'ctrl': 0x1d, 'alt': 0x38}


def key_bytes(spec: str) -> bytes:
    parts = spec.lower().split('+') if spec not in ('+',) else ['+']
    name, mods = parts[-1], parts[:-1]
    if name not in KEYS:
        raise ValueError('unknown key: ' + spec)
    make, ext, asc, sasc = KEYS[name]
    for m in mods:
        if m not in MODS:
            raise ValueError('unknown modifier: ' + spec)
    seq = bytearray()
    for m in mods:
        seq.append(MODS[m])
    seq += (b'\xe0' if ext else b'') + bytes([make])
    seq += (b'\xe0' if ext else b'') + bytes([make | 0x80])
    for m in reversed(mods):
        seq.append(MODS[m] | 0x80)
    # BIOS buffer word (no 8042): what SeaBIOS's INT 09h would store.
    if 'alt' in mods:
        word = make << 8
    elif 'ctrl' in mods:
        word = (make << 8) | ((asc & 0x1f) if asc else 0)
    elif 'shift' in mods:
        word = (make << 8) | sasc
    else:
        word = (make << 8) | asc
    return bytes([3, len(seq)]) + bytes(seq) + struct.pack('<H', word)


def char_key(ch: str) -> bytes:
    if ch not in CHARS:
        raise ValueError('cannot type: %r' % ch)
    make, shifted = CHARS[ch]
    name = [k for k, v in KEYS.items() if len(k) == 1 and v[0] == make][0] if ch != ' ' else 'space'
    return key_bytes(('shift+' if shifted else '') + name)


PIX_TICKS_PER_CHECK = 4


def pixel_hash(plane_bytes: bytes, width: int) -> int:
    """The hash USOSKBC computes for op 6 (h = rol(h, 5) xor byte), over
    the rows of `width` bytes in order."""
    h = 0
    for b in plane_bytes:
        h = ((h << 5) | (h >> 27)) & 0xffffffff
        h ^= b
    return h


def plane0_bytes(image, x: int, y: int, width: int, rows: int) -> bytes:
    """Plane-0 bytes of a 640x480 screenshot (PIL image) of a black-and-white
    area: white -> 1, black -> 0, MSB = leftmost pixel. Other colours are an
    error (their plane-0 bit depends on the driver's palette)."""
    rgb = image.convert('RGB')
    out = bytearray()
    for row in range(y, y + rows):
        for col in range(x, x + width):
            v = 0
            for bit in range(8):
                px = rgb.getpixel((col * 8 + bit, row))
                if px == (255, 255, 255):
                    v |= 0x80 >> bit
                elif px != (0, 0, 0):
                    raise ValueError(f'pixel {col * 8 + bit},{row} is {px}, not black or white')
            out.append(v)
    return bytes(out)


def compile_script(text: str) -> bytes:
    out = bytearray(b'UKS1')
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        words = shlex.split(line, posix=True) if '"' in line else line.split()
        op, args = words[0].lower(), words[1:]
        try:
            if op in ('wait', 'gone'):
                data = args[0].encode('ascii')
                if not 0 < len(data) < 80:
                    raise ValueError('text length 1..79')
                out += bytes([1 if op == 'wait' else 5, len(data)]) + data
                if op == 'wait':
                    out += bytes([2]) + struct.pack('<H', SETTLE_TICKS)
            elif op == 'gfx':
                out += bytes([4])
            elif op == 'pix':
                x, y, w, h = (int(v, 0) for v in args[:4])
                digest = int(args[4], 16)
                timeout = float(args[5]) if len(args) > 5 else 900.0
                if not (0 <= x < 80 and 0 < w <= 80 - x and 0 <= y < 480 and 0 < h <= 480 - y and h < 256):
                    raise ValueError('rectangle outside 80 x 480 bytes')
                checks = max(1, round(timeout * TICKS_PER_SECOND / PIX_TICKS_PER_CHECK))
                out += bytes([6]) + struct.pack('<HBBIH', y * 80 + x, h, w, digest, min(checks, 0xffff))
                out += bytes([2]) + struct.pack('<H', SETTLE_TICKS)
            elif op == 'delay':
                out += bytes([2]) + struct.pack('<H', max(1, round(float(args[0]) * TICKS_PER_SECOND)))
            elif op == 'key':
                for spec in args:
                    out += key_bytes(spec)
            elif op == 'type':
                for ch in args[0]:
                    out += char_key(ch)
            else:
                raise ValueError('unknown op ' + op)
        except (IndexError, ValueError) as e:
            raise ValueError(f'line {number}: {raw!r}: {e}') from None
    if len(out) >= 3072:
        raise ValueError('script too long for USOSKBC (3071 bytes)')
    return bytes(out)


def build_all(out: Path) -> list:
    built = []
    for src in sorted(SOURCES.glob('*.txt')):
        data = compile_script(src.read_text(encoding='ascii'))
        target = out / (src.stem.upper() + '.KEY')
        target.write_bytes(data)
        built.append(target)
    return built


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, default=ROOT / 'zig-out/dos-native/msdos')
    p.add_argument('--hash', nargs=5, metavar=('PNG', 'X', 'Y', 'W', 'H'),
                   help='print the pix hash of a rectangle of a 640x480 screenshot')
    a = p.parse_args()
    if a.hash:
        from PIL import Image
        x, y, w, h = (int(v, 0) for v in a.hash[1:])
        print('pix %d %d %d %d %08x' % (x, y, w, h, pixel_hash(plane0_bytes(Image.open(a.hash[0]), x, y, w, h), w)))
        raise SystemExit(0)
    a.out.mkdir(parents=True, exist_ok=True)
    for f in build_all(a.out):
        print(f, f.stat().st_size)
