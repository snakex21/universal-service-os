// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only image identity for the host DISM executor prototype. This does not
// create, open as a disk, mount, resize or write the image.
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class MiniOsHostDismFilePin : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Info {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
        public uint VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info value);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder value,uint size,uint flags);

    readonly string path;
    readonly SafeFileHandle pin;
    readonly uint volume,indexHigh,indexLow;

    static string Canonical(string value) {
        if(String.IsNullOrWhiteSpace(value) || value.StartsWith(@"\\") || value.Length<4 ||
           !Char.IsLetter(value[0]) || value[1]!=':' || (value[2]!='\\' && value[2]!='/') ||
           value.IndexOf(':',2)>=0 || value.IndexOfAny(new char[]{'\0','\r','\n',','})>=0)
            throw new InvalidOperationException("Fully qualified ordinary local path required");
        return Path.GetFullPath(value);
    }
    static void NoReparseAncestors(string value) {
        for(string part=value;!String.IsNullOrEmpty(part);part=Path.GetDirectoryName(part)) {
            var attributes=File.GetAttributes(part); // absent/inaccessible ancestors fail closed
            if((attributes&FileAttributes.ReparsePoint)!=0)throw new InvalidOperationException("Reparse ancestor forbidden");
        }
    }
    static SafeFileHandle Open(string value) {
        // Deny delete/rename while allowing the Windows VHDX driver to write.
        // This does NOT exclude another writer and is not a storage-size bound.
        var result=CreateFile(value,0x80000000,3,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
        if(result.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
        return result;
    }
    static Info Inspect(SafeFileHandle handle,string expected) {
        Info info;
        if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
        if(info.Links!=1 || (info.Attributes&(0x10u|0x200u|0x400u|0x800u|0x4000u))!=0)
            throw new InvalidOperationException("Single-link ordinary non-sparse file required");
        var result=new StringBuilder(32768);
        uint count=GetFinalPathNameByHandle(handle,result,(uint)result.Capacity,0);
        if(count==0 || count>=result.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());
        string final=result.ToString();
        if(!final.StartsWith(@"\\?\",StringComparison.Ordinal))throw new InvalidOperationException("Unsupported final path");
        if(!String.Equals(Canonical(final.Substring(4)),expected,StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Final image path differs");
        return info;
    }
    public MiniOsHostDismFilePin(string value) {
        path=Canonical(value);
        if(!String.Equals(Path.GetExtension(path),".vhdx",StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Explicit VHDX path required");
        NoReparseAncestors(path);
        pin=Open(path);
        try { var data=Inspect(pin,path);volume=data.VolumeSerial;indexHigh=data.IndexHigh;indexLow=data.IndexLow; }
        catch {pin.Dispose();throw;}
    }
    public void AssertUnchanged() {
        NoReparseAncestors(path);
        Info a=Inspect(pin,path);
        using(var fresh=Open(path)) {
            Info b=Inspect(fresh,path);
            if(a.VolumeSerial!=volume || b.VolumeSerial!=volume || a.IndexHigh!=indexHigh || b.IndexHigh!=indexHigh ||
               a.IndexLow!=indexLow || b.IndexLow!=indexLow)throw new InvalidOperationException("Image file identity changed");
        }
    }
    public void Dispose() {pin.Dispose();}
}
