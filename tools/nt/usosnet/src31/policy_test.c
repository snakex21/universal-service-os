/* Native host execution of the exact pure policy used by the driver. */
#include "u31_policy.h"
#include "cfg31_policy.h"
__declspec(dllimport) void __stdcall ExitProcess(unsigned long);
#define CHECK(x) do { if(!(x))ExitProcess(__LINE__); } while(0)
static int calls;
static int __cdecl NoteMock(void *filter,void *context){CHECK(filter!=0);CHECK(context==&calls);calls++;return 1;}
void __cdecl entry(void)
{
    unsigned char own[6]={0x52,0x54,0,0x55,0x53,1},other[6]={0x52,0x54,0,0x55,0x53,2};
    unsigned char broadcast[6]={255,255,255,255,255,255},multicast[6]={1,0,0x5e,0,0,1};
    CHECK(U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xfebc0000,0));
    CHECK(U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xfebc0004,0));
    CHECK(!U31PciValid(2,0,5,0,0x10c98086,0x02000001,0,0xfebc0000,0));
    CHECK(!U31PciValid(0,0,5,0,0x10c98086,0x02000001,0,0xfebc0000,0));
    CHECK(!U31PciValid(1,256,5,0,0x10c98086,0x02000001,0,0xfebc0000,0));
    CHECK(!U31PciValid(1,0,32,0,0x10c98086,0x02000001,0,0xfebc0000,0));
    CHECK(!U31PciValid(1,0,5,8,0x10c98086,0x02000001,0,0xfebc0000,0));
    CHECK(!U31PciValid(1,0,5,0,0x15398086,0x02000001,0,0xfebc0000,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x01000001,0,0xfebc0000,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02010001,0,0xfebc0000,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0x10000,0xfebc0000,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xfebc0001,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xfebc0002,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xfebc0006,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xfebc0004,1));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xfebc1000,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0,0));
    CHECK(!U31PciValid(1,0,5,0,0x10c98086,0x02000001,0,0xffffffff,0));
    CHECK(U31DmaValid(0x1000,0,4096));
    CHECK(U31DmaValid(0xfff000,0,4096));
    CHECK(!U31DmaValid(0xfff000,0,4097));
    CHECK(!U31DmaValid(0x1000000,0,1));
    CHECK(!U31DmaValid(0x1000,1,4096));
    CHECK(!U31DmaValid(0x1000,0,0));
    CHECK(U31NeedsLoopback(own,own));
    CHECK(U31NeedsLoopback(broadcast,own));
    CHECK(U31NeedsLoopback(multicast,own));
    CHECK(!U31NeedsLoopback(other,own));
    CHECK(!U31NoteOpenIfReady(0,0,0,NoteMock,&calls));CHECK(calls==0);
    CHECK(!U31NoteOpenIfReady(0,0,1,NoteMock,&calls));CHECK(calls==0);
    CHECK(!U31NoteOpenIfReady(0,&calls,0,NoteMock,&calls));CHECK(calls==0);
    CHECK(!U31NoteOpenIfReady(1,&calls,1,NoteMock,&calls));CHECK(calls==0);
    CHECK(U31NoteOpenIfReady(0,&calls,1,NoteMock,&calls));CHECK(calls==1);
    CHECK(U31OwnService("USOSNET31")==1);
    CHECK(U31OwnService("usosnet31")==1);
    CHECK(U31OwnService("USOSNET3101")==2);
    CHECK(U31OwnService("usosnet3101")==2);
    CHECK(U31OwnService("USOSNET311")==3);
    CHECK(U31OwnService("USOSNET3102")==3);
    CHECK(U31OwnService("USOSNET3101x")==3);
    CHECK(U31OwnService("NDISLoop")==0);
    CHECK(!U31OneOwnAdapter(0,0));
    CHECK(!U31OneOwnAdapter(1,0));
    CHECK(!U31OneOwnAdapter(0,1));
    CHECK(U31OneOwnAdapter(1,1));
    CHECK(!U31OneOwnAdapter(1,2));
    CHECK(!U31OneOwnAdapter(2,1));
    ExitProcess(0);
}
