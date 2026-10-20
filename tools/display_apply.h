/* Tested transaction shared by production Win32 adapter and host fakes. GPL-3.0-or-later. */
#ifndef USOS_DISPLAY_APPLY_H
#define USOS_DISPLAY_APPLY_H
#include "display_policy.h"
typedef struct {
    void *context;
    long (*test)(void *,int,const char *);
    int (*backup)(void *);
    long (*apply)(void *,int);
    long (*rollback)(void *);
} UsosDisplayActions;
typedef struct {
    int state,index; /* 0=current, 1=applied, 2=restart, 3=rolled back, 4=backup failure */
    long apply_result,rollback_result;
} UsosDisplayResult;
static UsosDisplayResult usos_display_execute(UsosDisplayMode *m,unsigned count,
    const UsosDisplayRequest *request,int buffers,const UsosDisplayActions *actions) {
    UsosDisplayResult result={0,-1,0,0};
    unsigned tries;
    for(tries=0;tries<count;tries++) {
        UsosDisplayChoice chosen=usos_display_choose(m,count,request,buffers);
        if(chosen.index<0)return result;
        if(actions->test(actions->context,chosen.index,chosen.reason)!=0) {
            m[chosen.index].valid=0;continue;
        }
        result.index=chosen.index;
        if(!actions->backup(actions->context)) {result.state=4;return result;}
        result.apply_result=actions->apply(actions->context,chosen.index);
        if(result.apply_result==0)result.state=1;
        else if(result.apply_result==1)result.state=2;
        else {result.state=3;result.rollback_result=actions->rollback(actions->context);}
        return result;
    }
    return result;
}
#endif
