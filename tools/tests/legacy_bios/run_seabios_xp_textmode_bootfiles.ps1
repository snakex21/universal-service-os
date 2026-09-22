param(
    [string]$IsoPath = 'windows_xp_professional_service_pack_2_x86_pl.iso',
    [UInt64]$TargetBytes = 120034123776,
    [int]$TimeoutSeconds = 600,
    [switch]$KeepArtifacts
)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools/process_argument_line.ps1')
$stagingRunner=Join-Path $PSScriptRoot 'run_seabios_xp_menu_staging.ps1'
$textModeRunner=Join-Path $PSScriptRoot 'continue_xp_textmode_from_raw.ps1'
$watchdogScript=Join-Path $PSScriptRoot 'xp_bootfiles_watchdog.ps1'
$mutexName='Global\USOS_XP_BOOTFILES_REGRESSION_V2'
$mutex=[Threading.Mutex]::new($false,$mutexName)
$mutexTaken=$false
try {
    try { $mutexTaken=$mutex.WaitOne(0,$false) }
    catch [Threading.AbandonedMutexException] { $mutexTaken=$true }
    if(-not $mutexTaken){ throw 'XP boot-files regression LOCKED: another canonical wrapper instance is already running' }

    $token='xpbootfiles-'+[Guid]::NewGuid().ToString('N').Substring(0,12)
    $runDir=Join-Path $root "zig-out\legacy-bios\xp-bootfiles-$token"
    $logDir=Join-Path $root 'zig-out\legacy-bios\wrapper-logs'
    [IO.Directory]::CreateDirectory($runDir) | Out-Null
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $stdout=Join-Path $logDir "$token.out.log"
    $stderr=Join-Path $logDir "$token.err.log"
    $doneFile=Join-Path $logDir "$token.done"
    $passFile=Join-Path $logDir "$token.pass"
    $watchdog=$null
    $activeChild=$null

    function Get-OwnedProcesses {
        $watchdogPid=if($script:watchdog){$script:watchdog.Id}else{-1}
        @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and $_.ProcessId -ne $watchdogPid -and $_.CommandLine -and $_.CommandLine.Contains($script:token)
        })
    }
    function Stop-OwnedProcessTrees {
        $owned=Get-OwnedProcesses
        foreach($proc in $owned | Sort-Object ProcessId -Descending){
            & taskkill.exe /PID $proc.ProcessId /T /F 2>$null | Out-Null
        }
        Start-Sleep -Milliseconds 300
        @(Get-OwnedProcesses)
    }
    function Signal-WatchdogDone {
        if(-not (Test-Path -LiteralPath $script:doneFile -PathType Leaf)){
            [IO.File]::WriteAllText($script:doneFile,"done`r`n",[Text.UTF8Encoding]::new($false))
        }
    }
    function Invoke-Phase {
        param(
            [string]$Name,
            [string[]]$Arguments,
            [DateTime]$Deadline
        )
        $psi=[Diagnostics.ProcessStartInfo]::new()
        $psi.FileName='powershell.exe'
        $psi.Arguments=(ConvertTo-NativeArgumentLine -Arguments $Arguments)
        $psi.UseShellExecute=$false
        $psi.CreateNoWindow=$true
        $psi.RedirectStandardOutput=$true
        $psi.RedirectStandardError=$true
        $proc=[Diagnostics.Process]::new()
        $proc.StartInfo=$psi
        [void]$proc.Start()
        $script:activeChild=$proc
        $outTask=$proc.StandardOutput.ReadToEndAsync()
        $errTask=$proc.StandardError.ReadToEndAsync()
        while(-not $proc.HasExited -and [DateTime]::UtcNow -lt $Deadline){
            Start-Sleep -Milliseconds 250
            $proc.Refresh()
        }
        if(-not $proc.HasExited){
            $remaining=Stop-OwnedProcessTrees
            [void]$proc.WaitForExit(5000)
            throw "$Name TIMEOUT; owned_processes_remaining=$(@($remaining).Count)"
        }
        $proc.WaitForExit()
        $outText=$outTask.Result
        $errText=$errTask.Result
        $script:activeChild=$null
        if($outText){ Write-Host $outText.TrimEnd() }
        if($proc.ExitCode -ne 0){ throw "$Name failed exit=$($proc.ExitCode)`n$errText" }
        if($errText){ Write-Host $errText.TrimEnd() }
        [pscustomobject]@{ Output=$outText; Error=$errText; ExitCode=$proc.ExitCode }
    }

    Remove-Item -LiteralPath $stdout,$stderr,$doneFile,$passFile -Force -ErrorAction SilentlyContinue
    $watchdogArgs=@(
        '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$watchdogScript,
        '-Token',$token,
        '-OwnerPid',$PID,
        '-TimeoutSeconds',($TimeoutSeconds+15),
        '-DoneFile',$doneFile
    )
    $watchdogExe=(Get-Command powershell.exe -ErrorAction Stop).Source
    $watchdogCommand='"'+$watchdogExe+'" '+(ConvertTo-NativeArgumentLine -Arguments $watchdogArgs)
    $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$watchdogCommand}
    if($created.ReturnValue -ne 0 -or -not $created.ProcessId){ throw "Cannot start detached XP boot-files watchdog: return=$($created.ReturnValue)" }
    $watchdog=[Diagnostics.Process]::GetProcessById([int]$created.ProcessId)

    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stagingArgs=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$stagingRunner,
        '-IsoPath',$IsoPath,
        '-BlankTarget',
        '-TargetBytes',$TargetBytes,
        '-OutputDirectory',$runDir,
        '-SelectNoUnattended',
        '-TimeoutMinutes',([Math]::Max(10,[Math]::Ceiling($TimeoutSeconds/60)))
    )
    $stage=Invoke-Phase -Name 'production-topology XP staging' -Arguments $stagingArgs -Deadline $deadline
    if(-not $stage.Output.Contains('[PASS] DONE framebuffer rendered the ENTER action; Enter reached POWER OFF REQUESTED and QEMU powered off.')){
        throw 'production-topology staging host PASS for DONE/tty1 poweroff is missing'
    }
    $serialLine=@($stage.Output -split "`r?`n" | Where-Object { $_ -like 'SERIAL=*' } | Select-Object -Last 1)
    if(-not $serialLine){ throw 'production-topology staging did not report SERIAL' }
    $serialPath=$serialLine.Substring('SERIAL='.Length).Trim()
    if(-not (Test-Path -LiteralPath $serialPath -PathType Leaf)){ throw "production-topology staging serial missing: $serialPath" }
    $serialText=[IO.File]::ReadAllText($serialPath)
    foreach($needle in @(
        '[LEGACY_XP] BIOS TARGET MATCH',
        'source=INT13-AH08',
        '[XP_TARGET] MBR CHS PASS',
        '[USOS-FB-UI] STAGE current=1/5',
        '[USOS-FB-UI] STAGE current=2/5',
        '[USOS-FB-UI] STAGE current=3/5',
        '[USOS-FB-UI] STAGE current=4/5',
        '[USOS-FB-UI] STAGE current=5/5',
        '[USOS-FB-UI] DONE RENDER PASS backend=framebuffer action=[ENTER]-POWER-OFF',
        '[LEGACY_XP] POWER OFF REQUESTED input=/dev/tty1'
    )){
        if(-not $serialText.Contains($needle)){ throw "production-topology staging serial missing '$needle'" }
    }
    $targetLine=@($stage.Output -split "`r?`n" | Where-Object { $_ -like 'TARGET_RAW=*' } | Select-Object -Last 1)
    if(-not $targetLine){ throw 'production-topology staging did not report TARGET_RAW' }
    $targetRaw=$targetLine.Substring('TARGET_RAW='.Length).Trim()
    if(-not (Test-Path -LiteralPath $targetRaw -PathType Leaf)){ throw "staged target raw missing: $targetRaw" }
    if([UInt64](Get-Item -LiteralPath $targetRaw).Length -ne $TargetBytes){ throw 'staged target raw size changed' }

    $textOut=Join-Path $runDir 'textmode-copy-start'
    $textArgs=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$textModeRunner,
        '-RawPath',$targetRaw,
        '-OutputDirectory',$textOut,
        '-TimeoutMinutes',([Math]::Max(8,[Math]::Ceiling($TimeoutSeconds/60)))
    )
    $text=Invoke-Phase -Name 'single-boot XP Text Mode' -Arguments $textArgs -Deadline $deadline
    $copyMarker='[PASS] XP Text Mode: partition 2 created -> selected -> boot-files C: check passed -> format started/completed -> file copying started.'
    if(-not $text.Output.Contains($copyMarker)){ throw 'Text Mode copy-start PASS marker missing' }

    $combined=$stage.Output+"`r`n--- STAGING SERIAL ---`r`n"+$serialText+"`r`n--- TEXT MODE ---`r`n"+$text.Output
    [IO.File]::WriteAllText($stdout,$combined,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))

    $remaining=Stop-OwnedProcessTrees
    if(@($remaining).Count -ne 0){ throw "XP boot-files regression left owned processes after cleanup: $(@($remaining | ForEach-Object { $_.ProcessId }) -join ',')" }
    $passText=("XP boot-files wrapper PASS token={0} target_bytes={1} orphan_processes=0 production_topology=yes single_textmode_boot=yes ah08=yes tty1_poweroff=yes`r`n" -f $token,$TargetBytes)
    [IO.File]::WriteAllText($passFile,$passText,[Text.UTF8Encoding]::new($false))
    Signal-WatchdogDone
    if($watchdog -and -not $watchdog.HasExited){ [void]$watchdog.WaitForExit(5000) }
    if($watchdog -and -not $watchdog.HasExited){ Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue }
    Write-Host ("[PASS] XP boot-files canonical regression: production staging topology -> AH=08 CHS -> DONE/tty1 poweroff -> sole-target Text Mode -> partition 2 -> format -> copy start; target_bytes={0}; orphan_processes=0" -f $TargetBytes) -ForegroundColor Green
} finally {
    if($mutexTaken){
        try {
            if(Get-Variable -Name token -Scope Local -ErrorAction SilentlyContinue){
                $remaining=Stop-OwnedProcessTrees
                if(@($remaining).Count -ne 0){ Write-Error ("Wrapper cleanup could not terminate owned processes: {0}" -f (@($remaining | ForEach-Object { $_.ProcessId }) -join ',')) }
                Signal-WatchdogDone
                if($watchdog -and -not $watchdog.HasExited){ [void]$watchdog.WaitForExit(3000) }
                if($watchdog -and -not $watchdog.HasExited){ Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue }
            }
        } finally {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    } else {
        $mutex.Dispose()
    }
}
