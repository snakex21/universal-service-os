/* NDIS CPU-speed fix from JHRobotics Patcher9x 0.9.91, MIT, commit d7e2ed7:
 * Copyright (c) 2022 JHRobotics (upstream MIT notice retained in LICENSE.TXT).
 * cpuspeed_ndis_patch_v1/v4 and cpuspeed/speedndis_v1.asm.
 * Corresponding sources/license: tools/vendor/patcher9x/0.9.91/source.zip
 * and LICENSE.TXT. The 18-byte replacement raises the timing loop count
 * and prevents a zero divisor. Its original-code mask accepts both
 * equivalent SUB eax,edx encodings (2B C2 and 29 D0). Search by bytes;
 * offsets vary between NDIS builds. USOS integration: GPL-3.0-or-later. */
#ifndef USOSADD_NDIS_PATCH_H
#define USOSADD_NDIS_PATCH_H
#define UA_NDIS_PATCH_SIZE 18
static const unsigned char ua_ndis_original[UA_NDIS_PATCH_SIZE] = {
    0x10,0x00,0x90,0xe2,0xfe,0xcd,0x20,0x3f,0x00,0x01,0x00,0x2b,0xc2,0xb9,0xe8,0x03,0x00,0x00
};
static const unsigned char ua_ndis_patched[UA_NDIS_PATCH_SIZE] = {
    0x40,0x06,0xe2,0xfe,0xcd,0x20,0x3f,0x00,0x01,0x00,0x29,0xd0,0x75,0x01,0x40,0x6a,0x0a,0x59
};
static int ua_ndis_equal(const unsigned char *a, const unsigned char *b) {
    unsigned j;
    for (j=0;j<UA_NDIS_PATCH_SIZE;j++) if(a[j]!=b[j])return 0;
    return 1;
}
/* 1=one original match, 2=already patched, 0=unknown or ambiguous.
 * No bytes are changed until the caller has saved a backup. */
static int ua_ndis_locate(const unsigned char *data, unsigned long size, unsigned long *offset) {
    unsigned long i;unsigned count=0;int result=0;
    if(size<UA_NDIS_PATCH_SIZE)return 0;
    for(i=0;i<=size-UA_NDIS_PATCH_SIZE;i++) {
        unsigned j;int original=1;
        for(j=0;j<UA_NDIS_PATCH_SIZE;j++) {
            if(j==11) {
                if(!((data[i+11]==0x2b&&data[i+12]==0xc2)||(data[i+11]==0x29&&data[i+12]==0xd0)))original=0;
                j++;
            } else if(data[i+j]!=ua_ndis_original[j])original=0;
        }
        if(original||ua_ndis_equal(data+i,ua_ndis_patched)) {
            if(++count>1)return 0;
            *offset=i;result=original?1:2;
        }
    }
    return result;
}
#endif
