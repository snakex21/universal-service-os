/* Exact original NT31 NCPA instance01 observed in R24, not a prefix match. */
#ifndef USOS_CFG31_POLICY_H
#define USOS_CFG31_POLICY_H
static int U31OwnService(const char *name)
{
    const char *prefix="USOSNET31";unsigned int i;char c;
    for(i=0;prefix[i];i++){
        c=name[i];if(c>='a'&&c<='z')c-=32;
        if(c!=prefix[i])return 0;
    }
    if(!name[i])return 1;
    if(name[i]=='0'&&name[i+1]=='1'&&!name[i+2])return 2;
    return 3;
}
static int U31OneOwnAdapter(unsigned long roots,unsigned long instances)
{return roots==1&&instances==1;}
#endif
