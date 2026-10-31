#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='WindowsCargo')]
param(
    [Parameter(Mandatory,ParameterSetName='WindowsCargo')][string[]]$CargoArguments,
    [Parameter(ParameterSetName='WindowsCargo')][ValidateRange(3,512)][int]$TransientMiB=14,
    [Parameter(ParameterSetName='WindowsCargo')][ValidateSet('1.98.1','1.99.1')][string]$Toolchain='1.98.1',
    [Parameter(Mandatory,ParameterSetName='MacDecodeDiagnostic')][switch]$MacDecodeDiagnostic,
    [Parameter(Mandatory,ParameterSetName='MacDecodeDiagnostic')][Parameter(Mandatory,ParameterSetName='MacCdfCandidate')][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ProtocolSha256,
    [Parameter(Mandatory,ParameterSetName='MacDecodeRetry')][switch]$MacDecodeRetry,
    [Parameter(Mandatory,ParameterSetName='MacDecodeRetry')][ValidatePattern('\A[0-9a-f]{64}\z')][string]$AmendmentSha256,
    [Parameter(Mandatory,ParameterSetName='MacCdfCandidate')][switch]$MacCdfCandidate
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($PSCmdlet.ParameterSetName -ceq 'MacCdfCandidate'){
    if(-not $MacCdfCandidate){throw 'MacCdfCandidate must be explicitly true.'}
    & (Join-Path $PSScriptRoot 'invoke-mac-cdf-candidate.ps1') -ProtocolSha256 $ProtocolSha256
    exit $LASTEXITCODE
}
if($PSCmdlet.ParameterSetName -ceq 'MacDecodeRetry'){
    if(-not $MacDecodeRetry){throw 'MacDecodeRetry must be explicitly true.'}
    & (Join-Path $PSScriptRoot 'invoke-mac-decode-diagnostic.ps1') -Retry -AmendmentSha256 $AmendmentSha256
    exit $LASTEXITCODE
}
if($PSCmdlet.ParameterSetName -ceq 'MacDecodeDiagnostic'){
    if(-not $MacDecodeDiagnostic){throw 'MacDecodeDiagnostic must be explicitly true.'}
    & (Join-Path $PSScriptRoot 'invoke-mac-decode-diagnostic.ps1') -ProtocolSha256 $ProtocolSha256
    exit $LASTEXITCODE
}
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$taskProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$taskPaths=Get-KhcStorageTaskPaths
$taskTarget=$taskPaths.CargoTargetRoot
$taskToolchain="$Toolchain-x86_64-pc-windows-msvc"
$taskToolchainBin=Join-Path 'C:/Users/IMT/.rustup/toolchains' "$taskToolchain/bin"
$taskCargo=[IO.Path]::GetFullPath((Join-Path $taskToolchainBin 'cargo.exe'))
$taskRustc=[IO.Path]::GetFullPath((Join-Path $taskToolchainBin 'rustc.exe'))
foreach($taskRequiredTool in @($taskCargo,$taskRustc)){
    if(-not (Test-Path -LiteralPath $taskRequiredTool -PathType Leaf)){throw "installed toolchain $taskToolchain is missing required executable: $taskRequiredTool"}
}
$taskCap=5906793080L+268435456L
function Usage {
    for($taskScan=0;$taskScan -lt 3;$taskScan++){
        try {
            return Get-KhcTreeUsage -LiteralPath $taskTarget
        } catch {
            # Cargoの一時項目消失だけ全走査をやり直す。権限・リンク・他のIO障害は隠さない。
            $taskMissing=$false
            for($taskError=$_.Exception;$null -ne $taskError;$taskError=$taskError.InnerException){
                if($taskError -is [IO.IOException] -and (($taskError.HResult -band 65535) -in @(2,3))){$taskMissing=$true}
            }
            if(-not $taskMissing -or $taskScan -eq 2 -or -not [IO.Directory]::Exists($taskTarget)){throw}
            Start-Sleep -Milliseconds 25
        }
    }
}
$taskPath=$taskTarget
while($taskPath){if((Test-Path -LiteralPath $taskPath) -and (((Get-Item -LiteralPath $taskPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'cargo reparse ancestor'};$taskPath=[IO.Path]::GetDirectoryName($taskPath)}
if($CargoArguments -contains '-j' -or $CargoArguments -contains '--jobs' -or @($CargoArguments | Where-Object {$_ -match '^(-j\d|--jobs=|--target-dir|--config)'}).Count){throw 'job/target/config override prohibited'}
$taskPaths=Initialize-KhcStorageTaskEnvironment
$taskTarget=$taskPaths.CargoTargetRoot
$taskStorage=Assert-KhcStorageBudget -CargoReserveBytes ($TransientMiB*1MB)
$taskStart=Usage
$taskLimit=[math]::Min($taskCap,$taskStart+$TransientMiB*1048576L)
if($taskCap-$taskStart -lt $TransientMiB*1048576L){throw 'insufficient temporary budget before cargo'}
if([IO.DriveInfo]::new('D:\').AvailableFreeSpace -lt 5368709120L+$TransientMiB*1048576L){throw 'free space budget'}
$taskInfo=[Diagnostics.ProcessStartInfo]::new()
$taskInfo.FileName=$taskCargo
$taskInfo.WorkingDirectory=$taskProjectRoot
$taskInfo.UseShellExecute=$false
$taskInfo.CreateNoWindow=$true
$taskInfo.RedirectStandardOutput=$true
$taskInfo.RedirectStandardError=$true
$taskInfo.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$taskInfo.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
$taskInfo.Environment['RUSTC']=$taskRustc
$taskInfo.Environment['RUSTUP_TOOLCHAIN']=$taskToolchain
$taskInfo.Environment['RUSTUP_AUTO_INSTALL']='0'
$taskInfo.Environment['KHC_STORAGE_TASK_ID']=$taskPaths.TaskId
$taskInfo.Environment['TEMP']=$taskPaths.TempRoot
$taskInfo.Environment['TMP']=$taskPaths.TempRoot
$taskInfo.Environment['TMPDIR']=$taskPaths.TempRoot
$taskInfo.Environment['CARGO_TARGET_DIR']=$taskTarget
$taskInfo.Environment['CARGO_BUILD_TARGET_DIR']=$taskTarget
$taskInfo.Environment['CARGO_BUILD_BUILD_DIR']=$taskTarget
$taskInfo.Environment['CARGO_INCREMENTAL']='0'
$taskSeparator=[array]::IndexOf($CargoArguments,'--')
$taskJobPosition=if($taskSeparator -ge 0){$taskSeparator}else{$CargoArguments.Length}
for($taskIndex=0;$taskIndex -le $CargoArguments.Length;$taskIndex++){
    # clippyの区切り以降はrustc引数なので、Cargoのjobsは必ずその前へ渡す。
    if($taskIndex -eq $taskJobPosition){$taskInfo.ArgumentList.Add('-j');$taskInfo.ArgumentList.Add('1');$taskInfo.ArgumentList.Add('--target-dir');$taskInfo.ArgumentList.Add($taskTarget);$taskInfo.ArgumentList.Add('--config');$taskInfo.ArgumentList.Add('build.build-dir="'+$taskTarget.Replace('\','/')+'"')}
    if($taskIndex -lt $CargoArguments.Length){$taskInfo.ArgumentList.Add($CargoArguments[$taskIndex])}
}
$taskProcess=[Diagnostics.Process]::new();$taskProcess.StartInfo=$taskInfo
$taskLease=Enter-KhcCargoLease
$taskJob=$null;$taskGate=$null
$taskLogs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
$taskBuffers=@([char[]]::new(4096),[char[]]::new(4096))
$taskDone=@($false,$false)
$taskTasks=@($null,$null)
$taskReaders=@($null,$null)
$taskPeak=$taskStart;$taskStarted=$false;$taskFailure=$null;$taskExit=1
$taskTimer=[Diagnostics.Stopwatch]::StartNew()
try {
    # 制御されたpwsh bootstrapだけ先に起動し、Job配下へ入るまでCargoを開始しない。
    $taskGateName='Local\KHC-Cargo-'+[Guid]::NewGuid().ToString('N')
    $taskGate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$taskGateName)
    $taskJob=[Khc.Storage.ProcessJob]::new()
    $taskInfo.Environment['KHC_SERIAL_CARGO_EXE']=$taskCargo
    $taskInfo.Environment['KHC_SERIAL_CARGO_ARGS']=ConvertTo-Json -InputObject @($taskInfo.ArgumentList) -Compress
    $taskInfo.Environment['KHC_STORAGE_START_EVENT']=$taskGateName
    $taskInfo.FileName=(Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $taskInfo.ArgumentList.Clear();$taskInfo.ArgumentList.Add('-NoProfile');$taskInfo.ArgumentList.Add('-Command')
    $taskInfo.ArgumentList.Add('[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding;$ErrorActionPreference="Stop"; $gate=[Threading.EventWaitHandle]::OpenExisting($env:KHC_STORAGE_START_EVENT);try{if(-not $gate.WaitOne(10000)){throw "Job assignment timeout"}}finally{$gate.Dispose()};$cargoArgs=ConvertFrom-Json -InputObject $env:KHC_SERIAL_CARGO_ARGS;& $env:KHC_SERIAL_CARGO_EXE @cargoArgs;exit $LASTEXITCODE')
    if(-not $taskProcess.Start()){throw 'cargo start'};$taskStarted=$true
    $taskJob.Assign($taskProcess);$null=$taskGate.Set()
    $taskReaders=@($taskProcess.StandardOutput,$taskProcess.StandardError)
    for($taskSide=0;$taskSide -lt 2;$taskSide++){$taskTasks[$taskSide]=$taskReaders[$taskSide].ReadAsync($taskBuffers[$taskSide],0,4096)}
    while($true){
        for($taskSide=0;$taskSide -lt 2;$taskSide++){
            if(-not $taskDone[$taskSide] -and $taskTasks[$taskSide].IsCompleted){
                $taskN=$taskTasks[$taskSide].GetAwaiter().GetResult()
                if($taskN -eq 0){$taskDone[$taskSide]=$true}else{
                    if($taskLogs[$taskSide].Length+$taskN -gt 32768){throw 'cargo log bound'}
                    $null=$taskLogs[$taskSide].Append($taskBuffers[$taskSide],0,$taskN)
                    $taskTasks[$taskSide]=$taskReaders[$taskSide].ReadAsync($taskBuffers[$taskSide],0,4096)
                }
            }
        }
        $taskUsed=Usage;$taskPeak=[math]::Max($taskPeak,$taskUsed)
        if($taskUsed -gt $taskLimit-2097152L){throw 'cargo temporary budget guard (2MiB reserve)'}
        if([IO.DriveInfo]::new('D:\').AvailableFreeSpace -lt 5368709120L){throw 'free space guard'}
        if($taskTimer.Elapsed.TotalSeconds -gt 180){throw 'cargo deadline'}
        if($taskProcess.HasExited -and $taskDone[0] -and $taskDone[1]){
            # wrapper終了直後のJob集計遅延だけを許容し、子は同じJob内で最大2秒待つ。
            $taskDrainTimer=[Diagnostics.Stopwatch]::StartNew()
            while($taskJob.Active -ne 0 -and $taskDrainTimer.ElapsedMilliseconds -lt 2000){Start-Sleep -Milliseconds 25}
            $taskActive=$taskJob.Active;$taskDrainTimer.Stop()
            if($taskActive -ne 0){
                $taskPidSnapshot='unavailable';$taskPidError=$null;$taskMembers=@()
                try{
                    $taskPidSnapshot=$taskJob.ProcessIdSnapshot()
                    if($taskPidSnapshot -match ';pids=([^;]*)'){
                        foreach($taskRawPid in $Matches[1].Split(',',[StringSplitOptions]::RemoveEmptyEntries)){
                            $taskPid=[long]::Parse($taskRawPid,[Globalization.CultureInfo]::InvariantCulture)
                            $taskMember=Get-CimInstance Win32_Process -Filter ("ProcessId = $taskPid") -ErrorAction Stop
                            if($null -eq $taskMember){$taskMembers+=,[pscustomobject]@{ProcessId=$taskPid;details_unavailable='not returned by CIM'}}
                            else{$taskMembers+=,[pscustomobject]@{ProcessId=[long]$taskMember.ProcessId;ParentProcessId=[long]$taskMember.ParentProcessId;Name=[string]$taskMember.Name;ExecutablePath=[string]$taskMember.ExecutablePath}}
                        }
                    }
                }catch{$taskPidError=$_.Exception.Message}
                $taskMembersJson=ConvertTo-Json -InputObject $taskMembers -Compress -Depth 3
                throw "cargo root exited with $taskActive surviving job process(es) after drain grace; Job PID list=$taskPidSnapshot; PID details=$taskMembersJson; PID diagnostic error=$taskPidError"
            }
            $taskExit=$taskProcess.ExitCode;break
        }
        Start-Sleep -Milliseconds 100
    }
}catch{$taskFailure=$_.Exception.Message}
finally{
    try {
        if($null -ne $taskJob){$taskJob.StopAndWait(5000)}
        if($taskStarted -and -not $taskProcess.HasExited){$taskProcess.Kill($true);if(-not $taskProcess.WaitForExit(5000)){throw 'cargo process did not finish'}}
    } catch { $taskFailure=$_.Exception.Message }
    finally { $taskTimer.Stop();$taskProcess.Dispose();if($null -ne $taskGate){$taskGate.Dispose()};if($null -ne $taskJob){$taskJob.Dispose()};$taskLease.Dispose() }
}
foreach($taskLog in $taskLogs){Write-Output $taskLog.ToString()}
$taskEnd=Usage
$null=Assert-KhcStorageBudget
[ordered]@{exit=$taskExit;failure=$taskFailure;toolchain=$taskToolchain;start_bytes=$taskStart;observed_peak_bytes=$taskPeak;end_bytes=$taskEnd;fixed_cap_bytes=$taskCap;remaining_bytes=$taskCap-$taskEnd;seconds=$taskTimer.Elapsed.TotalSeconds;jobs=1;monitor='sampling with 2MiB reserve; NOT OS quota or guaranteed peak';deletions=0} | ConvertTo-Json -Compress
if($taskFailure){exit 1}
exit $taskExit
