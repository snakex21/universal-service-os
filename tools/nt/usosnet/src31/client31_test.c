typedef unsigned long DWORD;
__declspec(dllimport) void __stdcall ExitProcess(DWORD);
#include "client31_policy.h"
static unsigned long states[4],starts[4];static int fault,stops,disables;
static int query(int id,unsigned long *s,unsigned long *t){if(fault==1&&id==0)return 2;if(fault==2&&id==1)return 0;*s=states[id];*t=starts[id];return 1;}
static int stop(int id){stops++;if(fault==3)return 0;if(fault!=4)states[id]=1;return 1;}
static int disable(int id){disables++;if(fault==5)return 0;if(fault!=6)starts[id]=4;return 1;}
static void reset(void){int i;for(i=0;i<4;i++){states[i]=4;starts[i]=2;}fault=stops=disables=0;}
#define CHECK(x) if(!(x))ExitProcess(__LINE__)
void __cdecl entry(void)
{
    CLIENT31_OPS o={query,stop,disable};int i;
    reset();CHECK(Client31Policy(&o,1));CHECK(stops==2&&disables==2&&states[2]==4&&states[3]==4);
    CHECK(Client31Policy(&o,0));CHECK(Client31Policy(&o,1)&&stops==2&&disables==2);
    reset();CHECK(!Client31Policy(&o,0)&&stops==0&&disables==0);
    reset();fault=1;CHECK(Client31Policy(&o,1)&&stops==1&&disables==1);
    for(i=2;i<=6;i++){reset();fault=i;CHECK(!Client31Policy(&o,1));CHECK(stops<=1&&disables<=1);}
    reset();states[2]=1;CHECK(!Client31Policy(&o,1)&&stops==0&&disables==0);
    reset();states[3]=1;CHECK(!Client31Policy(&o,1)&&stops==0&&disables==0);
    ExitProcess(0);
}
