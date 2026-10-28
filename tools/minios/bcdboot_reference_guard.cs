// SPDX-License-Identifier: GPL-3.0-or-later
// Native host-only guards. Public API contracts:
// https://learn.microsoft.com/windows/win32/api/virtdisk/nf-virtdisk-createvirtualdisk
// https://learn.microsoft.com/windows/win32/api/virtdisk/ns-virtdisk-get_virtual_disk_info
// No physical disk open, persistent mount, NVRAM, merge or resize API.
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MiniOsBcdReference {
    [StructLayout(LayoutKind.Sequential)] struct StorageType { public uint DeviceId; public Guid VendorId; }
    [StructLayout(LayoutKind.Sequential)] struct OpenParameters { public uint Version, RWDepth; }
    [StructLayout(LayoutKind.Sequential)] struct CreateV1 {
        public Guid UniqueId; public ulong MaximumSize;
        public uint BlockSizeInBytes, SectorSizeInBytes;
        public IntPtr ParentPath, SourcePath;
    }
    [StructLayout(LayoutKind.Sequential)] struct CreateParameters { public uint Version; public CreateV1 V1; }
    [StructLayout(LayoutKind.Sequential)] struct FileInformation {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    public sealed class VhdIdentity {
        public ulong VirtualBytes; public uint SectorBytes, Subtype;
        public Guid Identifier, ParentIdentifier; public string ParentPath;
    }
    public sealed class AliasIdentity { public uint DiskNumber; public ulong Offset, Bytes; }
    static readonly Guid Vendor = new Guid("EC984AEC-A0F9-47E9-901F-71415A66345B");
    [DllImport("virtdisk.dll",CharSet=CharSet.Unicode)] static extern uint OpenVirtualDisk(ref StorageType t,string p,uint access,uint flags,ref OpenParameters pars,out IntPtr h);
    [DllImport("virtdisk.dll",CharSet=CharSet.Unicode)] static extern uint CreateVirtualDisk(ref StorageType t,string p,uint access,IntPtr security,uint flags,uint provider,ref CreateParameters pars,IntPtr overlapped,out IntPtr h);
    [DllImport("virtdisk.dll")] static extern uint GetVirtualDiskInformation(IntPtr h,ref uint bytes,IntPtr info,out uint used);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string p,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr h,out FileInformation info);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(IntPtr h,StringBuilder path,uint count,uint flags);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(IntPtr h,uint control,IntPtr input,uint inputBytes,byte[] output,uint outputBytes,out uint used,IntPtr overlapped);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint QueryDosDevice(string name,StringBuilder target,uint bytes);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool DefineDosDevice(uint flags,string name,string target);

    static void Result(uint error) { if(error!=0) throw new Win32Exception((int)error); }
    public static string Canonical(string path) {
        if(path.StartsWith(@"\\?\",StringComparison.Ordinal)) path=path.Substring(4);
        if(!Path.IsPathFullyQualified(path)||path.StartsWith(@"\\")||path.Length<4||path.IndexOf(':',2)>=0||path.IndexOfAny(new char[]{'\r','\n','\0',','})>=0)
            throw new InvalidOperationException("Ordinary fully qualified local path required");
        return Path.GetFullPath(path);
    }
    public static void Ordinary(string path,bool readOnly) {
        path=Canonical(path);
        for(string at=path;!String.IsNullOrEmpty(at);at=Path.GetDirectoryName(at)) {
            if((File.Exists(at)||Directory.Exists(at)) && (File.GetAttributes(at)&FileAttributes.ReparsePoint)!=0)
                throw new InvalidOperationException("Reparse path forbidden");
        }
        IntPtr h=CreateFile(path,0x80000000,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
        if(h==new IntPtr(-1)) throw new Win32Exception();
        try {
            FileInformation f; if(!GetFileInformationByHandle(h,out f)) throw new Win32Exception();
            // No sparse, compressed, encrypted, directory or reparse objects;
            // parent is readonly, new child and working BCD copy are writable.
            if(f.Links!=1||(f.Attributes&(0x10u|0x200u|0x400u|0x800u|0x4000u))!=0||((f.Attributes&1)!=0)!=readOnly)
                throw new InvalidOperationException("One ordinary file link with exact readonly state required");
            var final=new StringBuilder(32768);
            uint count=GetFinalPathNameByHandle(h,final,(uint)final.Capacity,0);
            if(count==0||count>=final.Capacity||!String.Equals(Canonical(final.ToString()),path,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Opened file identity/path differs");
        } finally {CloseHandle(h);}
    }
    static byte[] Information(IntPtr h,uint version) {
        const int limit=65536; IntPtr buffer=Marshal.AllocHGlobal(limit);
        try {
            for(int i=0;i<limit;i+=8) Marshal.WriteInt64(buffer,i,0);
            Marshal.WriteInt32(buffer,0,(int)version);
            uint bytes=limit,used; Result(GetVirtualDiskInformation(h,ref bytes,buffer,out used));
            if(used<12||used>limit||bytes>limit) throw new InvalidOperationException("Virtual disk information bounds differ");
            byte[] result=new byte[used]; Marshal.Copy(buffer,result,0,(int)used);return result;
        } finally {Marshal.FreeHGlobal(buffer);}
    }
    static Guid GuidAt(byte[] value,int offset) {
        if(offset<0||value.Length-offset<16)throw new InvalidOperationException("Truncated virtual GUID");
        byte[] data=new byte[16];Array.Copy(value,offset,data,0,16);return new Guid(data);
    }
    public static VhdIdentity Identify(string path) {
        var type=new StorageType{DeviceId=2,VendorId=Vendor};
        var pars=new OpenParameters{Version=1,RWDepth=0};IntPtr h;
        Result(OpenVirtualDisk(ref type,Canonical(path),0x00080000,0,ref pars,out h));
        try {
            var size=Information(h,1);var id=Information(h,2);var kind=Information(h,7);
            if(size.Length<32||kind.Length<12)throw new InvalidOperationException("Truncated virtual geometry");
            var result=new VhdIdentity{VirtualBytes=BitConverter.ToUInt64(size,8),SectorBytes=BitConverter.ToUInt32(size,28),Identifier=GuidAt(id,8),Subtype=BitConverter.ToUInt32(kind,8)};
            if(result.Subtype==4) {
                var parent=Information(h,3);var parentId=Information(h,4);
                if(parent.Length<16||BitConverter.ToUInt32(parent,8)!=1)throw new InvalidOperationException("Unresolved differencing parent");
                int end=12;while(end+1<parent.Length&&(parent[end]!=0||parent[end+1]!=0))end+=2;
                if(end+1>=parent.Length)throw new InvalidOperationException("Unterminated parent location");
                result.ParentPath=Canonical(Encoding.Unicode.GetString(parent,12,end-12));result.ParentIdentifier=GuidAt(parentId,8);
            }
            return result;
        } finally {CloseHandle(h);}
    }
    public static VhdIdentity CreateChild(string parent,string child,ulong expectedBytes) {
        parent=Canonical(parent);child=Canonical(child);Ordinary(parent,true);
        if(Path.GetExtension(parent)!=".vhd"||Path.GetExtension(child)!=".vhd"||File.Exists(child)||Directory.Exists(child)||String.Equals(parent,child,StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Fresh exact VHD child required");
        var before=Identify(parent);
        if(before.Subtype!=3||before.VirtualBytes!=expectedBytes||before.SectorBytes!=512)throw new InvalidOperationException("Accepted dynamic VHD identity differs");
        var type=new StorageType{DeviceId=2,VendorId=Vendor};IntPtr name=Marshal.StringToHGlobalUni(parent),h;
        try {
            var pars=new CreateParameters{Version=1,V1=new CreateV1{UniqueId=Guid.NewGuid(),SectorSizeInBytes=512,ParentPath=name}};
            Result(CreateVirtualDisk(ref type,child,0x003F0000,IntPtr.Zero,0,0,ref pars,IntPtr.Zero,out h));CloseHandle(h);
        } finally {Marshal.FreeHGlobal(name);}
        Ordinary(child,false);var after=Identify(child);
        if(after.Subtype!=4||after.VirtualBytes!=expectedBytes||after.SectorBytes!=512||after.ParentIdentifier!=before.Identifier||!String.Equals(after.ParentPath,parent,StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Created VHD is not the exact differencing child");
        return after;
    }
    public static AliasIdentity VolumeIdentity(string alias) {
        if(alias.Length!=2||alias[1]!=':'||alias[0]<'R'||alias[0]>'Z')throw new InvalidOperationException("Temporary private alias required");
        IntPtr h=CreateFile(@"\\.\"+alias,0,3,IntPtr.Zero,3,0,IntPtr.Zero);
        if(h==new IntPtr(-1))throw new Win32Exception();
        try {
            byte[] device=new byte[12],extent=new byte[32];uint used;
            if(!DeviceIoControl(h,0x002D1080,IntPtr.Zero,0,device,12,out used,IntPtr.Zero)||used!=12||BitConverter.ToUInt32(device,0)!=7)
                throw new InvalidOperationException("Not a disk-backed volume");
            uint number=BitConverter.ToUInt32(device,4);
            if(!DeviceIoControl(h,0x00560000,IntPtr.Zero,0,extent,32,out used,IntPtr.Zero)||used!=32||BitConverter.ToUInt32(extent,0)!=1||BitConverter.ToUInt32(extent,8)!=number)
                throw new InvalidOperationException("Not a single exact virtual extent");
            return new AliasIdentity{DiskNumber=number,Offset=BitConverter.ToUInt64(extent,16),Bytes=BitConverter.ToUInt64(extent,24)};
        } finally {CloseHandle(h);}
    }
    // Compile-only ABI assertion; no native disk API is called by host tests.
    public static bool AbiValid() {
        return IntPtr.Size==8 && Marshal.SizeOf(typeof(StorageType))==20 && Marshal.SizeOf(typeof(OpenParameters))==8
            && Marshal.OffsetOf(typeof(CreateParameters),"V1").ToInt32()==8 && Marshal.SizeOf(typeof(CreateParameters))==56;
    }
}
