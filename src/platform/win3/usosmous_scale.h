/*
 * usosmous_scale.h - pointer speed scaling for USOSMOUS.DRV
 * (src/platform/win3/usosmous.c).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Plain C (no Windows headers, 16-bit int arithmetic only, no long
 * division helper of the C runtime) so the host test
 * tools/tests/legacy_bios/test_usosmous_scale.py compiles it unchanged.
 *
 * SeaBIOS turns a USB boot-protocol mouse report into PS/2 packets with the
 * report's deltas unchanged; a gaming mouse (Logitech G502: up to 1000 Hz,
 * high DPI) gives counts many times larger than a PS/2 mouse, and the
 * pointer flies. The driver therefore scales every movement it hands to
 * USER by Multiplier/Divisor (SYSTEM.INI [usosmous] Multiplier=, Divisor=;
 * defaults 1 and 2). What a division leaves over is kept per axis and added
 * to the next movement, so slow movements still move the pointer (one count
 * per poll at divisor 2 moves one pixel every second poll) instead of being
 * lost; the remainder is dropped when the direction reverses, so a turn
 * does not lag. USER then applies the Control Panel speed and acceleration
 * (MouseSpeed / MouseThreshold1/2) to these values as for any mouse.
 */

#define SCALE_MUL_DEFAULT  1
#define SCALE_DIV_DEFAULT  2
#define SCALE_MUL_MAX      4
#define SCALE_DIV_MAX      16
/* Clamp before scaling: |raw| * SCALE_MUL_MAX + |rest| stays below 32767. */
#define SCALE_RAW_MAX      4096

typedef struct {
    int mul, div;
    int rest_x, rest_y;
} SCALE;

/* Out-of-range settings fall back to the limits (0 or less: the default). */
static void scale_init(SCALE *s, int mul, int div)
{
    if (mul <= 0) mul = SCALE_MUL_DEFAULT;
    if (mul > SCALE_MUL_MAX) mul = SCALE_MUL_MAX;
    if (div <= 0) div = SCALE_DIV_DEFAULT;
    if (div > SCALE_DIV_MAX) div = SCALE_DIV_MAX;
    s->mul = mul;
    s->div = div;
    s->rest_x = s->rest_y = 0;
}

static int scale_axis(const SCALE *s, int raw, int *rest)
{
    int total, out;
    if (raw > SCALE_RAW_MAX) raw = SCALE_RAW_MAX;
    if (raw < -SCALE_RAW_MAX) raw = -SCALE_RAW_MAX;
    if ((raw > 0 && *rest < 0) || (raw < 0 && *rest > 0)) *rest = 0;
    total = raw * s->mul + *rest;
    out = total / s->div;           /* C: rounds toward zero, rest keeps the sign */
    *rest = total - out * s->div;
    return out;
}

/* Scales one movement (*dx, *dy) in place. */
static void scale_move(SCALE *s, int *dx, int *dy)
{
    *dx = scale_axis(s, *dx, &s->rest_x);
    *dy = scale_axis(s, *dy, &s->rest_y);
}
