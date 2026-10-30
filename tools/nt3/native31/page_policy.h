/* SPDX-License-Identifier: GPL-3.0-or-later
 * Own policy extracted from USOS nt31_vm_tick; not an input-injection hook.
 * A native boot-time INT16 consumer remains a separate acceptance gate.
 * The caller supplies a full 80x25 VGA text page, stripped of attributes.
 */
enum nt31_page { NT31_NONE,NT31_WELCOME,NT31_EXPRESS,NT31_PARTITION,
    NT31_FILESYSTEM,NT31_LOCATION,NT31_RESTART };
static int nt31_contains(const char *p,unsigned int n,const char *word)
{
    unsigned int i,j;
    for(i=0;i<n;i++){
        for(j=0;word[j] && i+j<n && p[i+j]==word[j];j++);
        if(!word[j])return 1;
    }
    return 0;
}
static enum nt31_page nt31_page(const char *page,unsigned int size)
{
    if(!page || size!=2000)return NT31_NONE;
    if(nt31_contains(page,size,"Press CTRL+ALT+DELETE to restart"))return NT31_RESTART;
    if(nt31_contains(page,size,"Welcome to Setup."))return NT31_WELCOME;
    if(nt31_contains(page,size,"Express Setup (recommended)"))return NT31_EXPRESS;
    if(nt31_contains(page,size,"select the partition where you would like to install")){
        /* Do not blindly accept another disk: require the staged FAT C:. */
        if(nt31_contains(page,size,"C:") && nt31_contains(page,size,"FAT"))return NT31_PARTITION;
        return NT31_NONE;
    }
    if(nt31_contains(page,size,"select a file system option") && nt31_contains(page,size,"FAT"))return NT31_FILESYSTEM;
    if(nt31_contains(page,size,"Choose the location") && nt31_contains(page,size,"\\WINNT"))return NT31_LOCATION;
    return NT31_NONE;
}
struct nt31_page_state { enum nt31_page previous; unsigned long last,attempts; };
static enum nt31_page nt31_answer(struct nt31_page_state *s,const char *page,unsigned int size,unsigned long seconds)
{
    enum nt31_page p=nt31_page(page,size);
    if(p==NT31_NONE || seconds>6UL*3600UL || s->attempts>=720)return NT31_NONE;
    if(p==s->previous && seconds-s->last<30)return NT31_NONE;
    s->previous=p;s->last=seconds;s->attempts++;
    return p;
}
