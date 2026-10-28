// SPDX-License-Identifier: GPL-3.0-or-later
// Start suspended, place the exact child in a private kill-on-close job, then
// resume. Block on process completion; bound output and inherited-pipe drain.
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.ComponentModel;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class MiniOsHostDismProcess {
    [StructLayout(LayoutKind.Sequential)] struct Security {public int Size;public IntPtr Descriptor;public int Inherit;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup {
        public int Size;public string Reserved,Desktop,Title;public int X,Y,XSize,YSize,XCount,YCount,Fill,Flags;
        public short Show,Reserved2;public IntPtr ReservedPtr,StdIn,StdOut,StdErr;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcInfo {public IntPtr Process,Thread;public uint Pid,Tid;}
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime,JobTime;public uint Flags;public UIntPtr Minimum,Maximum;public uint Active;
        public UIntPtr Affinity;public uint Priority,Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {public ulong A,B,C,D,E,F;}
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic;public IoCounters Io;public UIntPtr ProcessMemory,JobMemory,PeakProcess,PeakJob;
    }
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]static extern IntPtr CreateJobObject(IntPtr security,string name);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits value,uint size);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref Security security,uint size);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]static extern IntPtr CreateFile(string path,uint access,uint share,ref Security security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]static extern bool CreateProcess(string app,StringBuilder command,IntPtr procSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string cwd,ref Startup startup,out ProcInfo info);
    [DllImport("kernel32.dll",SetLastError=true)]static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)]static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr handle);

    static void Check(bool ok) {if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error());}
    static void Close(ref IntPtr h) {if(h!=IntPtr.Zero && h!=new IntPtr(-1)){CloseHandle(h);h=IntPtr.Zero;}}
    static string Quote(string value) {
        var b=new StringBuilder("\"");int slashes=0;
        foreach(char c in value) {
            if(c=='\\'){slashes++;continue;}
            if(c=='\"'){b.Append('\\',slashes*2+1);b.Append(c);slashes=0;continue;}
            b.Append('\\',slashes);slashes=0;b.Append(c);
        }
        b.Append('\\',slashes*2);b.Append('\"');return b.ToString();
    }
    static IntPtr EnvironmentBlock(string temporary) {
        var vars=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
            var key=(string)entry.Key;
            if(!key.Contains("="))vars[key]=(string)entry.Value;
        }
        vars["TEMP"]=temporary;vars["TMP"]=temporary;
        var text=new StringBuilder();foreach(var pair in vars)text.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');text.Append('\0');
        byte[] bytes=Encoding.Unicode.GetBytes(text.ToString());var pointer=Marshal.AllocHGlobal(bytes.Length);Marshal.Copy(bytes,0,pointer,bytes.Length);return pointer;
    }
    sealed class Budget {public long Remaining;public bool Exceeded;public bool Active=true;public readonly object Gate=new object();}
    static void Pump(Stream input,Stream output,Budget budget,IntPtr job) {
        var buf=new byte[4096];int count;
        while((count=input.Read(buf,0,buf.Length))>0) {
            lock(budget.Gate) {
                if(!budget.Active)return;
                int take=(int)Math.Min(count,Math.Max(0,budget.Remaining));
                if(take>0){output.Write(buf,0,take);budget.Remaining-=take;}
                if(take<count){budget.Exceeded=true;TerminateJobObject(job,1);return;}
            }
        }
    }
    readonly string pythonPath,pythonSha;
    readonly HashSet<string> executablePaths;
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern uint GetFullPathNameW(string path,uint count,StringBuilder output,IntPtr filePart);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern uint GetFinalPathNameByHandleW(IntPtr file,StringBuilder output,uint count,uint flags);

    static InvalidOperationException Denied() {
        return new InvalidOperationException("HOST_EXECUTABLE_NOT_ALLOWED: exact DISM or pinned Python path required");
    }
    public static string NormalizeExecutablePath(string path) {
        // Only ordinary drive-absolute paths. Reject streams, device/UNC paths,
        // short-name aliases, wildcards and command-line quoting, even if Win32
        // would resolve one to a file. No PATH or implicit .exe lookup occurs.
        if(String.IsNullOrEmpty(path)||path.Length>32760||path.Length<4||!Char.IsLetter(path[0])||path[1]!=':'||
           (path[2]!='\\' && path[2]!='/')||path.IndexOf(':',2)>=0||
           path.IndexOfAny(new char[]{'~','*','?','"','\r','\n','\0'})>=0)throw Denied();
        var parts=path.Replace('/','\\').Split('\\');
        for(int i=1;i<parts.Length;i++) {
            if(parts[i]=="."||parts[i]=="..")continue;
            parts[i]=parts[i].TrimEnd(' ','.');
            if(parts[i].Length==0)throw Denied();
        }
        var full=new StringBuilder(32768);
        uint count=GetFullPathNameW(String.Join("\\",parts),(uint)full.Capacity,full,IntPtr.Zero);
        if(count==0||count>=full.Capacity)throw Denied();
        return full.ToString();
    }
    public MiniOsHostDismProcess(string approvedPython,string approvedPythonSha256) {
        pythonPath=NormalizeExecutablePath(approvedPython);
        if(!String.Equals(Path.GetFileName(pythonPath),"python.exe",StringComparison.OrdinalIgnoreCase)||
           approvedPythonSha256==null||approvedPythonSha256.Length!=64||
           !System.Text.RegularExpressions.Regex.IsMatch(approvedPythonSha256,"\\A[0-9a-f]{64}\\z"))throw Denied();
        pythonSha=approvedPythonSha256;
        executablePaths=new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            pythonPath,NormalizeExecutablePath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"dism.exe"))
        };
    }
    public string ResolveExecutable(string path) {
        string full=NormalizeExecutablePath(path);
        if(!executablePaths.Contains(full))throw Denied();
        return full;
    }
    FileStream OpenExecutable(string full) {
        for(string at=full;!String.IsNullOrEmpty(at);at=Path.GetDirectoryName(at)) {
            if((File.Exists(at)||Directory.Exists(at))&&(File.GetAttributes(at)&FileAttributes.ReparsePoint)!=0)throw Denied();
        }
        var file=new FileStream(full,FileMode.Open,FileAccess.Read,FileShare.Read);
        try {
            var final=new StringBuilder(32768);
            uint size=GetFinalPathNameByHandleW(file.SafeFileHandle.DangerousGetHandle(),final,(uint)final.Capacity,0);
            string actual=final.ToString();
            if(actual.StartsWith(@"\\?\",StringComparison.Ordinal))actual=actual.Substring(4);
            if(size==0||size>=final.Capacity||!String.Equals(NormalizeExecutablePath(actual),full,StringComparison.OrdinalIgnoreCase))throw Denied();
            if(String.Equals(full,pythonPath,StringComparison.OrdinalIgnoreCase)) {
                string sha=Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(file)).ToLowerInvariant();
                if(sha!=pythonSha)throw Denied();
            }
            return file;
        } catch {file.Dispose();throw;}
    }
    // Retired public entry: even callers of the old API fail before side effects.
    public static int Run(string exe,string[] args,string stdout,string stderr,string prefix,long limit,int timeoutMs,string temporary) {
        throw new InvalidOperationException("HOST_BCDBOOT_FORBIDDEN HOST_EXECUTABLE_NOT_ALLOWED: explicit immutable allowlist required");
    }
    public int RunAllowed(string exe,string[] args,string stdout,string stderr,string prefix,long limit,int timeoutMs,string temporary) {
        exe=ResolveExecutable(exe);
        using(var executableLock=OpenExecutable(exe))
            return RunChild(exe,args,stdout,stderr,prefix,limit,timeoutMs,temporary);
    }
    static int RunChild(string exe,string[] args,string stdout,string stderr,string prefix,long limit,int timeoutMs,string temporary) {
        if(limit<1024 || limit>512L*1024*1024 || timeoutMs<=0 || timeoutMs>10800000)
            throw new ArgumentOutOfRangeException("Bounded output and timeout required");
        byte[] header=Encoding.UTF8.GetBytes(prefix);
        if(2L*header.Length>=limit)throw new InvalidOperationException("Prefix exceeds log budget");
        var cmd=new StringBuilder(Quote(exe));foreach(string arg in args)cmd.Append(' ').Append(Quote(arg));
        IntPtr job=IntPtr.Zero,or=IntPtr.Zero,ow=IntPtr.Zero,er=IntPtr.Zero,ew=IntPtr.Zero,input=IntPtr.Zero,env=IntPtr.Zero;
        ProcInfo pi=new ProcInfo();bool assigned=false;
        using(var output=new FileStream(stdout,FileMode.CreateNew,FileAccess.Write,FileShare.Read))
        using(var errors=new FileStream(stderr,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) {
            output.Write(header,0,header.Length);errors.Write(header,0,header.Length);
            var budget=new Budget{Remaining=limit-2L*header.Length};
            try {
                job=CreateJobObject(IntPtr.Zero,null);if(job==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
                var limits=new ExtendedLimits();limits.Basic.Flags=0x2000; // KILL_ON_JOB_CLOSE
                Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits))));
                var sa=new Security{Size=Marshal.SizeOf(typeof(Security)),Inherit=1};
                Check(CreatePipe(out or,out ow,ref sa,0));Check(CreatePipe(out er,out ew,ref sa,0));
                Check(SetHandleInformation(or,1,0));Check(SetHandleInformation(er,1,0));
                input=CreateFile("NUL",0x80000000,3,ref sa,3,0,IntPtr.Zero);
                if(input==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());
                var si=new Startup{Size=Marshal.SizeOf(typeof(Startup)),Flags=0x100,StdIn=input,StdOut=ow,StdErr=ew};
                env=EnvironmentBlock(temporary);
                // CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
                Check(CreateProcess(exe,cmd,IntPtr.Zero,IntPtr.Zero,true,0x00000404|0x08000000,env,null,ref si,out pi));
                if(!AssignProcessToJobObject(job,pi.Process)){int error=Marshal.GetLastWin32Error();TerminateProcess(pi.Process,1);throw new Win32Exception(error);}
                assigned=true;
                if(ResumeThread(pi.Thread)==0xffffffff)throw new Win32Exception(Marshal.GetLastWin32Error());
                Close(ref ow);Close(ref ew);Close(ref input);
                using(var outRead=new FileStream(new SafeFileHandle(or,true),FileAccess.Read))
                using(var errRead=new FileStream(new SafeFileHandle(er,true),FileAccess.Read)) {
                    or=IntPtr.Zero;er=IntPtr.Zero;
                    var a=Task.Run(()=>Pump(outRead,output,budget,job));var b=Task.Run(()=>Pump(errRead,errors,budget,job));
                    uint status=WaitForSingleObject(pi.Process,(uint)timeoutMs);
                    if(status!=0){TerminateJobObject(job,1);Task.WaitAll(new[]{a,b},5000);throw new TimeoutException("Bounded command timed out or wait failed");}
                    if(!Task.WaitAll(new[]{a,b},5000)) {
                        TerminateJobObject(job,1);Task.WaitAll(new[]{a,b},5000);
                        throw new TimeoutException("Child output pipe remained open");
                    }
                    output.Flush(true);errors.Flush(true);
                    if(budget.Exceeded)throw new InvalidOperationException("Bounded command output exceeded budget");
                    uint exit;Check(GetExitCodeProcess(pi.Process,out exit));return unchecked((int)exit);
                }
            } finally {
                lock(budget.Gate) {budget.Active=false;if(assigned && job!=IntPtr.Zero)TerminateJobObject(job,1);}
                Close(ref pi.Thread);Close(ref pi.Process);Close(ref or);Close(ref ow);Close(ref er);Close(ref ew);Close(ref input);Close(ref job);
                if(env!=IntPtr.Zero)Marshal.FreeHGlobal(env);
            }
        }
    }
}
