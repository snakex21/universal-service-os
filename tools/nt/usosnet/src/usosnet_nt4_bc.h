/* Copyright (C) 2026 USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 * NT4-only diagnostics. Own code; wrapper constraints established from
 * doors/windows_nt_4_source_code.7z: nt4/private/ntos/ndis/ndis40/{mini.h,timerm.c}.
 * Never linked into the shared Windows 95 or NT351 binaries.
 */
#pragma warning(push)
#pragma warning(disable:4996)
/* Compiler intrinsics (lock-prefixed), no kernel import. */
long __cdecl _InterlockedIncrement(long volatile *Addend);
long __cdecl _InterlockedDecrement(long volatile *Addend);
long __cdecl _InterlockedCompareExchange(long volatile *Target, long Value, long Comparand);
#pragma intrinsic(_InterlockedIncrement, _InterlockedDecrement, _InterlockedCompareExchange)
static WCHAR g_N4Key[256];
static BOOLEAN g_N4Ready;
typedef struct _N4_SAMPLE {
    WORK_QUEUE_ITEM Work;
    KEVENT Done;
    ULONG Values[8];
} N4_SAMPLE;
static N4_SAMPLE g_N4Samples[4];
static KMUTEX g_N4Mutex;
static volatile LONG g_N4Stopping;
static volatile LONG g_N4InTick; /* N4Tick bodies running (any CPU) */
static ULONG g_N4Seq, g_N4Next;
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
    KeWaitForSingleObject(&g_N4Mutex, Executive, KernelMode, FALSE, NULL);
    values[0] = 0x400B0001; values[1] = ++g_N4Seq;
    values[2] = point; values[3] = stage; values[4] = error;
    for (i = 0; i < 8; i++) values[5+i] = sample ? sample[i] : 0;
    N4String(&key, g_N4Key);
    InitializeObjectAttributes(&oa, &key, OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (!NT_SUCCESS(ZwCreateKey(&h, KEY_SET_VALUE, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, &disposition))) {
        KeReleaseMutex(&g_N4Mutex, FALSE); return;
    }
    for (i = 0; i < 13; i++) {
        N4String(&name, names[i]);
        ZwSetValueKey(h, &name, 0, REG_DWORD, values+i, sizeof(ULONG));
    }
    ZwFlushKey(h);
    ZwClose(h);
    KeReleaseMutex(&g_N4Mutex, FALSE);
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
    for (i = 0; i < 4; i++) KeInitializeEvent(&g_N4Samples[i].Done, NotificationEvent, TRUE);
    KeInitializeMutex(&g_N4Mutex, 0);
    g_N4Ready = TRUE;
    N4Write(0, ST_ENTRY, 0, NULL); /* DriverEntry, before NDIS wrapper init */
}

static VOID N4Worker(PVOID context)
{
    N4_SAMPLE *sample = (N4_SAMPLE *)context;
    N4Write(0x20, ST_STARTED, 0, sample->Values);
    KeSetEvent(&sample->Done, IO_NO_INCREMENT, FALSE);
}

/* Called by NDIS's serialized timer, not the ISR. Snapshot owns no adapter
 * pointer. All registry I/O (especially ZwFlushKey) runs at PASSIVE_LEVEL. */
static void N4Tick(PADAPTER a)
{
    N4_SAMPLE *sample;
    ULONG sec = a->TimerCount / TICKS_PER_SEC;
    /* Announce first, then test g_N4Stopping (both interlocked = full
     * barriers): N4Drain either sees this tick in g_N4InTick and waits for
     * it, or this tick sees g_N4Stopping and queues nothing. */
    _InterlockedIncrement(&g_N4InTick);
    if (!g_N4Ready || _InterlockedCompareExchange(&g_N4Stopping, 0, 0) ||
        g_N4Next >= 4 || sec < g_N4At[g_N4Next]) {
        _InterlockedDecrement(&g_N4InTick);
        return;
    }
    /* Each of the four samples is queued once. Never reuse a work item or
     * its event while the previous callback is still returning. */
    sample = &g_N4Samples[g_N4Next++];
    KeClearEvent(&sample->Done);
    sample->Values[0] = sec; sample->Values[1] = a->IsrCount;
    sample->Values[2] = a->TimerCount; sample->Values[3] = a->RxOk;
    sample->Values[4] = a->TxOk; sample->Values[5] = a->PollMode;
    sample->Values[6] = a->LinkUp; sample->Values[7] = a->IrqStatus;
    ExInitializeWorkItem(&sample->Work, N4Worker, sample);
    ExQueueWorkItem(&sample->Work, DelayedWorkQueue);
    _InterlockedDecrement(&g_N4InTick);
}

/* MpHalt is PASSIVE_LEVEL. NdisMCancelTimer does not wait for a timer DPC
 * already running on another processor (MP kernel), so after g_N4Stopping
 * wait for any tick still inside N4Tick before reading g_N4Next.
 * Drain before returning, so an unload cannot free code used by the worker. */
static void N4Drain(void)
{
    ULONG i;
    LARGE_INTEGER ms;
    _InterlockedExchange(&g_N4Stopping, 1);
    if (!g_N4Ready) return;
    ms.QuadPart = -10000; /* 1 ms, relative */
    while (_InterlockedCompareExchange(&g_N4InTick, 0, 0) != 0)
        KeDelayExecutionThread(KernelMode, FALSE, &ms);
    for (i = 0; i < g_N4Next; i++)
        KeWaitForSingleObject(&g_N4Samples[i].Done, Executive, KernelMode, FALSE, NULL);
}
#define BC(A, P) N4Write((P), (A)->Stage, (A)->Error, NULL)
#pragma warning(pop)
