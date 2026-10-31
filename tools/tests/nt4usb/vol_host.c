/*
 * Host harness for the volume publishing code of tools/nt4/usosusb/src/usosusb.c
 * (tools/tests/test_nt4_usosusb.py). The test cuts these pieces out of the
 * driver source and includes them here as USOSUSB_PIECES:
 *   le32, is_boot_sector, fs_kind, fs_name, nt4_fs_ok (NT4 build) and the
 *   block between "volumes: begin" and "volumes: end" of msc_attach.
 * The stick is a disk image file (argv[1]); scsi_rw reads it, vol_create,
 * gpt_volumes and diag_add print what the driver would do.
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char UCHAR;
typedef unsigned short USHORT;
typedef unsigned int ULONG;
typedef unsigned short WCHAR;
typedef unsigned long long ULONG_PTR;
typedef long NTSTATUS;
#define NT_SUCCESS(s) ((s) >= 0)
#define STATUS_SUCCESS 0
#define STATUS_IO_DEVICE_ERROR ((NTSTATUS)-1)

typedef struct _DEV {
    ULONG blocks;
    UCHAR port;
} DEV;

static UCHAR *g_img;
static ULONG g_imgsecs;
static UCHAR g_bva[0x10000];
static unsigned g_reads;

static size_t RtlCompareMemory(const void *a, const void *b, size_t n)
{
    size_t i;
    for (i = 0; i < n && ((const UCHAR *)a)[i] == ((const UCHAR *)b)[i]; i++)
        ;
    return i;
}
#define RtlCopyMemory(d, s, n) memcpy((d), (s), (n))

static NTSTATUS scsi_rw(DEV *d, int wr, ULONG lba, ULONG c)
{
    (void)d;
    if (wr || c > 128 || lba + c > g_imgsecs)
        return STATUS_IO_DEVICE_ERROR;
    memcpy(g_bva, g_img + (size_t)lba * 512, (size_t)c * 512);
    g_reads++;
    return STATUS_SUCCESS;
}

static void wput(const WCHAR *w)
{
    while (*w)
        putchar((char)*w++);
}

/* only the formats the volume block uses: %u, %s (wide) and plain text */
static void diag_add(const WCHAR *fmt, ULONG_PTR a, ULONG_PTR b, ULONG_PTR c, ULONG_PTR d)
{
    ULONG_PTR args[4];
    int k = 0;
    args[0] = a; args[1] = b; args[2] = c; args[3] = d;
    printf("diag ");
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            putchar((char)*fmt);
            continue;
        }
        fmt++;
        if (*fmt == 'u')
            printf("%u", (unsigned)args[k++]);
        else if (*fmt == 's')
            wput((const WCHAR *)args[k++]);
        else if (*fmt == 'x')
            printf("%x", (unsigned)args[k++]);
        else if (fmt[0] == '0' && fmt[1] == '2' && fmt[2] == 'x') {
            printf("%02x", (unsigned)args[k++]);
            fmt += 2;
        }
    }
    putchar('\n');
}

static void vol_create(DEV *d, ULONG start, ULONG count, UCHAR ptype, UCHAR boot, ULONG sig, UCHAR fs)
{
    (void)d;
    printf("vol start=%u count=%u type=%02x boot=%02x sig=%08x fs=%u\n", start, count, ptype, boot, sig, fs);
}

static void gpt_volumes(DEV *d)
{
    (void)d;
    printf("gpt\n");
}

#include USOSUSB_PIECES

static void run(DEV *d)
{
    UCHAR *s;
    ULONG i, sig;
    if (!NT_SUCCESS(scsi_rw(d, 0, 0, 1))) {
        printf("lba0 failed\n");
        return;
    }
#include USOSUSB_BLOCK
    (void)i;
}

int main(int argc, char **argv)
{
    FILE *f;
    long n;
    DEV d;
    if (argc < 2 || !(f = fopen(argv[1], "rb")))
        return 2;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    g_img = (UCHAR *)malloc((size_t)n);
    if (!g_img || fread(g_img, 1, (size_t)n, f) != (size_t)n)
        return 2;
    fclose(f);
    g_imgsecs = (ULONG)(n / 512);
    d.blocks = argc > 2 ? (ULONG)strtoul(argv[2], NULL, 0) : g_imgsecs;
    d.port = 1;
    run(&d);
    printf("reads %u\n", g_reads);
    return 0;
}
