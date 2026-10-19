/*
 * usosnet - interrupt claim rule for the igb family (shared legacy INTx).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Plain C without NDIS types so tools/tests/test_usosnet.py can compile it
 * with a host compiler. The caller (IgbIrqRead) must not read ICR at all
 * while the driver keeps the chip masked (Masked != 0): the line may be
 * shared, and a masked igb cannot be the device that asserts it.
 */
#ifndef USOSNET_IRQ_H
#define USOSNET_IRQ_H

#define USOSNET_ICR_INT_ASSERTED 0x80000000UL

/* ICR value -> cause word to queue for the DPC, 0 = not ours.
 * Ours only when the chip says it drives INTx (ICR.INT_ASSERTED, Intel
 * I210/I211 and 82576 datasheets, "Interrupt Cause Read"); an all-ones
 * read means the device is gone (surprise removal / no decode). */
static __inline unsigned long UsosnetIrqClaim(unsigned long Masked, unsigned long Icr)
{
    if (Masked) return 0;
    if (Icr == 0xFFFFFFFFUL) return 0;
    if (!(Icr & USOSNET_ICR_INT_ASSERTED)) return 0;
    return Icr;
}

/* IRQ watchdog: 1 = interrupts are not reaching the ISR, switch to timer
 * polling and mask the chip (a misrouted INTx then cannot keep another
 * line asserted). With working INTx the ISR always wins against the 20 ms
 * timer: the link coming up after PhyInit raises LSC, every frame RXT0. So
 * "no claimed interrupt for 5 s although the timer found frames or the
 * link is up" means lost interrupts (X470 + Me round 1: no RX at all). */
static __inline int UsosnetIrqBroken(unsigned long Sec, unsigned long IsrClaimed,
                                     unsigned long RxByTimer, unsigned long LinkUp)
{
    if (IsrClaimed || Sec < 5) return 0;
    return (RxByTimer || LinkUp) ? 1 : 0;
}

#endif
