/* Portable per-step retry policy used by the target and host fakes. GPL-3.0-or-later. */
#ifndef USOS_LAN_STATE_H
#define USOS_LAN_STATE_H
#define USOS_LAN_MAX_TRIES 3
#define USOS_LAN_IE 1u
#define USOS_LAN_FAVORITE 2u
#define USOS_LAN_DEFAULT 4u
#define USOS_LAN_DIALUP 8u
#define USOS_LAN_SHORTCUTS 16u
#define USOS_LAN_SYSTEM 32u
#define USOS_LAN_DEFAULT_FAVORITE 64u
#define USOS_LAN_ALL 127u
typedef struct { unsigned long magic,config,tries,done; } UsosLanState;
static int usos_lan_attempt(UsosLanState *s) {if(s->tries>=USOS_LAN_MAX_TRIES)return 0;s->tries++;return 1;}
static int usos_lan_step(UsosLanState *s,unsigned bit,int (*action)(void *),void *context) {
    if(s->done&bit)return 1;
    if(!action(context))return 0;
    s->done|=bit;return 1;
}
static void usos_lan_refresh(UsosLanState *s) {
    s->tries=0;s->done&=~(USOS_LAN_IE|USOS_LAN_DEFAULT|USOS_LAN_DIALUP|USOS_LAN_SHORTCUTS|USOS_LAN_SYSTEM);
}
#endif
