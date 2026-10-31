// SPDX-License-Identifier: GPL-3.0-or-later
// Create a NEW fixed VHDX only; no mount, partition, format or physical disk.
// API ABI from the local Windows SDK um/virtdisk.h. Caller must separately
// enforce an exclusive private workspace and scoped space reservation.
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MiniOsHostDismVhdxNative {
    [StructLayout(LayoutKind.Sequential)] struct StorageType {public uint DeviceId;public Guid VendorId;}
    [StructLayout(LayoutKind.Sequential)] struct CreateV1 {
        public Guid UniqueId;public ulong MaximumSize;public uint BlockSizeInBytes,SectorSizeInBytes;
        public IntPtr ParentPath,SourcePath;
    }
    [StructLayout(LayoutKind.Sequential)] struct CreateParameters {public uint Version;public CreateV1 V1;}
    [DllImport("virtdisk.dll",CharSet=CharSet.Unicode)]
    static extern uint CreateVirtualDisk(ref StorageType type,string path,uint access,IntPtr security,
                                          uint flags,uint provider,ref CreateParameters parameters,
                                          IntPtr overlapped,out IntPtr handle);
    [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CreateDirectory(string path,IntPtr security);
    public static bool AbiValid() {
        return IntPtr.Size==8 && Marshal.SizeOf(typeof(StorageType))==20 &&
               Marshal.OffsetOf(typeof(CreateParameters),"V1").ToInt32()==8 && Marshal.SizeOf(typeof(CreateParameters))==56;
    }
    public static void CreateFreshDirectory(string path) {
        if(!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\") || path.Length<4 || path.IndexOf(':',2)>=0 ||
           path.IndexOfAny(new char[]{'\0','\r','\n',','})>=0)throw new InvalidOperationException("Local new directory required");
        path=Path.GetFullPath(path);
        for(string at=Path.GetDirectoryName(path);!String.IsNullOrEmpty(at);at=Path.GetDirectoryName(at))
            if((File.GetAttributes(at)&FileAttributes.ReparsePoint)!=0)throw new InvalidOperationException("Reparse ancestry forbidden");
        // CreateDirectoryW fails when the directory already exists.
        if(!CreateDirectory(path,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void CreateFreshFixed(string path,ulong bytes) {
        if(!AbiValid() || !Path.IsPathFullyQualified(path) || path.StartsWith(@"\\") ||
           path.Length<4 || path.IndexOf(':',2)>=0 || path.IndexOfAny(new char[]{'\0','\r','\n',','})>=0 ||
           !String.Equals(Path.GetExtension(path),".vhdx",StringComparison.OrdinalIgnoreCase) ||
           bytes<16UL*1024*1024 || bytes>32UL*1024*1024*1024 || bytes%512!=0)
            throw new InvalidOperationException("Fresh bounded local VHDX path and geometry required");
        path=Path.GetFullPath(path);
        for(string at=Path.GetDirectoryName(path);!String.IsNullOrEmpty(at);at=Path.GetDirectoryName(at)) {
            if((File.GetAttributes(at)&FileAttributes.ReparsePoint)!=0)throw new InvalidOperationException("Reparse ancestry forbidden");
        }
        if(File.Exists(path)||Directory.Exists(path))throw new InvalidOperationException("Existing VHDX must never be replaced");
        var type=new StorageType{DeviceId=3,VendorId=new Guid("EC984AEC-A0F9-47E9-901F-71415A66345B")};
        var pars=new CreateParameters{Version=1,V1=new CreateV1{UniqueId=Guid.NewGuid(),MaximumSize=bytes,SectorSizeInBytes=512}};
        IntPtr handle;
        // FULL_PHYSICAL_ALLOCATION only; no sparse, parent, source or attach.
        uint error=CreateVirtualDisk(ref type,path,0x003F0000,IntPtr.Zero,1,0,ref pars,IntPtr.Zero,out handle);
        if(error!=0)throw new Win32Exception((int)error);
        if(handle==IntPtr.Zero || handle==new IntPtr(-1))throw new InvalidOperationException("Invalid created virtual disk handle");
        CloseHandle(handle);
    }
}
