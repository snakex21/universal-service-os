# SPDX-License-Identifier: GPL-3.0-or-later
"""Exact-path policy tests; never execute DISM, bcdboot or open host BCD."""
from pathlib import Path
import tempfile
import unittest
from test_minios_host_dism_executor import ROOT, BOUNDED, powershell


def setup():
    return ("$ErrorActionPreference='Stop'; Add-Type -Path '"+str(BOUNDED).replace("'","''")+"'\n"
            "$exe=(Get-Command python.exe).Source\n"
            "$sha=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()\n"
            "$policy=[MiniOsHostDismProcess]::new($exe,$sha)\n")


class Tests(unittest.TestCase):
    def test_blacklist_bypasses_and_other_executables_refuse_before_outputs(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as folder:
            script=setup()+"$dir='"+folder.replace("'","''")+"'\n"
            script+=r'''
            $system=[Environment]::GetFolderPath('System')
            $bad=@('bcdboot.exe. ','BCDBOOT','bcdboot.exe::$DATA',
              (Join-Path $system 'bcdboot.exe. '),(Join-Path $system 'BCDBOOT.EXE'),
              (Join-Path $system 'bcdboot.exe::$DATA'),(Join-Path $system 'BCDBOO~1.EXE'),
              (Join-Path $dir 'python.exe'),(Join-Path $system 'cmd.exe'),
              (Join-Path $system 'powershell.exe'),('\\?\'+$exe),('\\server\share\python.exe'))
            foreach($path in $bad) {
                $blocked=$false
                try {$policy.RunAllowed($path,@(),(Join-Path $dir 'out'),(Join-Path $dir 'err'),'',1024,1,$dir)}
                catch {if($_.Exception.Message -notmatch 'HOST_EXECUTABLE_NOT_ALLOWED'){throw};$blocked=$true}
                if(-not $blocked){throw ('not refused: '+$path)}
            }
            if(@(Get-ChildItem -LiteralPath $dir -Force).Count){throw 'denial created files'}
            '''
            powershell(script)

    def test_full_normalization_and_ordinal_case_insensitive_match(self):
        powershell(setup()+r'''
        $candidate=$exe.ToUpperInvariant()+'. '
        if($policy.ResolveExecutable($candidate) -ine $exe){throw 'Win32 trailing/case normalization differs'}
        $candidate=Join-Path ([IO.Path]::GetDirectoryName($exe)) './python.exe'
        if($policy.ResolveExecutable($candidate) -ine $exe){throw 'GetFullPathName not used'}
        $dism=Join-Path ([Environment]::GetFolderPath('System')) 'dism.exe'
        if($policy.ResolveExecutable($dism.ToUpperInvariant()) -ine $dism){throw 'exact system DISM not recognized'}
        $failed=$false
        try {[MiniOsHostDismProcess]::new((Join-Path ([Environment]::GetFolderPath('System')) 'bcdboot.exe. '),$sha)}
        catch {$failed=$true}
        if(-not $failed){throw 'bcdboot admitted as Python'}
        ''')

    def test_python_hash_is_verified_before_outputs(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'runtime') as folder:
            script=setup()+"$dir='"+folder.replace("'","''")+"'\n"
            script+=r'''
            $policy=[MiniOsHostDismProcess]::new($exe,('0'*64));$blocked=$false
            try {$policy.RunAllowed($exe,@('-c','print(1)'),(Join-Path $dir 'out'),(Join-Path $dir 'err'),'',1024,1000,$dir)}
            catch {if($_.Exception.Message -notmatch 'HOST_EXECUTABLE_NOT_ALLOWED'){throw};$blocked=$true}
            if(-not $blocked -or @(Get-ChildItem -LiteralPath $dir).Count){throw 'hash failed after side effect'}
            '''
            powershell(script)

    def test_real_short_path_alias_of_interpreter_is_rejected_if_assigned(self):
        script=setup()+r'''
        Add-Type -TypeDefinition @'
        using System;using System.Text;using System.Runtime.InteropServices;
        public static class MiniOsTestShortPath {
            [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
            public static extern uint GetShortPathNameW(string path,StringBuilder output,uint count);
        }
'@
        $short=[Text.StringBuilder]::new(32768)
        $count=[MiniOsTestShortPath]::GetShortPathNameW($exe,$short,[uint32]$short.Capacity)
        if($count -eq 0 -or $short.ToString() -notmatch '~'){Write-Output 'NO_DISTINCT_SHORT_ALIAS';return}
        $blocked=$false
        try {$policy.ResolveExecutable($short.ToString())}
        catch {if($_.Exception.Message -notmatch 'HOST_EXECUTABLE_NOT_ALLOWED'){throw};$blocked=$true}
        if(-not $blocked){throw '8.3 alias admitted'}
        Write-Output 'DISTINCT_SHORT_ALIAS_REFUSED'
        '''
        result=powershell(script)
        if 'NO_DISTINCT_SHORT_ALIAS' in result:self.skipTest('No distinct 8.3 alias assigned to the local interpreter')
        self.assertIn('DISTINCT_SHORT_ALIAS_REFUSED',result)


if __name__=='__main__':unittest.main()
