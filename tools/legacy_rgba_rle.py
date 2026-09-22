"""Lossless pixel RLE used by the small Legacy BIOS icon decoder."""


def _encode_runs(data: bytes) -> bytes:
    if len(data) % 4:
        raise ValueError('RGBA input must contain complete pixels')
    pixels = [data[i:i + 4] for i in range(0, len(data), 4)]
    result = bytearray()
    cursor = 0
    while cursor < len(pixels):
        run = 1
        while run < 128 and cursor + run < len(pixels) and pixels[cursor + run] == pixels[cursor]:
            run += 1
        if run > 1:
            result.append(0x80 | (run - 1))
            result.extend(pixels[cursor])
            cursor += run
            continue
        opaque = 0
        while opaque < 128 and cursor + opaque < len(pixels) and pixels[cursor + opaque][3] == 255:
            if cursor + opaque + 1 < len(pixels) and pixels[cursor + opaque] == pixels[cursor + opaque + 1]:
                break
            opaque += 1
        if opaque >= 2:
            result.extend((0x7f, opaque - 1))
            result.extend(b''.join(pixel[:3] for pixel in pixels[cursor:cursor + opaque]))
            cursor += opaque
            continue
        start = cursor
        cursor += 1
        while cursor - start < 127 and cursor < len(pixels):
            if cursor + 1 < len(pixels) and pixels[cursor] == pixels[cursor + 1]:
                break
            if cursor + 1 < len(pixels) and pixels[cursor][3] == 255 and pixels[cursor + 1][3] == 255:
                break
            cursor += 1
        result.append(cursor - start - 1)
        result.extend(b''.join(pixels[start:cursor]))
    return bytes(result)


def encode(data: bytes) -> bytes:
    """Keep repeated rows/pixel sequences once; decoded RGBA stays identical."""
    if len(data) % 4:
        raise ValueError('RGBA input must contain complete pixels')
    pixels = [data[i:i + 4] for i in range(0, len(data), 4)]
    seen = {}
    result = bytearray()
    cursor = start = 0
    while cursor < len(pixels):
        key = tuple(pixels[cursor:cursor + 3])
        best = distance = 0
        for previous in seen.get(key, ()):
            if cursor - previous > 65535:
                continue
            length = 3
            while length < 130 and cursor + length < len(pixels) and pixels[previous + length] == pixels[cursor + length]:
                length += 1
            if length > best:
                best, distance = length, cursor - previous
        if best >= 3 and cursor + best <= len(pixels):
            result.extend(_encode_runs(data[start * 4:cursor * 4]))
            result.extend((0x7f, 0x80 | (best - 3), distance & 255, distance >> 8))
            advance = best
        else:
            advance = 1
        for index in range(cursor, cursor + advance):
            sequence = tuple(pixels[index:index + 3])
            positions = seen.setdefault(sequence, [])
            positions.append(index)
            if len(positions) > 16:
                positions.pop(0)
        cursor += advance
        if best >= 3:
            start = cursor
    result.extend(_encode_runs(data[start * 4:]))
    plain = _encode_runs(data)
    return bytes(result) if len(result) < len(plain) else plain
