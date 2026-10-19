/* Strict readers for the known USOSVESA.INF format, no CRT. GPL-3.0-or-later. */
#ifndef USOS_DISPLAY_INF_H
#define USOS_DISPLAY_INF_H
static char usos_display_lower(char c) { return c>='A'&&c<='Z'?(char)(c+32):c; }
static int usos_display_prefix(const char *s,const char *prefix) {
    while(*prefix) if(usos_display_lower(*s++)!=usos_display_lower(*prefix++))return 0;
    return 1;
}
static char *usos_display_append(char *to,const char *s) { while(*s)*to++=*s++;*to=0;return to; }
static char *usos_display_decimal(char *to,unsigned long n) {
    char reverse[12];unsigned count=0;do{reverse[count++]=(char)('0'+n%10);n/=10;}while(n);
    while(count)*to++=reverse[--count];*to=0;return to;
}
static int usos_display_inf_has(const char *text,unsigned long w,unsigned long h,unsigned long bpp) {
    char pattern[64],*end=usos_display_append(pattern,"HKR,\"MODES\\");
    end=usos_display_decimal(end,bpp);end=usos_display_append(end,"\\");
    end=usos_display_decimal(end,w);end=usos_display_append(end,",");
    end=usos_display_decimal(end,h);usos_display_append(end,"\"");
    while(*text) {
        while(*text==' '||*text=='\t')text++;
        if(usos_display_prefix(text,pattern))return 1;
        while(*text&&*text!='\n')text++;if(*text)text++;
    }
    return 0;
}
static unsigned long usos_display_inf_limit(const char *text) {
    unsigned long result=0;unsigned count=0;
    const char *prefix="HKLM,Software\\vmdisp9x\\vesa,VRAMLimit,,";
    while(*text) {
        while(*text==' '||*text=='\t')text++;
        if(usos_display_prefix(text,prefix)) {
            const char *p=prefix;unsigned long n=0;int quoted=0;
            while(*p++){text++;}
            while(*text==' '||*text=='\t')text++;
            if(*text=='\"'){quoted=1;text++;}
            if(*text<'0'||*text>'9')return 0;
            while(*text>='0'&&*text<='9'){n=n*10+(unsigned long)(*text++-'0');if(n>8192)return 0;}
            if(quoted){if(*text!='\"')return 0;text++;}
            while(*text==' '||*text=='\t'||*text=='\r')text++;
            if(*text&&*text!='\n'&&*text!=';')return 0;
            if(!n)return 0;result=n>128?128:n;count++;
        }
        while(*text&&*text!='\n')text++;if(*text)text++;
    }
    return count==1?result*1024UL*1024:0;
}
#endif
