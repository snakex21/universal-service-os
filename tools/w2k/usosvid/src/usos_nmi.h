/* One-shot USOS NMI diagnostic ABI. Own code, LGPL-2.1-or-later.
 * Extends UW7D without changing any offset below 0x240.
 * Firmware: 240..257. BOOTVID: 258..27f, 2c0..2ff, 300..47f.
 * Helper: 280..2bf. No physical addresses are truncated to 32 bits. */
#ifndef USOS_NMI_H
#define USOS_NMI_H
#define USN_MAGIC 0x324D4E55UL /* UNM2 */
#define USN_CFG 0x240u
#define USN_ENABLE 0x244u
#define USN_BSP 0x248u
#define USN_HELPER 0x24Cu
#define USN_READY 0x258u
#define USN_REJECT 0x25Cu
#define USN_KBASE 0x260u
#define USN_KSIZE 0x264u
#define USN_HBASE 0x268u
#define USN_HSIZE 0x26Cu
#define USN_KVARIANT 0x270u
#define USN_TR 0x274u
#define USN_VBASE 0x278u
#define USN_VSIZE 0x27Cu
#define USN_REQUEST 0x280u
#define USN_PHASE 0x284u
#define USN_REASON 0x288u
#define USN_OLD_TICK 0x28Cu
#define USN_OLD_IT 0x290u
#define USN_OLD_PROXY 0x294u
#define USN_ADVANCE 0x298u
#define USN_SENT_TSC 0x2A0u
#define USN_DRAWS 0x2A8u
#define USN_APIC_BEFORE 0x2B0u
#define USN_APIC_AFTER 0x2B4u
#define USN_APIC_RESTORED 0x2B8u
#define USN_HELPER_SVR 0x2BCu
#define USN_ACK 0x2C0u
#define USN_CAPTURE_REASON 0x2C4u
#define USN_COUNT 0x2C8u
#define USN_LAB 0x2CCu /* BOOTVID laboratory build only, never hardware mode */
#define USN_UNSOL 0x2D0u
#define USN_UNSOL_EIP 0x2D4u
#define USN_UNSOL_FLAGS 0x2D8u
#define USN_UNSOL_TICK 0x2DCu
#define USN_UNSOL_TR 0x2E0u
#define USN_UNSOL_VALID 0x2E4u
#define USN_UNSOL_COUNT 0x2E8u
#define USN_EVENT_MAGIC 0x324E5645UL /* EVN2, committed last */
#define USN_SNAPSHOT 0x300u
#define USN_SNAPSHOT_SIZE 0x180u
#define USN_READY_MAGIC 0x32594452UL /* RDY2 */
#define USN_TOKEN 0x21494D4EUL /* NMI! */
#define USN_SNAP_MAGIC 0x32504E53UL /* SNP2 */
#define USN_WAIT 0u
#define USN_WATCH 1u
#define USN_REQUESTED 2u
#define USN_DONE 3u
#define USN_NOACK 4u
#define USN_SKIPPED 5u
/* Snapshot offsets, relative to USN_SNAPSHOT. All fields are u32 except TSC. */
#define NS_VALID 0x08u
#define NS_PARTIAL 0x0Cu
#define NS_EIP 0x10u
#define NS_FLAGS 0x14u
#define NS_ESP 0x18u
#define NS_CR3 0x1Cu
#define NS_CS 0x20u
#define NS_SS 0x24u
#define NS_EAX 0x28u
#define NS_EBX 0x2Cu
#define NS_ECX 0x30u
#define NS_EDX 0x34u
#define NS_ESI 0x38u
#define NS_EDI 0x3Cu
#define NS_EBP 0x40u
#define NS_BACKLINK 0x44u
#define NS_NMI_CR3 0x48u
#define NS_TSC 0x50u
#define NS_TICK 0x58u
#define NS_IT 0x5Cu
#define NS_HB 0x64u
#define NS_ARM 0x68u
#define NS_APIC_BASE 0x70u
#define NS_ID 0x78u
#define NS_TPR 0x7Cu
#define NS_PPR 0x80u
#define NS_SVR 0x84u
#define NS_LDR 0x88u
#define NS_DFR 0x8Cu
#define NS_LVTT 0x90u
#define NS_LINT0 0x94u
#define NS_LINT1 0x98u
#define NS_ISR 0xA0u
#define NS_IRR 0xC0u
#define NS_TMR 0xE0u
#define NS_PCR_TSS 0x100u
#define NS_PCR_GDT 0x104u
#define NS_PCR_IRQL 0x108u
#define NS_BUGCHECK 0x110u /* five raw u32s, code plus four parameters */
#define USN_DETAIL 0x500u
#define USN_DETAIL_SIZE 0x300u
#define USN_DETAIL_MAGIC 0x334C5444UL /* DTL3, committed before ACK */
#define ND_VALID 0x04u
#define ND_STACK_LO 0x0Cu
#define ND_STACK_HI 0x10u
#define ND_INIT_THREAD 0x14u
#define ND_THREAD 0x18u
#define ND_INIT_CR3 0x1Cu
#define ND_CR3 0x20u
#define ND_ESP 0x24u
#define ND_EBP 0x28u
#define ND_FS0 0x2Cu
#define ND_FAULT 0x30u
#define ND_FAULT_WORDS 0x34u /* eight raw words */
#define ND_FRAME_COUNT 0x54u
#define ND_SEH_COUNT 0x58u
#define ND_TOP_COUNT 0x5Cu
#define ND_FRAMES 0x60u /* sixteen records: frame, previous, return, three args */
#define ND_SEH 0x1E0u /* eight raw six-word records, first word is record VA */
#define ND_TOP 0x2A0u /* sixteen words from interrupted ESP, bounded */
#define ND_HIGH 0x2E0u /* eight words below initial stack high */
/* EX4: three nested MP dispatcher contexts, newest first. Read only within
 * the already validated initial stack. Nine screen rows, six words each. */
#define USN_EXCEPTION 0x800u
#define UE_MAGIC 0x8E0u
#define UE_COUNT 0x8E4u
#define UE_RAW 0x900u /* three 0x100-byte records, raw EXCEPTION_RECORD/CONTEXT */
#define UE_MAGIC_VALUE 0x34584345UL /* ECX4, commit before primary ACK */
#define UE_ORIGINAL 0xC00u /* three six-word frames from oldest captured context */
#define UE_PANEL 0xD00u /* eleven rows of six u32s, prepared by the BSP NMI */
#define UE_PANEL_MAGIC 0xE0Cu
#define UE_PANEL_VALUE 0x354C4E50UL /* PNL5 */
#define UE_IRQ 0xE10u /* IRQ7: 8 header words then 0x68 raw stack bytes */
#define UE_IRQ_VALUE 0x37515249UL
/* Detail validity: 1 stack mapping verified, 2 same initial thread,
 * 4 same initial CR3, 8 interrupted ESP within that stack, 16 EBP records,
 * 32 SEH records, 64 fault window prevalidated, 128 fault bytes copied.
 * Only the prevalidated original stack may be dereferenced. No page walk,
 * Windows API, allocation, lock or arbitrary pointer dereference in NMI. */
/* Validity: 1 previous TSS, 2 LAPIC, 4 counters, 8 prevalidated PCR,
 * 16 consistent InterruptTime, 32 prevalidated KiBugCheckData[5].
 * PARTIAL bit 1: RTE/RTC/PM indexed or destructive I/O deliberately omitted.
 * No IOREGSEL, EOI, RTC, PM/GPE or chipset write exists in the handler. */
#ifdef _NTDDK_
VOID UsosNmiInitialize(volatile UCHAR *Mailbox);
VOID UsosNmiLaboratory(VOID);
#endif
#endif
