/* Same finite policy used by the real SCM adapter and native contract tests.
 * No progress loop: each native stop is waited to completion, then queried once. */
typedef struct _CLIENT31_OPS {
    int (*Query)(int,unsigned long *,unsigned long *); /* 2 = absent Browser */
    int (*Stop)(int);
    int (*Disable)(int);
} CLIENT31_OPS;
static int Client31Policy(CLIENT31_OPS *o,int apply)
{
    unsigned long state,start;int i,r;
    for(i=2;i<4;i++)if(o->Query(i,&state,&start)!=1||state!=4)return 0;
    for(i=0;i<2;i++){
        r=o->Query(i,&state,&start);if(!i&&r==2)continue;
        if(r!=1)return 0;
        if(apply){
            if(state!=1){if(!o->Stop(i)||o->Query(i,&state,&start)!=1||state!=1)return 0;}
            if(start!=4){if(!o->Disable(i)||o->Query(i,&state,&start)!=1||state!=1||start!=4)return 0;}
        }
        if(state!=1||start!=4)return 0;
    }
    for(i=2;i<4;i++)if(o->Query(i,&state,&start)!=1||state!=4)return 0;
    return 1;
}
