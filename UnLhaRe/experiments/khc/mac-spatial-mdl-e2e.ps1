#requires -Version 7.0
# 固定ps-free correctness endpointのみ。private終端sealは親がcanonical再読後に別途登録する。
[CmdletBinding()]
param([string]$WorkDirectory='', [Parameter(Mandatory)][string]$ProtocolPath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ProtocolSha256,[switch]$ValidateProtocolOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$module=Get-Module storage-lifecycle
$protocol=& $module {param($path,$sha) Read-KhcMacNativeE2eProtocol $path $sha} $ProtocolPath $ProtocolSha256
if($ValidateProtocolOnly){return}
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$paths=Get-KhcStorageTaskPaths
if($paths.TaskId -cne 'goal-restore-20261019'){throw 'Remote native worker requires the approved current task.'}
$record=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if([string]$record.run_id -cnotmatch '\A[0-9a-f]{32}\z' -or [IO.Path]::GetFullPath($env:KHC_STORAGE_RUN_RECORD) -cne (Join-Path (Join-Path (Join-Path $paths.StateRoot 'runs') $record.run_id) 'run.json') -or [IO.Path]::GetFullPath($env:KHC_STORAGE_INVOCATION) -cne (Join-Path (Join-Path (Join-Path $paths.StateRoot 'runs') $record.run_id) 'invocation.clixml')){throw 'Native worker environment must use this exact registered run and invocation.'}
if($record.max_bytes -ne 8MB -or $record.max_entries -ne 96 -or $record.work_directory -cne $WorkDirectory){throw 'Remote native worker registration resources mismatch.'}
$registration=& $module {param($state,$id) $reserve=Get-KhcRecycleV6RunAnchor $state $id;Get-KhcMacNativeE2eRegistration $state $id $reserve -RequireInvocation} $paths.StateRoot $record.run_id
if($null -eq $registration -or $registration.Record.protocol_sha256 -cne $ProtocolSha256 -or $registration.Record.worker_sha256 -cne (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Worker/protocol differs from private registration.'}
if(Test-Path -LiteralPath $WorkDirectory){throw 'Remote work root must be unused.'}
$null=[IO.Directory]::CreateDirectory($WorkDirectory)
$null=Assert-KhcStorageBudget
$ssh='C:\Program Files\Git\usr\bin\ssh.exe'
if(-not (Test-Path -LiteralPath $ssh -PathType Leaf)){throw 'Approved Git SSH is missing.'}
$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$ssh;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false,$true)
$p=$protocol.Data
$command='[ "$(/usr/bin/shasum -a 256 {0}/tools/mac-native-e2e-endpoint.py | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && [ "$(/usr/bin/shasum -a 256 {0}/downloads/mac-native-e2e-ps-free-protocol.json | /usr/bin/cut -d '' '' -f 1)" = "{2}" ] && /usr/bin/python3 -I -B {0}/tools/mac-native-e2e-endpoint.py --windows-run-id {3} --protocol-sha {2}' -f $p.root,$p.endpoint_sha256,$ProtocolSha256,$record.run_id
foreach($arg in @('-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','m3mb14',$command)){$info.ArgumentList.Add($arg)}
$process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
try{
    if(-not $process.Start()){throw 'SSH start failed.'};$started=$true
    $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(4096),[char[]]::new(4096))
    $logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new());$done=@($false,$false)
    $tasks=@($readers[0].ReadAsync($buffers[0],0,4096),$readers[1].ReadAsync($buffers[1],0,4096))
    $timer=[Diagnostics.Stopwatch]::StartNew();$nextBudget=0.0
    while($true){
        for($side=0;$side -lt 2;$side++){
            if(-not $done[$side] -and $tasks[$side].IsCompleted){$n=$tasks[$side].GetAwaiter().GetResult();if($n -eq 0){$done[$side]=$true}else{
                $null=$logs[$side].Append($buffers[$side],0,$n)
                $cap=if($side -eq 0){65536}else{16384}
                if([Text.Encoding]::UTF8.GetByteCount($logs[$side].ToString()) -gt $cap){throw 'Endpoint stream byte bound exceeded.'}
                $tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)
            }}
        }
        if($timer.Elapsed.TotalSeconds -gt 350){throw 'Endpoint observation deadline; private remote run remains unsealed.'}
        if($timer.Elapsed.TotalSeconds -ge $nextBudget){$null=Assert-KhcStorageBudget;$nextBudget=$timer.Elapsed.TotalSeconds+5}
        if($process.HasExited -and $done[0] -and $done[1]){break}
        Start-Sleep -Milliseconds 100
    }
    # stdoutの1行+末尾LFを再serializeせず保持し、Mac canonical bytesと同じSHAを維持する。
    $raw=$logs[0].ToString()
    if(-not $raw.EndsWith("`n") -or $raw.Contains("`r") -or $raw.Substring(0,$raw.Length-1).Contains("`n")){throw 'Endpoint must emit exactly one canonical JSON line with LF.'}
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($raw)
    $receiptSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $verified=& $module {param($bytes,$sha,$protocol,$protocolSha,$id,$oracle) $receipt=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha;Assert-KhcMacNativeE2eReceiptData $receipt $protocol $protocolSha $id $oracle} $bytes $receiptSha $p $ProtocolSha256 $record.run_id $registration.Oracle
    if($process.ExitCode -ne $verified.Receipt.exit){throw 'SSH exit differs from canonical endpoint status.'}
    if($null -ne $verified.ReportBytes){$stream=[IO.File]::Open((Join-Path $WorkDirectory 'native-e2e-report.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($verified.ReportBytes);$stream.Flush($true)}finally{$stream.Dispose()}}
    $stream=[IO.File]::Open((Join-Path $WorkDirectory 'endpoint-receipt.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    Write-Output (ConvertTo-Json -Compress -InputObject ([ordered]@{run_id=$record.run_id;status=$verified.Receipt.status;receipt_sha256=$receiptSha;report_sha256=$verified.Receipt.report_sha256;children_absent=$true;seal='parent canonical confirmation required'}))
    exit ([int]$verified.Receipt.exit)
}finally{
    try{if($started -and -not $process.HasExited){$process.Kill($true);$null=$process.WaitForExit(5000)}}finally{$process.Dispose()}
}
