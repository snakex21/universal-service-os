/* USOS one-shot BSP task-gate NMI snapshot. Own code, GPL-3.0-or-later.
 * The Microsoft files are never edited. The runtime NMI TSS entry is hooked
 * only after exact SP4 image/layout/mapping validation and an explicit v2 gate.
 * NMI path: own resident memory + local APIC reads, no Windows calls or locks.
 */
#include <ntddk.h>
#include "usos_watcher.h"
#include "usos_nmi.h"

#pragma pack(push, 1)
typedef struct { USHORT Limit; ULONG Base; } USN_TABLE;
#pragma pack(pop)

static volatile UCHAR *g_Mailbox;
static volatile UCHAR *g_MainTss;
static volatile UCHAR *g_NmiTss;
static volatile ULONG *g_Lapic;
static USHORT g_MainTr;
static ULONG g_OriginalEip, g_OriginalEsp, g_EntryFlags;
static ULONG g_NmiCr3, g_LapicPa;
static ULONG g_KBase, g_KSize, g_HBase, g_HSize;
static ULONG g_StackTop;
static volatile ULONG *g_Tick;
static volatile ULONG *g_BugData;
static volatile ULONG *g_Shared;
static volatile UCHAR *g_Pcr;
static ULONG g_StackLow, g_StackHigh, g_InitialThread, g_InitialCr3;
static ULONG g_ContextPcrReady, g_StackReady, g_FaultWindow, g_FaultReady;
static ULONG g_AcpiBase, g_AcpiReady;
__declspec(align(16)) static UCHAR g_NmiStack[16384];

#define M32(o) (*(volatile ULONG *)(g_Mailbox + (o)))
#define S32(o) (*(volatile ULONG *)(snapshot + (o)))
#define T32(o) (*(volatile ULONG *)(g_MainTss + (o)))

static BOOLEAN StackSpan(ULONG address, ULONG bytes)
{
    return !(address & 3) && g_StackHigh > g_StackLow &&
        bytes <= g_StackHigh - g_StackLow && address >= g_StackLow &&
        address <= g_StackHigh - bytes;
}

/* Exact MP SP4: dispatcher RVA 2EFEE registers scope 5548 at EBP-10,
 * builds CONTEXT at EBP-38C, and receives EXCEPTION_RECORD at EBP+8.
 * Independent validation of every dereference; no arbitrary pool pointers.
 * Retain raw records even when a control-flow check fails; validity is explicit. */
static VOID CaptureExceptions(ULONG head)
{
    ULONG frame = head, visited = 0, count = 0, base, context, record, trap, i, flags, sp;
    volatile ULONG *row, *raw, *c, *e;
    while (visited++ < 32 && count < 3 && StackSpan(frame, 20)) {
        if (*(volatile ULONG *)(frame + 4) == g_KBase + 0x60AD0 &&
            *(volatile ULONG *)(frame + 8) == g_KBase + 0x5548 &&
            frame >= g_StackLow + 0x37C && StackSpan(frame, 0x28)) {
            base = frame + 0x10; context = base - 0x38C;
            record = *(volatile ULONG *)(base + 8);
            trap = *(volatile ULONG *)(base + 0x10);
            if (StackSpan(context, 0xCC) && StackSpan(record, 0x50)) {
                c = (volatile ULONG *)context; e = (volatile ULONG *)record;
                flags = 1;
                if ((c[0] & 0x10003) == 0x10003 && c[0xBC / 4] == 8) flags |= 2;
                if (c[0xB8 / 4] == e[3] && e[4] <= 15) flags |= 4;
                sp = c[0xC4 / 4];
                if (StackSpan(sp, 12)) flags |= 8;
                raw = (volatile ULONG *)(g_Mailbox + UE_RAW + count * 0x100);
                /* 20 EXCEPTION_RECORD words plus 13 CONTEXT control/GPR words. */
                for (i = 0; i < 20; i++) raw[i] = e[i];
                raw[20] = c[0];
                for (i = 0; i < 12; i++) raw[21 + i] = c[0x9C / 4 + i];
                raw[33] = frame; raw[34] = base; raw[35] = context;
                row = (volatile ULONG *)(g_Mailbox + USN_EXCEPTION + count * 72);
                row[0] = e[0]; row[1] = e[3]; row[2] = record;
                row[3] = context; row[4] = trap; row[5] = flags;
                row[6] = c[0xB8 / 4]; row[7] = sp; row[8] = c[0xB4 / 4];
                row[9] = c[0xB0 / 4]; row[10] = c[0xAC / 4]; row[11] = c[0xA8 / 4];
                row[12] = c[0xA4 / 4]; row[13] = c[0xA0 / 4]; row[14] = c[0x9C / 4];
                if (flags & 8) for (i = 0; i < 3; i++) row[15 + i] = ((volatile ULONG *)sp)[i];
                count++;
            }
        }
        i = *(volatile ULONG *)frame;
        if (i <= frame) break;
        frame = i;
    }
    M32(UE_COUNT) = count;
}

static VOID CapturePanel(VOID)
{
    volatile ULONG *p = (volatile ULONG *)(g_Mailbox + UE_PANEL);
    volatile ULONG *d = (volatile ULONG *)(g_Mailbox + USN_DETAIL);
    volatile ULONG *irq = (volatile ULONG *)(g_Mailbox + UE_IRQ);
    volatile ULONG *r, *raw;
    ULONG count = M32(UE_COUNT), index, i, j, frame, next, last, state, valid = 0;
    if (count > 3) count = 3;
    p[0] = g_AcpiBase; p[4] = g_AcpiReady; p[5] = count;
    if (g_AcpiReady) {
        p[2] = *(volatile ULONG *)(g_AcpiBase + 0x9AAA);
        p[3] = *(volatile ULONG *)(g_AcpiBase + 0x194AC);
        if (count) {
            last = M32(USN_EXCEPTION + (count - 1) * 72 + 4);
            if (last >= g_AcpiBase && last - g_AcpiBase < 162944) p[1] = last - g_AcpiBase;
        }
    }
    /* Row 1 is IRQ evidence; stack bounds remain in DTL3. */
    for (i = 6; i < 12; i++) p[i] = 0;
    /* Display newest and oldest (if three were captured, the middle remains
       in the mailbox). EXC exposes actual exception parameters, not P3/P4. */
    for (i = 0; i < 2 && i < count; i++) {
        index = i ? count - 1 : 0;
        r = (volatile ULONG *)(g_Mailbox + USN_EXCEPTION + index * 72);
        raw = (volatile ULONG *)(g_Mailbox + UE_RAW + index * 0x100);
        p[12 + i * 18] = r[0]; p[13 + i * 18] = r[1];
        p[14 + i * 18] = raw[4]; p[15 + i * 18] = raw[5]; p[16 + i * 18] = raw[6];
        p[17 + i * 18] = r[5];
        for (j = 6; j < 18; j++) p[12 + i * 18 + j] = r[j];
    }
    if (count && (d[ND_VALID / 4] & 15) == 15) {
        frame = M32(USN_EXCEPTION + (count - 1) * 72 + 0x20);
        for (i = 0; i < 3 && StackSpan(frame, 20); i++) {
            p[48 + i * 6] = frame;
            M32(UE_ORIGINAL + i * 24) = frame;
            for (j = 0; j < 5; j++) {
                next = ((volatile ULONG *)frame)[j];
                p[49 + i * 6 + j] = next;
                M32(UE_ORIGINAL + i * 24 + 4 + j * 4) = next;
            }
            next = *(volatile ULONG *)frame;
            if (next <= frame) break;
            frame = next;
        }
    }
    if (count && g_AcpiReady && (d[ND_VALID / 4] & 15) == 15 && p[1] == 0x9AAA) {
        r = (volatile ULONG *)(g_Mailbox + USN_EXCEPTION + (count - 1) * 72);
        if (r[0] == 0xC0000005UL && r[5] == 15 && r[9] == 0) {
            valid = 1;
            if (p[50] == g_AcpiBase + 0x1CA52 && p[56] == g_AcpiBase + 0x16811 &&
                p[62] == g_AcpiBase + 0x1CDC1 && p[57] == g_AcpiBase + 0x19420 && p[63] == p[57]) {
                valid |= 2;
                state = p[58];
                if (StackSpan(state, 0x68)) {
                    valid |= 4;
                    /* Copy only the already mapped, same-thread initial stack.
                       Never follow Entry/Descriptor/PDO pointers from it. */
                    for (i = 0; i < 26; i++) irq[8 + i] = ((volatile ULONG *)state)[i];
                    p[7] = irq[2] = state; p[11] = irq[3] = p[51];
                    p[8] = irq[4] = irq[8]; p[9] = irq[5] = irq[10];
                    p[10] = irq[6] = *(volatile USHORT *)(state + 0x30);
                    if (irq[9] == 0 && irq[11] == 0 && irq[4] <= irq[5]) valid |= 8;
                }
            }
        }
    }
    p[6] = irq[1] = valid;
    irq[0] = UE_IRQ_VALUE;
    M32(UE_PANEL_MAGIC) = UE_PANEL_VALUE;
}

/* All addresses below were mapped and checked before the NMI task was armed.
   Never follow a frame into another stack, pool, user VA or MMIO. */
static VOID CaptureDetail(volatile UCHAR *snapshot)
{
    volatile ULONG *detail = (volatile ULONG *)(g_Mailbox + USN_DETAIL);
    ULONG valid = 0, frame, next, count, i, fault;
#define D32(o) detail[(o) / 4]
    D32(ND_STACK_LO) = g_StackLow; D32(ND_STACK_HI) = g_StackHigh;
    D32(ND_INIT_THREAD) = g_InitialThread; D32(ND_INIT_CR3) = g_InitialCr3;
    D32(ND_CR3) = S32(NS_CR3); D32(ND_ESP) = S32(NS_ESP); D32(ND_EBP) = S32(NS_EBP);
    fault = S32(NS_BUGCHECK + 8); D32(ND_FAULT) = fault;
    if (g_FaultReady) {
        valid |= 64;
        if (!(fault & 3) && fault >= g_FaultWindow && fault <= g_FaultWindow + 256 - 32) {
            for (i = 0; i < 8; i++) D32(ND_FAULT_WORDS + i * 4) = ((volatile ULONG *)fault)[i];
            valid |= 128;
        }
    }
    if (g_StackReady) {
        valid |= 1;
        D32(ND_THREAD) = *(volatile ULONG *)(g_Pcr + 0x124);
        D32(ND_FS0) = *(volatile ULONG *)g_Pcr;
        if (D32(ND_THREAD) == g_InitialThread) valid |= 2;
        if (D32(ND_CR3) == g_InitialCr3) valid |= 4;
        if ((valid & 6) == 6 && StackSpan(D32(ND_ESP), 4)) {
            valid |= 8;
            count = (g_StackHigh - D32(ND_ESP)) / 4;
            if (count > 16) count = 16;
            for (i = 0; i < count; i++) D32(ND_TOP + i * 4) = ((volatile ULONG *)D32(ND_ESP))[i];
            D32(ND_TOP_COUNT) = count;
            for (i = 0; i < 8; i++) D32(ND_HIGH + i * 4) = ((volatile ULONG *)(g_StackHigh - 32))[i];
            frame = D32(ND_EBP); count = 0;
            while (count < 16 && StackSpan(frame, 20)) {
                D32(ND_FRAMES + count * 24) = frame;
                for (i = 0; i < 5; i++) D32(ND_FRAMES + count * 24 + 4 + i * 4) = ((volatile ULONG *)frame)[i];
                count++; next = *(volatile ULONG *)frame;
                if (next <= frame) break;
                frame = next;
            }
            D32(ND_FRAME_COUNT) = count; if (count) valid |= 16;
            frame = D32(ND_FS0); count = 0;
            while (count < 8 && StackSpan(frame, 20)) {
                D32(ND_SEH + count * 24) = frame;
                for (i = 0; i < 5; i++) D32(ND_SEH + count * 24 + 4 + i * 4) = ((volatile ULONG *)frame)[i];
                count++; next = *(volatile ULONG *)frame;
                if (next <= frame) break;
                frame = next;
            }
            D32(ND_SEH_COUNT) = count; if (count) valid |= 32;
            if (M32(USN_KVARIANT) == 2) CaptureExceptions(D32(ND_FS0));
        }
    }
    D32(ND_VALID) = valid;
    M32(UE_MAGIC) = UE_MAGIC_VALUE;
    detail[0] = USN_DETAIL_MAGIC;
#undef D32
}

static BOOLEAN Span(ULONG address, ULONG size)
{
    ULONG last, page;
    if (address < 0x80000000UL || !size || address + size < address) return FALSE;
    last = (address + size - 1) & ~4095UL;
    for (page = address & ~4095UL;; page += 4096) {
        if (!MmIsAddressValid((PVOID)page)) return FALSE;
        if (page == last) return TRUE;
    }
}

static ULONG Image(ULONG address)
{
    ULONG p = address & ~4095UL, i, nt;
    for (i = 0; i < 1024 && p >= 0x80000000UL; i++, p -= 4096) {
        if (!Span(p, 64)) return 0;
        if (*(PUSHORT)p != 0x5A4D) continue;
        nt = *(PULONG)(p + 0x3C);
        if (nt < 64 || nt > 2048 || !Span(p + nt, 0xF8)) continue;
        if (*(PULONG)(p + nt) == 0x4550 && address - p < *(PULONG)(p + nt + 0x50)) return p;
    }
    return 0;
}

static ULONG Descriptor(ULONG table, USHORT limit, USHORT selector, UCHAR type)
{
    PUCHAR p;
    ULONG size, base;
    if ((selector & 7) || selector > limit || limit - selector < 7 || !Span(table + selector, 8)) return 0;
    p = (PUCHAR)(table + selector);
    if ((p[5] & 0xFF) != type || (p[6] & 0x80)) return 0;
    size = *(PUSHORT)p | ((ULONG)(p[6] & 15) << 16);
    base = *(PUSHORT)(p + 2) | ((ULONG)p[4] << 16) | ((ULONG)p[7] << 24);
    if (size < 103 || !Span(base, 104)) return 0;
    return base;
}

static BOOLEAN FlatData(ULONG table, USHORT limit, USHORT selector)
{
    PUCHAR p;
    USHORT index = selector & ~7;
    if ((selector != 0x10 && selector != 0x23) || index > limit || limit - index < 7 || !Span(table + index, 8)) return FALSE;
    p = (PUCHAR)(table + index);
    return *(PUSHORT)p == 0xFFFF && *(PUSHORT)(p + 2) == 0 && p[4] == 0 && p[7] == 0 &&
        (p[5] & 0x9E) == 0x92 && (p[5] >> 5 & 3) >= (selector & 3) && (p[6] & 0xCF) == 0xCF;
}

static ULONG PhysicalWord(ULONG address)
{
    PHYSICAL_ADDRESS pa;
    PULONG p;
    ULONG value;
    pa.QuadPart = address & ~4095UL;
    p = (PULONG)MmMapIoSpace(pa, 4096, MmCached);
    if (p == NULL) return 0;
    value = p[(address & 4095) / 4];
    MmUnmapIoSpace(p, 4096);
    return value;
}

/* Pre-arm only. Verify every resident page under the NMI task's own CR3. */
static BOOLEAN CommonMapping(ULONG address, ULONG size)
{
    ULONG end, page, pde, pte, physical;
    PHYSICAL_ADDRESS current;
    if (!Span(address, size)) return FALSE;
    end = (address + size - 1) & ~4095UL;
    for (page = address & ~4095UL;; page += 4096) {
        pde = PhysicalWord((g_NmiCr3 & ~4095UL) + (page >> 22) * 4);
        if (!(pde & 1)) return FALSE;
        if (pde & 128) {
            if (pde & 0x001FE000UL) return FALSE; /* PSE-36, never truncate */
            physical = (pde & 0xFFC00000UL) | (page & 0x003FF000UL);
        } else {
            pte = PhysicalWord((pde & ~4095UL) + ((page >> 12) & 1023) * 4);
            if (!(pte & 1)) return FALSE;
            physical = pte & ~4095UL;
        }
        current = MmGetPhysicalAddress((PVOID)page);
        if (current.HighPart || current.LowPart != physical) return FALSE;
        if (page == end) return TRUE;
    }
}

/* Pre-arm only. The observed X470 fault lies in the boot-driver VA region.
 * Match the exact retail ACPI image, verify its code and resident .data map.
 * Absence simply leaves this optional evidence unavailable. Never follow
 * the arbiter's runtime pool pointer; copy only its numeric value in NMI. */
static VOID FindAcpi(VOID)
{
    ULONG base, offset, nt;
    for (base = 0xBFE00000UL; base < 0xC0000000UL; base += 4096) {
        if (!Span(base, 64) || *(volatile USHORT *)base != 0x5A4D) continue;
        offset = *(volatile ULONG *)(base + 0x3C);
        if (offset < 64 || offset > 2048 || !Span(base + offset, 0xF8)) continue;
        nt = base + offset;
        if (*(volatile ULONG *)nt != 0x4550 || *(volatile USHORT *)(nt + 4) != 0x14C ||
            *(volatile ULONG *)(nt + 8) != 1042659862UL ||
            *(volatile ULONG *)(nt + 0x58) != 187639UL ||
            *(volatile ULONG *)(nt + 0x50) != 162944UL) continue;
        if (!CommonMapping(base + 0x9AAA, 8) || !CommonMapping(base + 0x194AC, 4)) continue;
        if (*(volatile ULONG *)(base + 0x9AAA) != 0x3B1050FFUL ||
            *(volatile ULONG *)(base + 0x9AAE) != 0xB80A7DC7UL) continue;
        g_AcpiBase = base; g_AcpiReady = 1; return;
    }
}

static BOOLEAN ResidentImage(ULONG base)
{
    ULONG nt = base + *(PULONG)(base + 0x3C), section, count, i, va, size;
    count = *(PUSHORT)(nt + 6);
    section = nt + 24 + *(PUSHORT)(nt + 20);
    if (!count || count > 32 || !Span(section, count * 40)) return FALSE;
    for (i = 0; i < count; i++, section += 40) {
        if (*(PULONG)(section + 36) & 0x02000000UL) continue; /* discardable */
        va = *(PULONG)(section + 12); size = *(PULONG)(section + 8);
        if (size && !CommonMapping(base + va, size)) return FALSE;
    }
    return TRUE;
}

static ULONG HalImage(ULONG kernel)
{
    ULONG nt = kernel + *(PULONG)(kernel + 0x3C), imports, i, name, thunk;
    PUCHAR text;
    imports = *(PULONG)(nt + 0x80);
    if (!imports) return 0;
    for (i = 0; i < 64; i++) {
        ULONG descriptor = kernel + imports + i * 20;
        if (!Span(descriptor, 20)) return 0;
        name = *(PULONG)(descriptor + 12);
        if (!name) return 0;
        if (!Span(kernel + name, 8)) return 0;
        text = (PUCHAR)(kernel + name);
        if ((text[0] | 32) != 'h' || (text[1] | 32) != 'a' || (text[2] | 32) != 'l' || text[3] != '.') continue;
        thunk = kernel + *(PULONG)(descriptor + 16);
        return Span(thunk, 4) ? Image(*(PULONG)thunk) : 0;
    }
    return 0;
}

#ifdef USOS_NMI_LAB
/* A second fault from an exception filter leaves the original dispatcher
 * below it. Disposable VM LAB=9/10 preserve distinct UD2/access faults. */
#if USOS_NMI_LAB == 9 || USOS_NMI_LAB == 10
static ULONG g_LabNestedRaised;
__declspec(naked) static VOID FirstIllegal(VOID)
{
    __asm {
#if USOS_NMI_LAB == 9
        _emit 0x0F
        _emit 0x0B
#else
        xor eax, eax
        mov eax, [eax + 10h]
#endif
        ret
    }
}

static LONG NestedFilter(VOID)
{
    if (!g_LabNestedRaised) {
        g_LabNestedRaised = 1;
        ((VOID (NTAPI *)(VOID))(g_KBase + 0x6530))();
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static VOID NestedFault(VOID)
{
    __try { FirstIllegal(); }
    __except(NestedFilter()) { /* unreachable in the intended lab */ }
}
#endif
static VOID LabText(PCSTR text)
{
    while (*text) { UCHAR c = (UCHAR)*text++; __asm mov al, c __asm out 0E9h, al }
}
#else
#define LabText(s) ((void)0)
#endif

/* Returns 1 only for our outstanding one-shot request. Everything else chains. */
static ULONG __cdecl Capture(VOID)
{
    volatile UCHAR *snapshot;
    ULONG valid = 0, i, a, d;
    if (M32(USN_REQUEST) != USN_TOKEN || M32(USN_ACK) == USN_TOKEN) {
        /* The stock task return stores its own next EIP in this TSS. Withdraw
           readiness before chaining, so firmware cannot send a later request
           to an entry which the stock handler has since reclaimed. */
        M32(USN_READY) = 0;
        if (M32(USN_ACK) != USN_TOKEN) M32(USN_REJECT) = 13;
        if (M32(USN_UNSOL) != USN_EVENT_MAGIC) {
            M32(USN_UNSOL_TR) = *(volatile USHORT *)g_NmiTss;
            if (*(volatile USHORT *)g_NmiTss == g_MainTr) {
                M32(USN_UNSOL_EIP) = T32(0x20);
                M32(USN_UNSOL_FLAGS) = T32(0x24);
                M32(USN_UNSOL_TICK) = *g_Tick;
                M32(USN_UNSOL_VALID) = 1;
            }
            M32(USN_UNSOL_COUNT) = 1;
            M32(USN_UNSOL) = USN_EVENT_MAGIC;
        }
        LabText("USN_CHAIN\n");
        return 0;
    }
    snapshot = g_Mailbox + USN_SNAPSHOT;
    S32(0) = USN_SNAP_MAGIC; S32(4) = USN_SNAPSHOT_SIZE;
    S32(NS_PARTIAL) = 1; /* RTE/RTC/indexed I/O intentionally absent */
    S32(NS_BACKLINK) = *(volatile USHORT *)g_NmiTss;
    S32(NS_NMI_CR3) = g_NmiCr3;
    if (*(volatile USHORT *)g_NmiTss == g_MainTr) {
        S32(NS_EIP) = T32(0x20); S32(NS_FLAGS) = T32(0x24);
        S32(NS_ESP) = T32(0x38); S32(NS_CR3) = T32(0x1C);
        S32(NS_CS) = *(volatile USHORT *)(g_MainTss + 0x4C);
        S32(NS_SS) = *(volatile USHORT *)(g_MainTss + 0x50);
        S32(NS_EAX) = T32(0x28); S32(NS_ECX) = T32(0x2C);
        S32(NS_EDX) = T32(0x30); S32(NS_EBX) = T32(0x34);
        S32(NS_EBP) = T32(0x3C); S32(NS_ESI) = T32(0x40); S32(NS_EDI) = T32(0x44);
        valid |= 1;
    } else M32(USN_CAPTURE_REASON) = 1;
    __asm rdtsc __asm mov a, eax __asm mov d, edx
    S32(NS_TSC) = a; S32(NS_TSC + 4) = d;
    __asm mov ecx, 01Bh __asm rdmsr __asm mov a, eax __asm mov d, edx
    S32(NS_APIC_BASE) = a; S32(NS_APIC_BASE + 4) = d;
    if (!d && (a & 0xC00) == 0x800 && (a & 0xFFFFF000UL) == g_LapicPa) {
        S32(NS_ID) = g_Lapic[0x20 / 4];
        S32(NS_TPR) = g_Lapic[0x80 / 4]; S32(NS_PPR) = g_Lapic[0xA0 / 4];
        S32(NS_SVR) = g_Lapic[0xF0 / 4]; S32(NS_LDR) = g_Lapic[0xD0 / 4];
        S32(NS_DFR) = g_Lapic[0xE0 / 4]; S32(NS_LVTT) = g_Lapic[0x320 / 4];
        S32(NS_LINT0) = g_Lapic[0x350 / 4]; S32(NS_LINT1) = g_Lapic[0x360 / 4];
        for (i = 0; i < 8; i++) {
            S32(NS_ISR + i * 4) = g_Lapic[(0x100 + i * 16) / 4];
            S32(NS_IRR + i * 4) = g_Lapic[(0x200 + i * 16) / 4];
            S32(NS_TMR + i * 4) = g_Lapic[(0x180 + i * 16) / 4];
        }
        valid |= 2;
    } else {
        S32(NS_PARTIAL) |= 4; M32(USN_CAPTURE_REASON) = 2;
    }
    S32(NS_TICK) = *g_Tick;
    a = g_Shared[3]; S32(NS_IT) = g_Shared[2]; d = g_Shared[4];
    S32(NS_IT + 4) = a;
    if (a == d) valid |= 16;
    else S32(NS_PARTIAL) |= 2; /* interrupted system-time writer, never spin */
    S32(NS_HB) = M32(USW_HB_ENTRY); S32(NS_ARM) = M32(USW_ARM);
    valid |= 4;
    S32(NS_PCR_TSS) = *(volatile ULONG *)(g_Pcr + 0x40);
    S32(NS_PCR_GDT) = *(volatile ULONG *)(g_Pcr + 0x3C);
    S32(NS_PCR_IRQL) = *(volatile UCHAR *)(g_Pcr + 0x24);
    valid |= 8;
    for (i = 0; i < 5; i++) S32(NS_BUGCHECK + i * 4) = g_BugData[i];
    valid |= 32; /* raw global values, no lock or debugger call in NMI */
    CaptureDetail(snapshot);
    CapturePanel();
    S32(NS_VALID) = valid;
    M32(USN_COUNT) = M32(USN_COUNT) + 1;
    M32(USN_ACK) = USN_TOKEN; /* commit last; helper sees complete data */
    LabText("USN_CAPTURED\n");
    return 1;
}

__declspec(naked) static VOID TaskEntry(VOID)
{
    __asm {
        mov esp, g_StackTop
        pushfd
        pop g_EntryFlags
        cli
        cld
        pushad
        call Capture
        test eax, eax
        jz chain_original
        popad
        iretd
        /* Hardware saves this next EIP into the outgoing NMI TSS. */
        jmp TaskEntry
    chain_original:
        popad
        push g_EntryFlags
        popfd
        mov esp, g_OriginalEsp
        jmp dword ptr [g_OriginalEip]
    }
}

VOID UsosNmiInitialize(volatile UCHAR *mailbox)
{
    ULONG kernel, nt, variant = 0, nmiRva = 0, cr4Value, lo, hi, own;
    ULONG current, task, flags, pcr;
    USHORT tr;
    USN_TABLE idt, gdt;
    PHYSICAL_ADDRESS pa;
    PUCHAR gate;
    g_Mailbox = mailbox;
    if (mailbox == NULL || *(volatile USHORT *)(mailbox + 4) != 2 ||
        M32(USN_CFG) != USN_MAGIC || M32(USN_ENABLE) != 1) return;
#define REJECT(n) { M32(USN_REJECT) = (n); LabText("USN_REJECT\n"); return; }
    M32(USN_READY) = 0;
    __asm {
        _emit 0x0F
        _emit 0x20
        _emit 0xE0 /* MOV EAX, CR4; old WDK inline assembler lacks its name */
        mov cr4Value, eax
    }
    if (cr4Value & 32) REJECT(1); /* PAE requires a separate verified page walker */
    kernel = Image((ULONG)*(PULONG *)&KeTickCount);
    if (!kernel) REJECT(2);
    nt = kernel + *(PULONG)(kernel + 0x3C);
    if (*(PULONG)(nt + 8) == 1055309826UL && *(PULONG)(nt + 0x58) == 1749002UL &&
        *(PULONG)(nt + 0x50) == 1720384UL && (ULONG)*(PULONG *)&KeTickCount - kernel == 447716UL) {
        variant = 1; nmiRva = 0x66826;
    } else if (*(PULONG)(nt + 8) == 1055281331UL && *(PULONG)(nt + 0x58) == 1748590UL &&
        *(PULONG)(nt + 0x50) == 1696576UL && (ULONG)*(PULONG *)&KeTickCount - kernel == 456648UL) {
        variant = 2; nmiRva = 0x67520;
    } else REJECT(3);
    __asm sidt idt __asm sgdt gdt __asm str tr
    if (idt.Limit < 23 || !Span(idt.Base + 16, 8)) REJECT(4);
    gate = (PUCHAR)(idt.Base + 16);
    if (gate[5] != 0x85 || *(PUSHORT)(gate + 2) != 0x58) REJECT(5);
    current = Descriptor(gdt.Base, gdt.Limit, tr, 0x8B);
    task = Descriptor(gdt.Base, gdt.Limit, 0x58, 0x89);
    if (!current || !task || (task & 3) || current == task || tr != 0x28) REJECT(6);
    if (*(PULONG)(task + 0x20) != kernel + nmiRva || !Span(kernel + nmiRva, 1) || *(PUCHAR)(kernel + nmiRva) != 0xFA) REJECT(7);
    if (*(PUSHORT)(task + 0x4C) != 8 || *(PUSHORT)(task + 0x50) != 0x10 ||
        !FlatData(gdt.Base, gdt.Limit, *(PUSHORT)(task + 0x54)) ||
        !FlatData(gdt.Base, gdt.Limit, *(PUSHORT)(task + 0x48))) REJECT(8);
    g_NmiCr3 = *(PULONG)(task + 0x1C);
    if (!(g_NmiCr3 & ~4095UL)) REJECT(9);
    __asm mov ecx, 01Bh __asm rdmsr __asm mov lo, eax __asm mov hi, edx
    if (hi || !(lo & 0x800) || !(lo & 0x100) || (lo & 0x400)) REJECT(10);
    g_LapicPa = lo & 0xFFFFF000UL;
    pa.QuadPart = g_LapicPa;
    g_Lapic = (volatile ULONG *)MmMapIoSpace(pa, 4096, MmNonCached);
    if (!g_Lapic || g_Lapic[0x20 / 4] >> 24 != M32(USN_BSP) || M32(USN_BSP) == M32(USN_HELPER)) REJECT(11);
    g_MainTss = (volatile UCHAR *)current; g_NmiTss = (volatile UCHAR *)task;
    g_MainTr = tr; g_OriginalEip = *(PULONG)(task + 0x20); g_OriginalEsp = *(PULONG)(task + 0x38);
    g_StackTop = (ULONG)(g_NmiStack + sizeof(g_NmiStack) - 16);
    g_Tick = (volatile ULONG *)*(PULONG *)&KeTickCount;
    /* Exact exported KiBugCheckData RVAs, verified in both SP4 retail images.
       The kernel writes code/P1/P2/P3/P4 here before its fatal halt path. */
    g_BugData = (volatile ULONG *)(kernel + (variant == 1 ? 0x82880UL : 0x83CE0UL));
    g_Shared = (volatile ULONG *)0xFFDF0000;
    __asm mov eax, fs:[1Ch] __asm mov pcr, eax
    g_Pcr = (volatile UCHAR *)pcr;
    /* Best-effort extension; failure never disables the primary snapshot.
       The initial thread's stack remains valid while that thread is current.
       Capture refuses stack reads after a thread or address-space switch. */
    g_FaultWindow = kernel + 0x6500;
    g_FaultReady = CommonMapping(g_FaultWindow, 256);
    g_ContextPcrReady = CommonMapping(pcr, 0x128);
    if (g_ContextPcrReady) {
        g_InitialThread = *(volatile ULONG *)(pcr + 0x124);
        __asm mov eax, cr3 __asm mov g_InitialCr3, eax
        IoGetStackLimits(&g_StackLow, &g_StackHigh);
        if (g_InitialThread && g_StackLow >= 0x80000000UL && g_StackHigh > g_StackLow &&
            g_StackHigh - g_StackLow <= 65536 && !(g_StackLow & 3) && !(g_StackHigh & 3))
            g_StackReady = CommonMapping(g_StackLow, g_StackHigh - g_StackLow);
    }
    own = Image((ULONG)TaskEntry);
    if (!own || !ResidentImage(own) || !CommonMapping(current, 104) || !CommonMapping(task, 104) ||
        !CommonMapping((ULONG)mailbox, USW_SIZE) || !CommonMapping((ULONG)g_Lapic, 4096) ||
        !CommonMapping((ULONG)g_Tick, 4) || !CommonMapping((ULONG)g_Shared, 20) ||
        !CommonMapping((ULONG)g_BugData, 20) ||
        !CommonMapping(g_OriginalEip, 160) || !Span(g_OriginalEsp - 64, 64) ||
        !CommonMapping(pcr, 0x44)) REJECT(12);
    g_KBase = kernel; g_KSize = *(PULONG)(nt + 0x50);
    if (variant == 2) FindAcpi();
    g_HBase = HalImage(kernel); g_HSize = g_HBase ? *(PULONG)(g_HBase + *(PULONG)(g_HBase + 0x3C) + 0x50) : 0;
    M32(USN_KBASE) = g_KBase; M32(USN_KSIZE) = g_KSize;
    M32(USN_HBASE) = g_HBase; M32(USN_HSIZE) = g_HSize;
    M32(USN_KVARIANT) = variant; M32(USN_TR) = tr;
    M32(USN_VBASE) = own;
    M32(USN_VSIZE) = *(PULONG)(own + *(PULONG)(own + 0x3C) + 0x50);
    /* Only the aligned EIP word is replaced. Entry switches to our own stack
       before its first push, so no intermediate ESP/ESP0 rewrite is needed. */
    __asm pushfd __asm pop flags __asm cli
    *(volatile ULONG *)(task + 0x20) = (ULONG)TaskEntry;
    M32(USN_READY) = USN_READY_MAGIC;
    __asm push flags __asm popfd
    LabText("USN_READY\n");
#undef REJECT
}

VOID UsosNmiLaboratory(VOID)
{
#ifdef USOS_NMI_LAB
    ULONG flags, before;
    if (g_Mailbox == NULL || M32(USN_READY) != USN_READY_MAGIC) return;
    M32(USN_LAB) = USOS_NMI_LAB;
#if USOS_NMI_LAB == 1 || USOS_NMI_LAB == 4
    UNREFERENCED_PARAMETER(before);
    __asm pushfd __asm pop flags __asm cli
    LabText("USN_CLI_BEGIN\n");
    while (M32(USN_ACK) != USN_TOKEN) { __asm { pause } }
    __asm push flags __asm popfd
    LabText("USN_CLI_RETURN\n");
#if USOS_NMI_LAB == 4
    /* Separate laboratory check: a later unsolicited NMI must chain to the
       original task entry without overwriting our completed snapshot. */
    LabText("USN_SECOND_BEGIN\n");
    g_Lapic[0x300 / 4] = 0x44400; /* self NMI, lab build only */
    LabText("USN_SECOND_RETURN\n");
#endif
#elif USOS_NMI_LAB == 2
    UNREFERENCED_PARAMETER(flags);
    before = g_Lapic[0x80 / 4]; g_Lapic[0x80 / 4] = 0xF0;
    LabText("USN_TPR_BEGIN\n");
    while (M32(USN_ACK) != USN_TOKEN) { __asm { pause } }
    g_Lapic[0x80 / 4] = before;
    LabText("USN_TPR_RETURN\n");
#elif USOS_NMI_LAB == 5
    UNREFERENCED_PARAMETER(flags); UNREFERENCED_PARAMETER(before);
    LabText("USN_EARLY_BEGIN\n");
    g_Lapic[0x300 / 4] = 0x44400; /* unsolicited self NMI, laboratory only */
    LabText("USN_EARLY_RETURN\n");
#elif USOS_NMI_LAB == 6
    UNREFERENCED_PARAMETER(flags); UNREFERENCED_PARAMETER(before);
    LabText("USN_BUGCHECK_BEGIN\n");
    KeBugCheckEx(0xE2, 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00);
#elif USOS_NMI_LAB == 7 || USOS_NMI_LAB == 8
    UNREFERENCED_PARAMETER(flags); UNREFERENCED_PARAMETER(before);
#if USOS_NMI_LAB == 8
    g_StackReady = 0; /* verify the no-stack-read guard on a real exception */
#endif
    LabText("USN_ILLEGAL_BEGIN\n");
    if (M32(USN_KVARIANT) != 2) { LabText("USN_ILLEGAL_PROFILE_SKIP\n"); return; }
    /* Executing FF FF is intentionally invalid. Laboratory image only. */
    ((VOID (NTAPI *)(VOID))(g_KBase + 0x6530))();
#elif USOS_NMI_LAB == 9 || USOS_NMI_LAB == 10
    UNREFERENCED_PARAMETER(flags); UNREFERENCED_PARAMETER(before);
    LabText("USN_NESTED_BEGIN\n");
    if (M32(USN_KVARIANT) == 2) NestedFault();
#else
    UNREFERENCED_PARAMETER(flags); UNREFERENCED_PARAMETER(before);
#endif
#endif
}
