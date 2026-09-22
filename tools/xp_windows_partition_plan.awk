# Plan one shared Setup/Windows volume from a validated guard snapshot.
# Never selects an existing partition and never modifies the input disk.
function fail(message) { print "[XP_WINDOWS_PLAN] STOP: " message > "/dev/stderr"; failed=1; exit 1 }
function number(value) { return value ~ /^[0-9]+$/ }
function hex32le(value, offset,    i,byte,result,c,n) {
    result=0
    for(i=0;i<4;i++) {
        byte=0
        for(n=0;n<2;n++) {
            c=index("0123456789abcdef",substr(tolower(value),offset+i*2+n,1))-1
            if(c<0) fail("invalid partition entry")
            byte=byte*16+c
        }
        result+=byte*(256^i)
    }
    return result
}
function consider(first,last,    start,end) {
    start=int((first+2047)/2048)*2048
    end=int(last/2048)*2048
    # Keep automatically placed XP within 128 GiB, including RTM-era limitations.
    if(end>268435456) end=268435456
    # Extend the guarded staging extent only into the same contiguous free gap.
    if(start<=setup_start && end>=setup_start+4194304) {
        best_start=setup_start; best_size=end-setup_start
    }
}
BEGIN { FS="="; count=0; failed=0 }
{ if(NF>=2) { key=$1; sub(/^[^=]*=/, ""); values[key]=$0 } }
END {
    if(failed) exit 1
    if(values["version"]!="2") fail("unsupported guard snapshot")
    size=values["size_bytes"]
    setup_start=values["xpsetup_start_lba"]
    setup_slot=values["xpsetup_slot"]
    if(!number(size)||!number(setup_start)||!number(setup_slot)) fail("missing numeric snapshot fields")
    size+=0; setup_start+=0; setup_slot+=0
    if(size<10737418240||size>=2199023255040||size%512!=0) fail("unsupported target size")
    if(values["xpsetup_sectors"]!="4194304"||setup_slot<1||setup_slot>4) fail("invalid XPSETUP reservation")
    if(setup_start<2048||setup_start%2048!=0||setup_start+4194304>size/512) fail("XPSETUP outside disk")
    windows_slot=setup_slot
    for(slot=1;slot<=4;slot++) {
        entry=values["mbr_entry" slot]
        if(length(entry)!=32||entry~/[^0-9a-fA-F]/) fail("invalid partition snapshot")
        if(entry=="00000000000000000000000000000000") {
        } else {
            if(substr(entry,9,2)=="00"||tolower(substr(entry,9,2))=="ee") fail("unsupported occupied partition type")
            first=hex32le(entry,17); sectors=hex32le(entry,25)
            if(first<1||sectors<1||first+sectors>size/512) fail("invalid occupied extent")
            if(!(slot==setup_slot && values["xpsetup_reuse"]=="yes")) {
                starts[++count]=first; ends[count]=first+sectors
            }
        }
    }
    if(windows_slot==0) fail("no free primary slot for Windows")
    if(values["xpsetup_reuse"]=="no") {
        if(values["mbr_entry" setup_slot]!="00000000000000000000000000000000") fail("reserved XPSETUP slot occupied")
    } else if(values["xpsetup_reuse"]=="yes") {
        entry=values["mbr_entry" setup_slot]
        if(tolower(substr(entry,9,2))!="0c"||hex32le(entry,17)!=setup_start||hex32le(entry,25)!=4194304) fail("reused XPSETUP does not match reservation")
    } else fail("invalid reuse state")
    for(i=1;i<=count;i++) for(j=i+1;j<=count;j++) if(starts[j]<starts[i]) {
        swap=starts[i]; starts[i]=starts[j]; starts[j]=swap
        swap=ends[i]; ends[i]=ends[j]; ends[j]=swap
    }
    cursor=1; best_start=0; best_size=0
    for(i=1;i<=count;i++) {
        if(starts[i]<cursor) fail("overlapping reserved extents")
        consider(cursor,starts[i]); cursor=ends[i]
    }
    consider(cursor,size/512)
    if(best_size<16777216) fail("need at least 8 GiB contiguous space for Windows and Setup")
    print "version=2"
    print "windows_slot=" windows_slot
    printf "windows_start_lba=%.0f\nwindows_sectors=%.0f\n",best_start,best_size
    print "policy=single-volume-native-ntfs"
}
