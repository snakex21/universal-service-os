/* SPDX-License-Identifier: GPL-3.0-or-later */
static int nt31_year(const char *s)
{
    /* NT 3.1 MAIN.CPL shows two digits ("26"; X470 2026-10-31), later
       builds four. */
    int i,y=0;
    for(i=0;s[i];i++){if(i==4 || s[i]<'0' || s[i]>'9')return 0;y=y*10+s[i]-'0';}
    if(i==2)return 1;
    return i==4 && y>=1990 && y<=2099;
}
static int nt31_domain(const char *s)
{
    int i;
    for(i=0;s[i];i++){
        if(i==15 || !((s[i]>='A' && s[i]<='Z') || (s[i]>='0' && s[i]<='9') || s[i]=='-'))return 0;
    }
    return i>0 && s[0]!='-' && s[i-1]!='-';
}
