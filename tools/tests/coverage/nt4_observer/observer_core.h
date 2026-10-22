/* Own test-only NT4 observer state machine. GPL-3.0-or-later. */
#ifndef NT4_OBSERVER_CORE_H
#define NT4_OBSERVER_CORE_H
enum { OBS_ARM_ABSENT=1, OBS_STAGING_FAILED, OBS_HOOK_CLEANUP_FAILED,
       OBS_ARM_CLEANUP_FAILED, OBS_FIRSTLO_FAILED, OBS_READY,
       OBS_NOT_READY, OBS_TESTNET_FAILED, OBS_TESTNET_DONE };
typedef struct {
 void *context;
 int (*arm)(void *); int (*staged)(void *);
 int (*remove_once)(void *); int (*remove_run)(void *); int (*remove_arm)(void *);
 int (*hidden)(void *,int); int (*ready)(void *); void (*status)(void *,int);
} OBS_OPS;
static int obs_first(OBS_OPS *p) {
 int a,b; void *c=p->context;
 /* No ARM is normal before arming or for a duplicate Run invocation.
  * Preserve READY/TESTNET_DONE and earlier error status; never emit a token. */
 if(!p->arm(c))return OBS_ARM_ABSENT;
 if(!p->staged(c)){p->status(c,OBS_STAGING_FAILED);return OBS_STAGING_FAILED;}
 a=p->remove_once(c);b=p->remove_run(c); /* Always attempt both, never short-circuit. */
 if(!a||!b){p->status(c,OBS_HOOK_CLEANUP_FAILED);return OBS_HOOK_CLEANUP_FAILED;}
 if(!p->remove_arm(c)){p->status(c,OBS_ARM_CLEANUP_FAILED);return OBS_ARM_CLEANUP_FAILED;}
 if(!p->hidden(c,0)){p->status(c,OBS_FIRSTLO_FAILED);return OBS_FIRSTLO_FAILED;}
 p->status(c,OBS_READY);return OBS_READY;
}
static int obs_testnet(OBS_OPS *p) {
 void *c=p->context;
 if(!p->ready(c)){p->status(c,OBS_NOT_READY);return OBS_NOT_READY;}
 if(!p->staged(c)){p->status(c,OBS_STAGING_FAILED);return OBS_STAGING_FAILED;}
 if(!p->hidden(c,1)){p->status(c,OBS_TESTNET_FAILED);return OBS_TESTNET_FAILED;}
 p->status(c,OBS_TESTNET_DONE);return OBS_TESTNET_DONE;
}
#endif
