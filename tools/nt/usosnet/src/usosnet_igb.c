/*
 * usosnet - igb family backend: Intel I211 / I210 / 82576.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Written from the public Intel datasheets (Intel Ethernet Controller
 * I210/I211 datasheet; Intel 82576EB GbE Controller datasheet): register
 * offsets, the software reset sequence, EERD, the I210/I211 iNVM record
 * layout, MDIC, advanced RX (SRRCTL one-buffer) and TX (advanced data)
 * descriptors. The Linux igb driver (GPL-2.0) and FreeBSD e1000/igb (BSD)
 * were read as references for the order of the steps only (e.g. which
 * iNVM record types carry extra dwords, RAH pool bit, polling the queue
 * ENABLE bits); no code was copied.
 *
 * Interrupt model: legacy INTx (Windows 9x has no MSI). Queue 0 RX and TX
 * are mapped to vector 0 through IVAR0 and EIMS bit 0 is enabled next to
 * the legacy ICR causes, so both the "other" causes (link) and the queue
 * cause raise INTx. The ISR masks everything (IMC / EIMC), the DPC polls
 * the RX ring and unmasks again.
 */
#include "usosnet.h"

#define CTRL        0x0000
#define STATUS      0x0008
#define EECD        0x0010
#define EERD        0x0014
#define CTRL_EXT    0x0018
#define MDIC        0x0020
#define RCTL        0x0100
#define TCTL        0x0400
#define ICR         0x1500
#define IMS         0x1508
#define IMC         0x150C
#define IAM         0x1510
#define GPIE        0x1514
#define EIMS        0x1524
#define EIMC        0x1528
#define EIAC        0x152C
#define EIAM        0x1530
#define EICR        0x1580
#define IVAR0       0x1700
#define RXCSUM      0x5000
#define MTA         0x5200
#define RAL0        0x5400
#define RAH0        0x5404
#define MRQC        0x5818
#define RDBAL0      0xC000
#define RDBAH0      0xC004
#define RDLEN0      0xC008
#define SRRCTL0     0xC00C
#define RDH0        0xC010
#define RDT0        0xC018
#define RXDCTL0     0xC028
#define TDBAL0      0xE000
#define TDBAH0      0xE004
#define TDLEN0      0xE008
#define TDH0        0xE010
#define TDT0        0xE018
#define TXDCTL0     0xE028
#define INVM_DATA   0x12120     /* I210 / I211: 64 dwords */

#define CTRL_GIO_MASTER_DISABLE (1UL << 2)
#define CTRL_SLU        (1UL << 6)
#define CTRL_FRCSPD     (1UL << 11)
#define CTRL_FRCDPLX    (1UL << 12)
#define CTRL_RST        (1UL << 26)
#define CTRL_PHY_RST    (1UL << 31)
#define STATUS_FD       (1UL << 0)
#define STATUS_LU       (1UL << 1)
#define STATUS_GIO_MASTER_EN (1UL << 19)
#define STATUS_PF_RST_DONE (1UL << 21)
#define EECD_AUTO_RD    (1UL << 9)
#define EECD_FLASH_DETECTED (1UL << 19)   /* I210: external flash present */
#define CTRL_EXT_DRV_LOAD (1UL << 28)
#define EERD_START      1UL
#define EERD_DONE       2UL

#define RCTL_EN         (1UL << 1)
#define RCTL_UPE        (1UL << 3)
#define RCTL_MPE        (1UL << 4)
#define RCTL_BAM        (1UL << 15)
#define RCTL_SECRC      (1UL << 26)
#define TCTL_EN         (1UL << 1)
#define TCTL_PSP        (1UL << 3)
#define TCTL_CT         (0x0FUL << 4)
#define TCTL_COLD       (0x3FUL << 12)
#define TCTL_RTLC       (1UL << 24)
#define QUEUE_ENABLE    (1UL << 25)    /* RXDCTL / TXDCTL */
#define SRRCTL_2K_ADV1  (2UL | (1UL << 25) | (1UL << 31))   /* 2 KiB, adv one-buffer, DROP_EN */

#define ICR_LSC         (1UL << 2)
#define ICR_RXSEQ       (1UL << 3)
#define ICR_RXDMT0      (1UL << 4)
#define ICR_RXO         (1UL << 6)
#define ICR_RXT0        (1UL << 7)
#define ICR_ASSERTED    (1UL << 31)
#define IMS_MASK        (ICR_LSC | ICR_RXSEQ | ICR_RXDMT0 | ICR_RXO | ICR_RXT0)

/* advanced TX data descriptor, dword 2 / 3 */
#define TXD_DTYP_DATA   0x00300000UL
#define TXD_EOP         0x01000000UL
#define TXD_IFCS        0x02000000UL
#define TXD_RS          0x08000000UL
#define TXD_DEXT        0x20000000UL
#define TXD_PAYLEN_SHIFT 14
#define TXD_STAT_DD     1UL
/* advanced RX write-back, dword 2 (status / error) */
#define RXD_STAT_DD     1UL
#define RXD_STAT_EOP    2UL
#define RXD_ERR_FRAME   0x97000000UL  /* CE SE SEQ CXE RXE */

#define PHY_ADDR        1

static BOOLEAN MdicRead(PADAPTER A, ULONG Reg, USHORT *Val)
{
    ULONG i, v;
    WR32(A, MDIC, (Reg << 16) | ((ULONG)PHY_ADDR << 21) | (2UL << 26));
    for (i = 0; i < 2000; i++) {
        UsStall(5);
        v = RD32(A, MDIC);
        if (v & (1UL << 28)) {
            if (v & (1UL << 30)) return FALSE;
            *Val = (USHORT)(v & 0xFFFF);
            return TRUE;
        }
    }
    return FALSE;
}

static BOOLEAN MdicWrite(PADAPTER A, ULONG Reg, USHORT Val)
{
    ULONG i, v;
    WR32(A, MDIC, Val | (Reg << 16) | ((ULONG)PHY_ADDR << 21) | (1UL << 26));
    for (i = 0; i < 2000; i++) {
        UsStall(5);
        v = RD32(A, MDIC);
        if (v & (1UL << 28)) return (v & (1UL << 30)) ? FALSE : TRUE;
    }
    return FALSE;
}

static void IgbIrqDisable(PADAPTER A)
{
    WR32(A, IMC, 0xFFFFFFFF);
    WR32(A, EIMC, 0xFFFFFFFF);
}

static void IgbIrqEnable(PADAPTER A)
{
    WR32(A, IMS, IMS_MASK);
    WR32(A, EIMS, 1);
}

static ULONG IgbIrqRead(PADAPTER A)
{
    ULONG icr = RD32(A, ICR);
    ULONG eicr = RD32(A, EICR);
    if (icr == 0xFFFFFFFF) return 0;          /* device gone */
    if (eicr) WR32(A, EICR, eicr);
    if (!(icr & (ICR_ASSERTED | IMS_MASK)) && !(eicr & 1)) return 0;
    IgbIrqDisable(A);
    return (icr & ~ICR_ASSERTED) | ((eicr & 1) ? ICR_RXT0 : 0) | 0x100;
}

static NDIS_STATUS IgbReset(PADAPTER A)
{
    ULONG i;
    IgbIrqDisable(A);
    WR32(A, RCTL, 0);
    WR32(A, TCTL, TCTL_PSP);
    (void)RD32(A, STATUS);
    UsStall(10000);

    /* stop bus mastering before the reset (datasheet: master disable) */
    WR32(A, CTRL, RD32(A, CTRL) | CTRL_GIO_MASTER_DISABLE);
    for (i = 0; i < 800 && (RD32(A, STATUS) & STATUS_GIO_MASTER_EN); i++) UsStall(1000);

    WR32(A, CTRL, RD32(A, CTRL) | CTRL_RST);
    UsStall(5000);
    for (i = 0; i < 100; i++) {
        ULONG v = RD32(A, CTRL);
        if (v != 0xFFFFFFFF && !(v & CTRL_RST)) break;
        UsStall(1000);
    }
    /* NVM / iNVM auto-read and reset done */
    for (i = 0; i < 100 && !(RD32(A, EECD) & EECD_AUTO_RD); i++) UsStall(1000);
    for (i = 0; i < 100 && !(RD32(A, STATUS) & STATUS_PF_RST_DONE); i++) UsStall(1000);
    if (RD32(A, STATUS) == 0xFFFFFFFF) return NDIS_STATUS_HARD_ERRORS;

    IgbIrqDisable(A);
    (void)RD32(A, ICR);
    (void)RD32(A, EICR);
    WR32(A, GPIE, 0);
    WR32(A, IAM, 0);
    WR32(A, EIAC, 0);
    WR32(A, EIAM, 0);
    WR32(A, CTRL_EXT, RD32(A, CTRL_EXT) | CTRL_EXT_DRV_LOAD);
    A->CtrlAtInit = RD32(A, CTRL);
    UsLog(A, "reset ctrl %x eecd %x", A->CtrlAtInit, RD32(A, EECD));
    return NDIS_STATUS_SUCCESS;
}

static BOOLEAN MacValid(const UCHAR *M)
{
    ULONG i, ff = 0, z = 0;
    for (i = 0; i < ETH_ALEN; i++) { if (M[i] == 0xFF) ff++; if (!M[i]) z++; }
    return (ff != ETH_ALEN && z != ETH_ALEN && !(M[0] & 1)) ? TRUE : FALSE;
}

static BOOLEAN EerdRead(PADAPTER A, ULONG Word, USHORT *Val)
{
    ULONG i, v;
    WR32(A, EERD, (Word << 2) | EERD_START);
    for (i = 0; i < 10000; i++) {
        v = RD32(A, EERD);
        if (v & EERD_DONE) { *Val = (USHORT)(v >> 16); return TRUE; }
        UsStall(5);
    }
    return FALSE;
}

/* I210 / I211 iNVM: word-autoload records carry NVM words 0..2 (MAC). */
static BOOLEAN InvmMac(PADAPTER A, UCHAR *Mac)
{
    ULONG i, d, type, addr, data, got = 0;
    for (i = 0; i < 64; i++) {
        d = RD32(A, INVM_DATA + 4 * i);
        type = d & 7;
        if (type == 0) break;                 /* uninitialized: end of records */
        if (type == 2) { i += 1; continue; }  /* CSR autoload: + 1 data dword */
        if (type == 4) { i += 8; continue; }  /* RSA key SHA-256: + 8 dwords */
        if (type != 1) continue;              /* PHY autoload, invalidated */
        addr = (d >> 9) & 0x7F;
        data = d >> 16;
        if (addr <= 2) {
            Mac[addr * 2] = (UCHAR)data;
            Mac[addr * 2 + 1] = (UCHAR)(data >> 8);
            got |= 1UL << addr;
        }
    }
    return got == 7 ? TRUE : FALSE;
}

static BOOLEAN IgbReadMac(PADAPTER A, UCHAR *Mac)
{
    ULONG ral = RD32(A, RAL0), rah = RD32(A, RAH0), i;
    USHORT w;

    Mac[0] = (UCHAR)ral; Mac[1] = (UCHAR)(ral >> 8); Mac[2] = (UCHAR)(ral >> 16); Mac[3] = (UCHAR)(ral >> 24);
    Mac[4] = (UCHAR)rah; Mac[5] = (UCHAR)(rah >> 8);
    UsLog(A, "ral %x rah %x", ral, rah);
    if ((rah & 0x80000000UL) && MacValid(Mac)) { A->MacSource = 1; return TRUE; }

    if ((A->Chip->Flags & CHIP_IGB_I210) && !(RD32(A, EECD) & EECD_FLASH_DETECTED)) {
        if (InvmMac(A, Mac) && MacValid(Mac)) { A->MacSource = 3; return TRUE; }
    } else {
        for (i = 0; i < 3; i++) {
            if (!EerdRead(A, i, &w)) break;
            Mac[i * 2] = (UCHAR)w;
            Mac[i * 2 + 1] = (UCHAR)(w >> 8);
        }
        if (i == 3) {
            /* 82576 second port: LAN 1 address = LAN 0 address ^ 1 */
            if ((A->Chip->Flags & CHIP_IGB_82576) && ((RD32(A, STATUS) >> 2) & 3) == 1) Mac[5] ^= 1;
            if (MacValid(Mac)) { A->MacSource = 2; return TRUE; }
        }
    }
    /* last resort: whatever RAL/RAH hold without AV, if it looks sane */
    Mac[0] = (UCHAR)ral; Mac[1] = (UCHAR)(ral >> 8); Mac[2] = (UCHAR)(ral >> 16); Mac[3] = (UCHAR)(ral >> 24);
    Mac[4] = (UCHAR)rah; Mac[5] = (UCHAR)(rah >> 8);
    if (MacValid(Mac)) { A->MacSource = 5; return TRUE; }
    /* no address at all: a locally administered one so the stack can run */
    Mac[0] = 0x02; Mac[1] = 0x55; Mac[2] = 0x53; Mac[3] = 0x4F; Mac[4] = 0x53; Mac[5] = 0x01;
    A->MacSource = 6;
    return TRUE;
}

static void IgbSetMac(PADAPTER A, const UCHAR *Mac)
{
    WR32(A, RAL0, Mac[0] | ((ULONG)Mac[1] << 8) | ((ULONG)Mac[2] << 16) | ((ULONG)Mac[3] << 24));
    WR32(A, RAH0, Mac[4] | ((ULONG)Mac[5] << 8) | (1UL << 18) /* pool 0 */ | 0x80000000UL /* AV */);
}

static void IgbPhyInit(PADAPTER A)
{
    USHORT bmcr = 0, id1 = 0, id2 = 0, bmsr = 0;
    ULONG ctrl = RD32(A, CTRL);
    ctrl &= ~(CTRL_FRCSPD | CTRL_FRCDPLX | CTRL_PHY_RST);
    ctrl |= CTRL_SLU;
    WR32(A, CTRL, ctrl);
    UsStall(1000);
    if (MdicRead(A, 2, &id1) && MdicRead(A, 3, &id2)) A->PhyId = ((ULONG)id1 << 16) | id2;
    if (MdicRead(A, 0, &bmcr)) {
        /* power up (bit 11), advertise 10/100/1000, restart autoneg */
        MdicWrite(A, 4, 0x0DE1);     /* ANAR: 10/100 half+full, pause, asym pause, selector 802.3 */
        MdicWrite(A, 9, 0x0300);     /* 1000BASE-T full + half */
        bmcr &= ~0x0800;
        bmcr |= 0x1000 | 0x0200;
        MdicWrite(A, 0, bmcr);
    }
    MdicRead(A, 1, &bmsr);
    A->PhyBmsr = ((ULONG)bmcr << 16) | bmsr;
    A->StatusAtInit = RD32(A, STATUS);
    UsLog(A, "phy id %x bmcr/bmsr %x", A->PhyId, A->PhyBmsr);
}

static void IgbStart(PADAPTER A)
{
    ULONG i;
    volatile ULONG *d;

    WR32(A, RCTL, 0);
    WR32(A, MRQC, 0);
    for (i = 0; i < 128; i++) WR32(A, MTA + 4 * i, 0);

    /* TX ring 0 */
    UsZero(A->TxRing.Va, TX_COUNT * 16);
    WR32(A, TXDCTL0, 0);
    WR32(A, TDBAL0, A->TxRing.Pa);
    WR32(A, TDBAH0, 0);
    WR32(A, TDLEN0, TX_COUNT * 16);
    WR32(A, TDH0, 0);
    WR32(A, TDT0, 0);
    A->TxNext = A->TxClean = A->TxBusy = 0;
    WR32(A, TXDCTL0, QUEUE_ENABLE | 8 | (1UL << 8) | (1UL << 16));
    for (i = 0; i < 100 && !(RD32(A, TXDCTL0) & QUEUE_ENABLE); i++) UsStall(100);
    WR32(A, TCTL, TCTL_EN | TCTL_PSP | TCTL_CT | TCTL_COLD | TCTL_RTLC);

    /* RX ring 0: advanced one-buffer descriptors, 2 KiB buffers */
    WR32(A, RXDCTL0, 0);
    for (i = 0; i < RX_COUNT; i++) {
        d = (volatile ULONG *)(A->RxRing.Va + i * 16);
        d[0] = A->RxBufPa[i]; d[1] = 0; d[2] = 0; d[3] = 0;
    }
    WR32(A, RDBAL0, A->RxRing.Pa);
    WR32(A, RDBAH0, 0);
    WR32(A, RDLEN0, RX_COUNT * 16);
    WR32(A, SRRCTL0, SRRCTL_2K_ADV1);
    WR32(A, RDH0, 0);
    WR32(A, RDT0, 0);
    A->RxNext = 0;
    WR32(A, RXDCTL0, QUEUE_ENABLE | 8 | (8UL << 8) | (1UL << 16));
    for (i = 0; i < 100 && !(RD32(A, RXDCTL0) & QUEUE_ENABLE); i++) UsStall(100);
    WR32(A, RDT0, RX_COUNT - 1);

    /* queue 0 RX + TX -> vector 0 (bit 7 = valid) */
    WR32(A, IVAR0, 0x00008080UL);
    WR32(A, RCTL, RCTL_EN | RCTL_BAM | RCTL_SECRC);
    UsLog(A, "rings rx %x tx %x", A->RxRing.Pa, A->TxRing.Pa);
}

static void IgbStop(PADAPTER A)
{
    ULONG i;
    IgbIrqDisable(A);
    WR32(A, RCTL, 0);
    WR32(A, TCTL, TCTL_PSP);
    WR32(A, RXDCTL0, 0);
    WR32(A, TXDCTL0, 0);
    (void)RD32(A, STATUS);
    UsStall(2000);
    WR32(A, CTRL, RD32(A, CTRL) | CTRL_GIO_MASTER_DISABLE);
    for (i = 0; i < 100 && (RD32(A, STATUS) & STATUS_GIO_MASTER_EN); i++) UsStall(1000);
    WR32(A, CTRL, RD32(A, CTRL) | CTRL_RST);
    UsStall(5000);
    WR32(A, CTRL_EXT, RD32(A, CTRL_EXT) & ~CTRL_EXT_DRV_LOAD);
    IgbIrqDisable(A);
}

static BOOLEAN IgbTransmit(PADAPTER A, ULONG Len)
{
    ULONG i = A->TxNext;
    volatile ULONG *d = (volatile ULONG *)(A->TxRing.Va + i * 16);
    d[0] = A->TxBufPa[i];
    d[1] = 0;
    d[3] = Len << TXD_PAYLEN_SHIFT;
    d[2] = Len | TXD_DTYP_DATA | TXD_EOP | TXD_IFCS | TXD_RS | TXD_DEXT;
    A->TxNext = (i + 1) % TX_COUNT;
    A->TxBusy++;
    WR32(A, TDT0, A->TxNext);
    return TRUE;
}

static void IgbTxReclaim(PADAPTER A)
{
    volatile ULONG *d;
    while (A->TxBusy) {
        d = (volatile ULONG *)(A->TxRing.Va + A->TxClean * 16);
        if (!(d[3] & TXD_STAT_DD)) break;
        d[3] = 0;
        A->TxClean = (A->TxClean + 1) % TX_COUNT;
        A->TxBusy--;
    }
}

static void IgbRxPoll(PADAPTER A)
{
    ULONG n, i, st, len, last = 0xFFFFFFFF;
    volatile ULONG *d;
    for (n = 0; n < RX_COUNT; n++) {
        i = A->RxNext;
        d = (volatile ULONG *)(A->RxRing.Va + i * 16);
        st = d[2];
        if (!(st & RXD_STAT_DD)) break;
        len = d[3] & 0xFFFF;
        if (!(st & RXD_STAT_EOP) || (st & RXD_ERR_FRAME)) {
            A->RxErr++;
            if (st & 0x01000000UL) A->RxCrcErr++;
        } else {
            UsIndicateRx(A, A->RxBuf[i], len);
        }
        d[0] = A->RxBufPa[i]; d[1] = 0; d[2] = 0; d[3] = 0;   /* back to read format */
        last = i;
        A->RxNext = (i + 1) % RX_COUNT;
    }
    if (last != 0xFFFFFFFF) {
        NdisMEthIndicateReceiveComplete(A->Handle);
        WR32(A, RDT0, last);
    }
}

static void IgbLinkState(PADAPTER A, BOOLEAN *Up, ULONG *Mbps, BOOLEAN *Full)
{
    ULONG s = RD32(A, STATUS);
    ULONG sp = (s >> 6) & 3;
    *Up = (s & STATUS_LU) ? TRUE : FALSE;
    *Full = (s & STATUS_FD) ? TRUE : FALSE;
    *Mbps = sp == 0 ? 10 : sp == 1 ? 100 : 1000;
}

static void IgbSetFilter(PADAPTER A)
{
    ULONG rctl = RD32(A, RCTL) & ~(RCTL_UPE | RCTL_MPE | RCTL_BAM);
    ULONG f = A->PacketFilter;
    if (f & NDIS_PACKET_TYPE_PROMISCUOUS) rctl |= RCTL_UPE | RCTL_MPE;
    /* multicast: all multicast in hardware, NDIS filters the list (prototype) */
    if (f & (NDIS_PACKET_TYPE_ALL_MULTICAST | NDIS_PACKET_TYPE_MULTICAST)) rctl |= RCTL_MPE;
    if (f & NDIS_PACKET_TYPE_BROADCAST) rctl |= RCTL_BAM;
    WR32(A, RCTL, rctl);
}

const USOSNET_CHIP_OPS IgbOps = {
    "igb",
    IgbReset, IgbReadMac, IgbSetMac, IgbPhyInit, IgbStart, IgbStop,
    IgbIrqEnable, IgbIrqDisable, IgbIrqRead, IgbTransmit, IgbTxReclaim,
    IgbRxPoll, IgbLinkState, IgbSetFilter,
};
