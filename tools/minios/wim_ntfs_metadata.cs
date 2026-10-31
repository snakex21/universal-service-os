// SPDX-License-Identifier: GPL-3.0-or-later
// HOST-only read oracle. No setter, mount, format, write or device-open API.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public static class MiniOsWimMetadata {
    [StructLayout(LayoutKind.Sequential)] struct BasicInfo {
        public long Created, Accessed, Modified, Changed;
        public uint Attributes;
    }
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Modified;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct Privilege { public uint Count; public Luid Id; public uint Attributes; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out FileInfo info);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int kind, out BasicInfo info, uint bytes);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr input, uint inputSize, byte[] output, uint outputSize, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFileAttributes(string path);
    [DllImport("kernel32.dll", EntryPoint="GetFileInformationByHandleEx", SetLastError=true)]
    static extern bool GetFileInformationBuffer(SafeFileHandle h,int kind,byte[] data,uint bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct IoStatus { public IntPtr Status; public UIntPtr Information; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationFile(SafeFileHandle h,out IoStatus status,byte[] data,uint bytes,int kind);
    [DllImport("ntdll.dll")] static extern int NtQueryEaFile(SafeFileHandle h,out IoStatus status,byte[] data,uint bytes,[MarshalAs(UnmanagedType.U1)] bool single,IntPtr list,uint listBytes,IntPtr index,[MarshalAs(UnmanagedType.U1)] bool restart);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetKernelObjectSecurity(SafeFileHandle h, uint fields, byte[] data, uint bytes, out uint needed);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid value);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref Privilege requested, uint bytes, out Privilege old, out uint returned);

    public sealed class SecurityPrivilege : IDisposable {
        IntPtr token; Privilege oldSecurity,oldBackup; bool changedSecurity,changedBackup;
        void Enable(string name,out Privilege old) {
            Luid id;
            if (!LookupPrivilegeValue(null,name,out id)) throw new Win32Exception();
            Privilege request=new Privilege {Count=1,Id=id,Attributes=2};uint returned;
            bool ok=AdjustTokenPrivileges(token,false,ref request,(uint)Marshal.SizeOf<Privilege>(),out old,out returned);
            int error=Marshal.GetLastWin32Error();
            if(!ok || error!=0) throw new Win32Exception(error,"Cannot enable read-only oracle privilege "+name);
        }
        public SecurityPrivilege() {
            try {
                if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception();
                Enable("SeSecurityPrivilege",out oldSecurity);changedSecurity=true;
                // Only read handles with BACKUP_SEMANTICS below. Never enable
                // SeRestorePrivilege or change any target ACL to obtain access.
                Enable("SeBackupPrivilege",out oldBackup);changedBackup=true;
            } catch { Dispose(); throw; }
        }
        public void Dispose() {
            if (token==IntPtr.Zero) return;
            int failure=0;Privilege unused;uint returned;
            try {
                if(changedBackup && !AdjustTokenPrivileges(token,false,ref oldBackup,(uint)Marshal.SizeOf<Privilege>(),out unused,out returned)) failure=Marshal.GetLastWin32Error();
                if(changedSecurity && !AdjustTokenPrivileges(token,false,ref oldSecurity,(uint)Marshal.SizeOf<Privilege>(),out unused,out returned)) failure=Marshal.GetLastWin32Error();
            } finally { CloseHandle(token); token=IntPtr.Zero; }
            if(failure!=0) throw new Win32Exception(failure,"Cannot restore oracle privilege state");
        }
    }

    public sealed class DataStream {
        public string Name;
        public ulong Size;
        public string Sha1;
        public string Kind;
    }
    public sealed class Metadata {
        public uint Attributes, Links;
        public ulong Created, Accessed, Modified, Changed;
        public string FileId, SecuritySha256, SecurityHex, ReparseDataHex;
        public uint ReparseTag;
        public DataStream[] Streams;
    }
    public sealed class SecurityComparison {
        public bool Passed, ApiReorderedSd, RawBytesEqual;
        public string ExpectedSha256, NativeSha256, Reason;
    }
    public static string ShortName(string root,string relative) {
        using(SafeFileHandle h=Open(CheckedPath(root,relative),0x80)) {
            byte[] data=new byte[1024];IoStatus status;
            int result=NtQueryInformationFile(h,out status,data,(uint)data.Length,21);
            if(result==unchecked((int)0xc0000034)) return null;
            if(result<0) throw new InvalidOperationException("FileAlternateNameInformation failed: "+result.ToString("x8"));
            uint count=BitConverter.ToUInt32(data,0);
            if(count==0 || count>24 || count%2!=0) throw new InvalidOperationException("Invalid alternate-name length");
            return System.Text.Encoding.Unicode.GetString(data,4,(int)count);
        }
    }
    public static string ObjectId(string root,string relative) {
        using(SafeFileHandle h=Open(CheckedPath(root,relative),0x80)) {
            byte[] data=new byte[64];uint returned;
            if(!DeviceIoControl(h,0x9009c,IntPtr.Zero,0,data,64,out returned,IntPtr.Zero)) throw new Win32Exception();
            if(returned!=64) throw new InvalidOperationException("Object ID native length differs");
            return Hex(data);
        }
    }
    static string EaCanonical(byte[] data,bool wim) {
        var entries=new SortedDictionary<string,string>(StringComparer.Ordinal);
        int at=0;
        while(at<data.Length) {
            int header=wim?4:8;
            if(data.Length-at<header+2) throw new InvalidOperationException("EA header truncated");
            int value=BitConverter.ToUInt16(data,at+(wim?0:6));
            int name=data[at+(wim?2:5)],flags=data[at+(wim?3:4)];
            int length=header+name+1+value;
            if(name==0 || length>data.Length-at || data[at+header+name]!=0 || (flags&~0x80)!=0) throw new InvalidOperationException("Invalid native/oracle EA entry");
            string key=System.Text.Encoding.Latin1.GetString(data,at+header,name).ToUpperInvariant();
            if(entries.ContainsKey(key)) throw new InvalidOperationException("Duplicate native/oracle EA name");
            byte[] bytes=new byte[value];Array.Copy(data,at+header+name+1,bytes,0,value);
            entries.Add(key,flags.ToString("x2")+":"+Hex(bytes));
            uint next=wim?0:BitConverter.ToUInt32(data,at);
            if(!wim && next==0) {
                if(data.Length-at-length>3) throw new InvalidOperationException("Unexpected trailing EA bytes");
                for(int i=at+length;i<data.Length;i++) if(data[i]!=0) throw new InvalidOperationException("Nonzero native EA padding");
                break;
            }
            if(wim) at+=length;
            else { if(next%4!=0 || next<length || next>data.Length-at) throw new InvalidOperationException("Invalid native EA continuation");at+=(int)next; }
        }
        var text=new System.Text.StringBuilder();
        foreach(var entry in entries) text.Append(entry.Key).Append('=').Append(entry.Value).Append('\n');
        return text.ToString();
    }
    public static string ExpectedEa(string wimHex) { return EaCanonical(Convert.FromHexString(wimHex),true); }
    public static string ExtendedAttributes(string root,string relative) {
        using(SafeFileHandle h=Open(CheckedPath(root,relative),0x8)) { // FILE_READ_EA
            byte[] data=new byte[65536];IoStatus status;
            int result=NtQueryEaFile(h,out status,data,(uint)data.Length,false,IntPtr.Zero,0,IntPtr.Zero,true);
            if(result<0) throw new InvalidOperationException("NtQueryEaFile failed: "+result.ToString("x8"));
            ulong count=status.Information.ToUInt64();
            if(count==0 || count>(ulong)data.Length) throw new InvalidOperationException("Invalid returned EA length");
            Array.Resize(ref data,(int)count);return EaCanonical(data,false);
        }
    }
    sealed class SdParts {
        public byte Revision, RmControl;
        public ushort Control;
        public byte[][] Sections=new byte[4][];
    }
    static bool EqualBytes(byte[] a,byte[] b) {
        if(a==null || b==null) return a==b;
        if(a.Length!=b.Length) return false;
        for(int i=0;i<a.Length;i++) if(a[i]!=b[i]) return false;
        return true;
    }
    static SdParts SplitSecurity(byte[] raw) {
        if(raw.Length<20 || raw.Length>1048576 || raw[0]!=1 || (BitConverter.ToUInt16(raw,2)&0x8000)==0) throw new InvalidOperationException("Invalid self-relative SD header");
        SdParts parts=new SdParts {Revision=raw[0],RmControl=raw[1],Control=BitConverter.ToUInt16(raw,2)};
        uint[] starts=new uint[4],ends=new uint[4];
        for(int i=0;i<4;i++) {
            uint offset=BitConverter.ToUInt32(raw,4+i*4);
            if(offset==0) continue;
            if(offset<20 || offset%4!=0 || offset>(uint)raw.Length-8) throw new InvalidOperationException("SD section outside descriptor");
            int at=(int)offset,size;
            if(i<2) {
                if(raw[at]!=1 || raw[at+1]>15) throw new InvalidOperationException("Invalid SID section");
                size=8+4*raw[at+1];
            } else {
                int presence=i==2 ? 0x10 : 4;
                if((parts.Control&presence)==0 || (raw[at]!=2 && raw[at]!=4)) throw new InvalidOperationException("Invalid ACL presence/revision");
                size=BitConverter.ToUInt16(raw,at+2);
                if(size<8 || at+size>raw.Length) throw new InvalidOperationException("ACL outside descriptor");
                int cursor=at+8,count=BitConverter.ToUInt16(raw,at+4);
                for(int ace=0;ace<count;ace++) {
                    if(cursor+4>at+size) throw new InvalidOperationException("ACE header outside ACL");
                    int length=BitConverter.ToUInt16(raw,cursor+2);
                    if(length<4 || length%4!=0 || cursor+length>at+size) throw new InvalidOperationException("ACE outside ACL");
                    cursor+=length;
                }
            }
            if(at+size>raw.Length) throw new InvalidOperationException("Truncated SD section");
            starts[i]=offset;ends[i]=offset+(uint)size;
            for(int j=0;j<i;j++) if(starts[j]!=0 && offset<ends[j] && starts[j]<ends[i]) {
                // Complete owner/group SID alias is valid; partial overlap or
                // an SID pointing into ACL/ACE storage is never accepted.
                if(!(i<2 && j<2 && offset==starts[j] && ends[i]==ends[j])) throw new InvalidOperationException("Overlapping SD sections");
            }
            byte[] section=new byte[size];Array.Copy(raw,at,section,0,size);parts.Sections[i]=section;
        }
        for(int at=20;at<raw.Length;at++) {
            bool covered=false;
            for(int i=0;i<4;i++) if(starts[i]!=0 && at>=starts[i] && at<ends[i]) covered=true;
            if(!covered && raw[at]!=0) throw new InvalidOperationException("Nonzero bytes outside validated SD sections");
        }
        return parts;
    }
    public static SecurityComparison CompareSecurityHex(string expectedHex,string nativeHex) {
        SecurityComparison result=new SecurityComparison {Passed=false,Reason="Invalid security descriptor"};
        try {
            byte[] expected=Convert.FromHexString(expectedHex),native=Convert.FromHexString(nativeHex);
            result.ExpectedSha256=Hex(SHA256.HashData(expected));result.NativeSha256=Hex(SHA256.HashData(native));
            SdParts a=SplitSecurity(expected),b=SplitSecurity(native);
            if(a.Revision!=b.Revision || a.Control!=b.Control || a.RmControl!=b.RmControl) {result.Reason="SD revision/control/RMcontrol differs";return result;}
            for(int i=0;i<4;i++) if(!EqualBytes(a.Sections[i],b.Sections[i])) {result.Reason="SD SID/ACL section bytes differ";return result;}
            result.RawBytesEqual=EqualBytes(expected,native);
            result.ApiReorderedSd=!result.RawBytesEqual;
            result.Passed=true;result.Reason=result.ApiReorderedSd ? "Unchanged validated sections at different offsets; raw disk exact gate required separately" : "Raw SD bytes identical";
        } catch(Exception error) {result.Reason=error.Message;}
        return result;
    }
    static string Hex(byte[] value) { return Convert.ToHexString(value).ToLowerInvariant(); }
    static SafeFileHandle Open(string path, uint access) {
        // OPEN_EXISTING, backup-semantics + OPEN_REPARSE_POINT, share read/write/delete.
        SafeFileHandle h=CreateFile(path,access,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        if(h.IsInvalid) { int error=Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(error,"CreateFile read-only error="+error+" access=0x"+access.ToString("x")+" path="+path); }
        return h;
    }
    static string CheckedPath(string root, string relative) {
        if (String.IsNullOrEmpty(root) || root.Length<3 || root.StartsWith(@"\\") || root[1]!=':' || root[2]!='\\')
            throw new ArgumentException("Explicit drive-rooted alias/own fixture root required");
        if (relative==null || relative.Contains(":") || relative.Contains("\\") || relative.Contains("\0") || relative.Contains("\r") || relative.Contains("\n"))
            throw new ArgumentException("Invalid relative manifest path");
        string basePath=Path.GetFullPath(root).TrimEnd('\\');
        string[] parts=relative.Length==0 ? new string[0] : relative.Split('/');
        string path=@"\\?\"+basePath;
        for(int i=0;i<parts.Length;i++) {
            if(parts[i].Length==0 || parts[i]=="." || parts[i]==".." || parts[i].Length>255) throw new ArgumentException("Invalid path component");
            path+="\\"+parts[i];
            if(i+1<parts.Length) {
                uint attr=GetFileAttributes(path);
                if(attr==0xffffffff) throw new Win32Exception();
                if((attr&0x400)!=0) throw new ArgumentException("Refusing traversal through a reparse point");
            }
        }
        return path+ (parts.Length==0 ? "\\" : "");
    }
    static byte[] Security(SafeFileHandle h) {
        // OWNER|GROUP|DACL|SACL alone filters label/resource-attribute ACEs.
        // BACKUP_SECURITY_INFORMATION asks for the complete descriptor.
        const uint requested=0x00010000;
        uint size;
        GetKernelObjectSecurity(h,requested,null,0,out size);
        if(size<20 || size>1048576) throw new InvalidOperationException("Security descriptor size/refusal");
        byte[] data=new byte[size]; uint actual;
        if(!GetKernelObjectSecurity(h,requested,data,size,out actual) || actual!=size) throw new Win32Exception();
        return data;
    }
    static DataStream HashData(string path, string name, ulong expected) {
        using(SafeFileHandle h=Open(path,0x80000000))
        using(FileStream stream=new FileStream(h,FileAccess.Read,1048576,false))
        using(SHA1 hash=SHA1.Create()) {
            if(stream.Length<0 || (ulong)stream.Length!=expected || expected>100UL*1024*1024*1024) throw new InvalidOperationException("Stream size changed/exceeds bound");
            byte[] value=hash.ComputeHash(stream);
            if((ulong)stream.Position!=expected) throw new InvalidOperationException("Short stream read");
            return new DataStream { Name=name, Size=expected, Sha1=Hex(value), Kind="data" };
        }
    }
    static List<DataStream> NamedDataStreams(SafeFileHandle h,string path) {
        // FILE_STREAM_INFO on the existing BACKUP_SEMANTICS read handle.
        // FindFirstStreamW reopens without backup intent and incorrectly
        // fails a perfectly preserved SYSTEM-only WIM DACL.
        byte[] data=null;
        for(int size=16384;size<=1048576;size*=2) {
            byte[] candidate=new byte[size];
            bool ok=GetFileInformationBuffer(h,7,candidate,(uint)size);
            int error=Marshal.GetLastWin32Error();
            if(error==38) return new List<DataStream>();
            if(ok) {data=candidate;break;}
            if(error!=122 && error!=234) throw new Win32Exception(error,"FileStreamInfo read-only handle path="+path);
        }
        if(data==null) throw new InvalidOperationException("FileStreamInfo buffer bound exceeded");
        List<DataStream> result=new List<DataStream>();int at=0,count=0;
        while(true) {
            if(++count>1025 || at+24>data.Length) throw new InvalidOperationException("FileStreamInfo entry bound");
            uint next=BitConverter.ToUInt32(data,at),length=BitConverter.ToUInt32(data,at+4);
            long bytes=BitConverter.ToInt64(data,at+8);
            if(length==0 || length%2!=0 || length>2048 || length>data.Length-at-24 || bytes<0) throw new InvalidOperationException("FileStreamInfo name/size bounds");
            string stream=System.Text.Encoding.Unicode.GetString(data,at+24,(int)length);
            if(stream!="::$DATA") {
                if(!stream.StartsWith(":") || !stream.EndsWith(":$DATA")) throw new InvalidOperationException("Invalid DATA stream syntax");
                string name=stream.Substring(1,stream.Length-7);
                if(name.Length==0 || name.IndexOfAny(new char[]{':','/','\\','\0','\r','\n'})>=0) throw new InvalidOperationException("Invalid ADS name");
                result.Add(HashData(path+":"+name,name,(ulong)bytes));
            }
            if(next==0) break;
            if(next%8!=0 || next<24+length || next>data.Length-at-24) throw new InvalidOperationException("FileStreamInfo continuation bounds");
            at+=(int)next;
        }
        return result;
    }
    public static Metadata Read(string root, string relative) {
        string path=CheckedPath(root,relative);
        using(SafeFileHandle h=Open(path,0x81020080)) { // GENERIC_READ | ACCESS_SYSTEM_SECURITY | READ_CONTROL | READ_ATTRIBUTES
            BasicInfo basic; FileInfo info;
            if(!GetFileInformationByHandleEx(h,0,out basic,(uint)Marshal.SizeOf<BasicInfo>()) || !GetFileInformationByHandle(h,out info)) throw new Win32Exception();
            byte[] sd=Security(h);
            Metadata result=new Metadata { Attributes=basic.Attributes, Links=info.Links,
                Created=unchecked((ulong)basic.Created), Accessed=unchecked((ulong)basic.Accessed),
                Modified=unchecked((ulong)basic.Modified), Changed=unchecked((ulong)basic.Changed),
                FileId=info.Volume.ToString("x8")+":"+info.IndexHigh.ToString("x8")+info.IndexLow.ToString("x8"),
                SecuritySha256=Hex(SHA256.HashData(sd)), SecurityHex=Hex(sd) };
            var streams=new List<DataStream>();
            if((basic.Attributes&0x400)!=0) {
                byte[] buffer=new byte[16384]; uint actual;
                if(!DeviceIoControl(h,0x900a8,IntPtr.Zero,0,buffer,(uint)buffer.Length,out actual,IntPtr.Zero)) throw new Win32Exception();
                if(actual<8 || actual>16384) throw new InvalidOperationException("Invalid reparse buffer length");
                result.ReparseTag=BitConverter.ToUInt32(buffer,0);
                int length=BitConverter.ToUInt16(buffer,4);
                if((result.ReparseTag&0x80000000)==0) length+=16;
                if(length+8!=actual) throw new InvalidOperationException("Reparse length inconsistent with native buffer");
                // WIM stores the data after the 8-byte tag/length/reserved header.
                // Never follow the target or rewrite an absolute/root-relative name.
                byte[] data=new byte[length]; Array.Copy(buffer,8,data,0,length);
                result.ReparseDataHex=Hex(data);
                streams.Add(new DataStream { Name=null, Size=(ulong)data.Length, Sha1=Hex(SHA1.HashData(data)), Kind="reparse" });
            } else {
                if((basic.Attributes&0x10)!=0)
                    streams.Add(new DataStream { Name=null, Size=0, Sha1=new string('0',40), Kind="data" });
                else streams.Add(HashData(path,null,((ulong)info.SizeHigh<<32)|info.SizeLow));
                streams.AddRange(NamedDataStreams(h,path));
            }
            result.Streams=streams.ToArray();
            return result;
        }
    }
}
