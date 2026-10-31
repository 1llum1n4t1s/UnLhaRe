#requires -Version 7.0
# remote CargoはWindowsの共通leaseとimmutableな開始/終端台帳の下で一度だけ実行する。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('prepare-source','fetch','check','build')][string]$Stage,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$SourceZipSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$BuildScriptSha256,
    [ValidatePattern('\A[0-9a-fA-F]{64}\z|\A\z')][string]$AmendmentSpecSha256='',
    [ValidateRange(30,1800)][int]$TimeoutSeconds=900
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$module=Get-Module storage-lifecycle
$paths=Get-KhcStorageTaskPaths
if($paths.TaskId -cne 'goal-restore-20261019'){throw 'Remote build is restricted to the existing approved task.'}
$profile=& $module {Get-KhcMacRemoteReservation}
if($null -eq $profile){throw 'Initialize the approved persistent Mac reservation before remote execution.'}
$sourceSha=$SourceZipSha256.ToLowerInvariant();$scriptSha=$BuildScriptSha256.ToLowerInvariant()
$amendmentSha=$AmendmentSpecSha256.ToLowerInvariant()
if($amendmentSha -and $Stage -cne 'build'){throw 'Only the unstarted build stage can use an amendment.'}
$ssh='C:\Program Files\Git\usr\bin\ssh.exe'
if(-not (Test-Path -LiteralPath $ssh -PathType Leaf)){throw 'The approved absolute Git SSH executable is missing.'}
$lease=$null;$process=$null;$started=$false;$stageRecorded=$false;$terminalSaved=$false
try{
    $lease=Enter-KhcCargoLease
    & $module {param($stage,$source,$scriptHash,$amendment) Start-KhcMacNativeBuildStage $stage $source $scriptHash $amendment} $Stage $sourceSha $scriptSha $amendmentSha
    $stageRecorded=$true
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$ssh;$info.WorkingDirectory=$PSScriptRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    # 全埋込値は固定root、ValidateSet stage、hex SHAのみ。実行前にremote controller自身のSHAを照合する。
    $command='[ "$(/usr/bin/shasum -a 256 {0}/tools/mac-native-build.py | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && /usr/bin/python3 -I -B {0}/tools/mac-native-build.py {2} --source-sha {3}' -f $profile.root,$scriptSha,$Stage,$sourceSha
    if($amendmentSha){$command=('[ "$(/usr/bin/shasum -a 256 {0}/journal/mac-native-build-amendment-spec.json | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && ' -f $profile.root,$amendmentSha)+$command}
    foreach($arg in @('-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','m3mb14',$command)){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    if(-not $process.Start()){throw 'SSH process did not start.'};$started=$true
    $readers=@($process.StandardOutput,$process.StandardError)
    $buffers=@([char[]]::new(4096),[char[]]::new(4096));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
    $tasks=@($readers[0].ReadAsync($buffers[0],0,4096),$readers[1].ReadAsync($buffers[1],0,4096));$done=@($false,$false)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        for($side=0;$side -lt 2;$side++){
            if(-not $done[$side] -and $tasks[$side].IsCompleted){
                $count=$tasks[$side].GetAwaiter().GetResult()
                if($count -eq 0){$done[$side]=$true}else{
                    $cap=if($side -eq 0){1MB}else{64KB}
                    if($logs[$side].Length+$count -gt $cap){throw 'SSH output exceeds the bounded in-memory log limit.'}
                    $null=$logs[$side].Append($buffers[$side],0,$count)
                    $tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)
                }
            }
        }
        if($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds){throw 'SSH observation deadline exceeded; remote termination is unknown.'}
        if($process.HasExited -and $done[0] -and $done[1]){break}
        Start-Sleep -Milliseconds 100
    }
    $lines=@($logs[0].ToString() -split '\r?\n' | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($lines.Count -eq 0){throw 'SSH returned no terminal JSON.'}
    $receipt=ConvertFrom-Json -InputObject $lines[-1] -AsHashtable -ErrorAction Stop
    & $module {param($stage,$result) $entry=@(Get-KhcMacBuildLedger | Where-Object {$_.Stage -ceq $stage});if($entry.Count -ne 1){throw 'Mac stage identity missing.'};Assert-KhcMacBuildTerminalData $entry[0].Start $result} $Stage $receipt
    if($process.ExitCode -ne $receipt.exit){throw 'SSH exit differs from the confirmed remote terminal exit.'}
    & $module {param($stage,$result) Save-KhcMacNativeBuildTerminal $stage $result} $Stage $receipt
    $terminalSaved=$true
    Write-Output (ConvertTo-Json -InputObject $receipt -Depth 12 -Compress)
    exit ([int]$receipt.exit)
}catch{
    if($stageRecorded -and -not $terminalSaved){throw "Mac stage remains unresolved in the private ledger; next Cargo/registration is blocked. $($_.Exception.Message)"}
    throw
}finally{
    if($null -ne $process){
        try{if($started -and -not $process.HasExited){$process.Kill($true);if(-not $process.WaitForExit(5000)){throw 'Local SSH descendants did not terminate; remote stage remains unresolved.'}}}finally{$process.Dispose();if($null -ne $lease){$lease.Dispose();$lease=$null}}
    }
    if($null -ne $lease){$lease.Dispose()}
}
