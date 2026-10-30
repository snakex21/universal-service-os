/* Pure checked policy shared by the actual NT31 core and native host tests. */
#ifndef U31_POLICY_H
#define U31_POLICY_H
typedef int (__cdecl *U31_NOTE_OPEN)(void *,void *);
static int U31NoteOpenIfReady(int removing,void *filter,int started,U31_NOTE_OPEN note,void *context)
{
    if(removing || !filter || !started)return 0;
    return note(filter,context);
}
static int U31PciValid(unsigned long cpus,unsigned long bus,unsigned long device,unsigned long function,
    unsigned long id,unsigned long cls,unsigned long header,unsigned long bar,unsigned long high)
{
    unsigned long start=bar&~15UL;
    /* 82576 (QEMU igb) and I211 (X470 onboard, 2026-10-30) */
    return cpus==1 && bus<=255 && device<=31 && function<=7 && (id==0x10c98086 || id==0x15398086) &&
        (cls>>8)==0x020000 && ((header>>16)&0x7f)==0 && !(bar&1) &&
        ((bar&6)==0 || (bar&6)==4) && !high && start && start!=0xfffffff0 &&
        !(start&0x1ffff) && start<=0xffffffffUL-0x20000UL;
}
/* Below 4 GiB (both chips are 64-bit bus masters; MAXMEM=64 on NT 3.1). */
static int U31DmaValid(unsigned long low,unsigned long high,unsigned long length)
{
    return !high && length && length-1<=0xffffffffUL-low;
}
/* Config writes the backend may make: Command (word), the I210/I211 PLL
 * erratum's PMCSR (word at the PM capability + 4) and the BAR restore after
 * D3hot -> D0 (dwords 0x10..0x24). Everything else is refused. */
static int U31PciWriteAllowed(int i211,unsigned long pmcsr,unsigned long offset,unsigned long length)
{
    if(offset==4 && length==2)return 1;
    if(!i211)return 0;
    if(pmcsr && offset==pmcsr && length==2)return 1;
    return length==4 && offset>=0x10 && offset<=0x24 && !(offset&3);
}
static int U31NeedsLoopback(const unsigned char *frame,const unsigned char *mac)
{
    unsigned int i;if(frame[0]&1)return 1;
    for(i=0;i<6;i++)if(frame[i]!=mac[i])return 0;
    return 1;
}
#endif
