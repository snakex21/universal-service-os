/* Copyright (C) 2026 USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 * NT4-only diagnostics. Own code; wrapper constraints established from
 * doors/windows_nt_4_source_code.7z: nt4/private/ntos/ndis/ndis40/{mini.h,timerm.c}.
 * Never linked into the shared Windows 95 or NT351 binaries.
 */
#pragma warning(push)
#pragma warning(disable:4996)
static WCHAR g_N4Key[256];
static BOOLEAN g_N4Ready;
static WORK_QUEUE_ITEM g_N4Work;
static KEVENT g_N4Done;
static volatile LONG g_N4Pending, g_N4Stopping;
static ULONG g_N4Seq, g_N4Values[8], g_N4Next;
static const ULONG g_N4At[] = {1, 2, 5, 10};

static void N4String(PUNICODE_STRING u, PCWSTR p)
{
    USHORT n = 0;
    while (p[n]) n++;
    u->Buffer = (PWSTR)p; u->Length = n * sizeof(WCHAR);
    u->MaximumLength = u->Length + sizeof(WCHAR);
}

static void N4Write(ULONG point, ULONG stage, ULONG error, const ULONG *sample)
{
    static const PCWSTR names[] = {L"UsosnetBcVersion", L"UsosnetBcSeq", L"UsosnetBcPoint",
        L"UsosnetBcStage", L"UsosnetBcError", L"UsosnetAliveSec", L"UsosnetIsr",
        L"UsosnetTimer", L"UsosnetRx", L"UsosnetTx", L"UsosnetPoll", L"UsosnetLink", L"UsosnetIrqStatus"};
    ULONG values[13], i, disposition;
    UNICODE_STRING key, name;
    OBJECT_ATTRIBUTES oa;
    HANDLE h;
    if (!g_N4Ready || KeGetCurrentIrql() != PASSIVE_LEVEL) return;
    values[0] = 0x400B0001; values[1] = ++g_N4Seq;
    values[2] = point; values[3] = stage; values[4] = error;
    for (i = 0; i < 8; i++) values[5+i] = sample ? sample[i] : 0;
    N4String(&key, g_N4Key);
    InitializeObjectAttributes(&oa, &key, OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (!NT_SUCCESS(ZwCreateKey(&h, KEY_SET_VALUE, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, &disposition))) return;
    for (i = 0; i < 13; i++) {
        N4String(&name, names[i]);
        ZwSetValueKey(h, &name, 0, REG_DWORD, values+i, sizeof(ULONG));
    }
    ZwFlushKey(h);
    ZwClose(h);
}

static void N4Init(PUNICODE_STRING path)
{
    static const WCHAR suffix[] = L"\\Parameters\\NativeDiag";
    ULONG n, i;
    if (!path || path->Length % 2) return;
    n = path->Length / sizeof(WCHAR);
    if (n + sizeof(suffix)/sizeof(WCHAR) > sizeof(g_N4Key)/sizeof(WCHAR)) return;
    for (i = 0; i < n; i++) g_N4Key[i] = path->Buffer[i];
    for (i = 0; i < sizeof(suffix)/sizeof(WCHAR); i++) g_N4Key[n+i] = suffix[i];
    KeInitializeEvent(&g_N4Done, NotificationEvent, TRUE);
    g_N4Ready = TRUE;
    N4Write(0, ST_ENTRY, 0, NULL); /* DriverEntry, before NDIS wrapper init */
}

static VOID N4Worker(PVOID unused)
{
    (void)unused;
    N4Write(0x20, ST_STARTED, 0, g_N4Values);
    _InterlockedExchange(&g_N4Pending, 0);
    KeSetEvent(&g_N4Done, IO_NO_INCREMENT, FALSE);
}

/* Called by NDIS's serialized timer, not the ISR. Snapshot owns no adapter
 * pointer. All registry I/O (especially ZwFlushKey) runs at PASSIVE_LEVEL. */
static void N4Tick(PADAPTER a)
{
    ULONG sec = a->TimerCount / TICKS_PER_SEC;
    if (!g_N4Ready || g_N4Stopping || g_N4Next >= 4 || sec < g_N4At[g_N4Next]) return;
    if (_InterlockedCompareExchange(&g_N4Pending, 1, 0)) return;
    KeClearEvent(&g_N4Done);
    g_N4Values[0] = sec; g_N4Values[1] = a->IsrCount;
    g_N4Values[2] = a->TimerCount; g_N4Values[3] = a->RxOk;
    g_N4Values[4] = a->TxOk; g_N4Values[5] = a->PollMode;
    g_N4Values[6] = a->LinkUp; g_N4Values[7] = a->IrqStatus;
    g_N4Next++;
    ExInitializeWorkItem(&g_N4Work, N4Worker, NULL);
    ExQueueWorkItem(&g_N4Work, DelayedWorkQueue);
}

/* MpHalt is PASSIVE_LEVEL; the cancelled timer can queue no new sample.
 * Drain before returning, so an unload cannot free code used by the worker. */
static void N4Drain(void)
{
    _InterlockedExchange(&g_N4Stopping, 1);
    if (g_N4Pending) KeWaitForSingleObject(&g_N4Done, Executive, KernelMode, FALSE, NULL);
}
#define BC(A, P) N4Write((P), (A)->Stage, (A)->Error, NULL)
#pragma warning(pop)
