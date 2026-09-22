/* Only calls the pure selector. No Setup, disk, registry or boot API is run. */
#include "../windows_vista_install.c"
__declspec(dllexport) int select_scenario(unsigned old_count,const unsigned *old_ids,unsigned current_count,const unsigned *current_ids){
 Esp previous[8]={0},current[8]={0};
 if(old_count>8||current_count>8)return -2;
 for(unsigned i=0;i<old_count;i++){previous[i].disk=old_ids[i]>>16;previous[i].id.Data1=old_ids[i]&65535;}
 for(unsigned i=0;i<current_count;i++){current[i].disk=current_ids[i]>>16;current[i].id.Data1=current_ids[i]&65535;}
 return choose_esp(previous,old_count,current,current_count);
}
BOOL WINAPI dll_entry(HINSTANCE module,DWORD reason,LPVOID reserved){(void)module;(void)reason;(void)reserved;return TRUE;}
__declspec(dllexport) unsigned servicing_answer(WCHAR *out,unsigned capacity,const WCHAR *cab){return vista_kmdf_answer(out,capacity,cab);}
__declspec(dllexport) int check_framework(const WCHAR *root){
 return verify_offline_kmdf(root);
}
__declspec(dllexport) int select_profile_scenario(unsigned mode){
 BootProfile p={0};p.disk_id.Data1=99;p.esp_id.Data1=2;p.disk_size=120034123776ULL;
 Esp current[3]={0};for(unsigned i=0;i<3;i++){current[i].disk_id=p.disk_id;current[i].disk_size=p.disk_size;current[i].id.Data1=i+1;}
 if(mode==1)current[1].disk_id.Data1=100;
 if(mode==2)current[1].disk_size--;
 if(mode==3)current[1].id.Data1=9;
 if(mode==4)current[2]=current[1];
 if(mode==5){current[1].disk=27;current[1].number=12;}
 return choose_pinned_esp(&p,current,3,current,3);
}
/* Production profile selector, exercised over changing partition snapshots. */
__declspec(dllexport) int select_recreated_scenario(unsigned mode){
 BootProfile p={0};p.disk_id.Data1=99;p.esp_id.Data1=2;p.disk_size=120034123776ULL;
 Esp previous[3]={0},current[4]={0};unsigned old_count=3,count=1;
 for(unsigned i=0;i<3;i++){previous[i].disk=1;previous[i].disk_id=p.disk_id;previous[i].disk_size=p.disk_size;previous[i].id.Data1=i+1;}
 current[0]=previous[0];current[0].id.Data1=8;
 switch(mode){
 case 0:count=0;break; /* All partitions deleted. */
 case 1:break; /* New ESP replaces all old ones. */
 case 2:current[1]=previous[0];current[1].disk_id.Data1=55;count=2;break;
 case 3:current[1]=current[0];current[1].id.Data1=9;count=2;break;
 case 4:current[0]=previous[0];break; /* Only a stale old ESP remains. */
 case 5:old_count=0;break; /* Disk was already empty at launch. */
 case 6:previous[0]=current[0];old_count=1;break; /* New session after reinstall. */
 case 7:current[0].disk_id.Data1=55;break; /* Other disk, same size. */
 case 8:current[0].disk_size--;break;
 case 9:current[0].disk=27;current[0].number=12;break;
 case 10:current[1]=previous[0];count=2;break; /* New plus stale. */
 case 11:current[1]=current[0];count=2;break; /* Duplicate GUID. */
 case 12:current[1]=previous[1];count=2;break; /* Preferred ESP still present. */
 default:return -2;
 }
 return choose_pinned_esp(&p,previous,old_count,current,count);
}
