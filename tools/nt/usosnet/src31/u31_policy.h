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
    return cpus==1 && bus<=255 && device<=31 && function<=7 && id==0x10c98086 &&
        (cls>>8)==0x020000 && ((header>>16)&0x7f)==0 && !(bar&1) &&
        ((bar&6)==0 || (bar&6)==4) && !high && start && start!=0xfffffff0 &&
        !(start&0x1ffff) && start<=0xffffffffUL-0x20000UL;
}
static int U31DmaValid(unsigned long low,unsigned long high,unsigned long length)
{
    return !high && length && low<=0xffffffUL && length-1<=0xffffffUL-low;
}
static int U31NeedsLoopback(const unsigned char *frame,const unsigned char *mac)
{
    unsigned int i;if(frame[0]&1)return 1;
    for(i=0;i<6;i++)if(frame[i]!=mac[i])return 0;
    return 1;
}
#endif
