/* NT351's NDIS-owned CheckForHang timer is nominally 2000 ms. Delayed
 * callbacks make these diagnostic seconds approximate, never a wall clock.
 * No timer is created or rearmed by usosnet351. */
#ifndef USOSNET351_POLICY_H
#define USOSNET351_POLICY_H
#define USOSNET351_CHECK_SECONDS 2UL

static __inline unsigned long Usosnet351StallNext(unsigned long previous)
{
    /* Saturation keeps a long stall from wrapping and reporting again. */
    return previous >= 3 ? previous : previous + USOSNET351_CHECK_SECONDS;
}

static __inline int Usosnet351PeriodicLog(unsigned long sec)
{
    /* The existing second round at nominal65 lands on the next check66. */
    return sec == 30 || sec == 66 || (sec && sec % 300 == 0);
}
#endif
