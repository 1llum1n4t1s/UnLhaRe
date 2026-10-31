#requires -Version 7.0
# run-storage-experimentの正規登録からだけ起動する候補example専用worker。
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkDirectory,[Parameter(Mandatory)][string]$ProtocolPath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ProtocolSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$timer=[Diagnostics.Stopwatch]::StartNew()
Import-Module 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\storage-lifecycle.psm1' -Force
$module=Get-Module storage-lifecycle
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$paths=Get-KhcStorageTaskPaths
$context=& $module {
    param($state,$work,$protocolPath,$protocolSha,$workerPath)
    $kind=Get-KhcMacCandidateE2eKind
    if($protocolPath -cne $kind.ProtocolPath){throw 'Candidate E2E requires its fixed protocol.'}
    $recordPath=Assert-KhcPlainPath $env:KHC_STORAGE_RUN_RECORD
    $record=ConvertFrom-Json -AsHashtable -InputObject ([Text.UTF8Encoding]::new($false,$true).GetString((Read-KhcBoundedSnapshotBytes $recordPath 8192)))
    if($record.run_id -cnotmatch '\A[0-9a-f]{32}\z' -or $recordPath -cne (Join-Path (Join-Path (Join-Path $state 'runs') $record.run_id) 'run.json') -or $record.work_directory -cne $work -or $record.max_bytes -ne 8MB -or $record.max_entries -ne 96 -or $env:KHC_STORAGE_INVOCATION -cne (Join-Path (Split-Path $recordPath -Parent) 'invocation.clixml')){throw 'Candidate E2E worker requires the exact real storage run and invocation.'}
    $reserve=Get-KhcRecycleV6RunAnchor $state $record.run_id
    $registration=Get-KhcMacCandidateE2eRegistration $state $record.run_id $reserve -RequireInvocation
    if($null -eq $registration -or $registration.Record.protocol_sha256 -cne $protocolSha -or $workerPath -cne $registration.Trust.WorkerPath -or (Get-KhcRecycleV6Hash $workerPath) -cne $registration.Record.worker_sha256){throw 'Candidate E2E executing worker differs from its frozen registration.'}
    Assert-KhcMacCandidateE2eBuildEvidence
    return [pscustomobject]@{Record=$record;Registration=$registration;RecordPath=$recordPath}
} $paths.StateRoot $WorkDirectory $ProtocolPath $ProtocolSha256 $PSCommandPath
$lease=$null;$process=$null;$spawned=$false
try{
    # 親runnerのserial.lockに加え、Mac例の実行中は共有Cargo mutexも保持する。
    $lease=& $module {
        param($state,$record)
        $held=[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        try{Assert-KhcNoPendingMacBuild;Assert-KhcNoPendingStorageRuns -AllowedRecordPath $record;$null=Assert-KhcStorageBudget;return $held}catch{$held.Dispose();throw}
    } $paths.StateRoot $context.RecordPath
    if(Test-Path -LiteralPath $WorkDirectory){throw 'Candidate E2E work root must be unused.'}
    $null=[IO.Directory]::CreateDirectory($WorkDirectory)
    $p=$context.Registration.Protocol
    $ssh='C:\Program Files\Git\usr\bin\ssh.exe'
    if(-not (Test-Path -LiteralPath $ssh -PathType Leaf)){throw 'Approved SSH executable missing.'}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$ssh;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false,$true)
    $command='[ "$(/usr/bin/shasum -a 256 {0}/tools/mac-cdf-candidate-e2e-endpoint.py | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && [ "$(/usr/bin/shasum -a 256 {0}/journal/mac-cdf-candidate-e2e-protocol.json | /usr/bin/cut -d '' '' -f 1)" = "{2}" ] && /usr/bin/python3 -I -B {0}/tools/mac-cdf-candidate-e2e-endpoint.py --windows-run-id {3} --windows-registration-sha {4} --protocol-sha {2}' -f $p.root,$p.endpoint_sha256,$ProtocolSha256,$context.Record.run_id,$context.Registration.Record.record_sha256
    foreach($arg in @('-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','m3mb14',$command)){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    if(-not $process.Start()){throw 'Candidate E2E SSH start failed.'};$spawned=$true
    $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(4096),[char[]]::new(4096));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
    $tasks=@($readers[0].ReadAsync($buffers[0],0,4096),$readers[1].ReadAsync($buffers[1],0,4096));$done=@($false,$false);$nextBudget=0.0
    while($true){
        for($side=0;$side -lt 2;$side++){if(-not $done[$side] -and $tasks[$side].IsCompleted){$count=$tasks[$side].GetAwaiter().GetResult();if($count -eq 0){$done[$side]=$true}else{
            $cap=if($side -eq 0){131072}else{16384};if($logs[$side].Length+$count -gt $cap){throw 'Candidate E2E SSH output exceeds fixed bound.'}
            $null=$logs[$side].Append($buffers[$side],0,$count);$tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)
        }}}
        if($timer.Elapsed.TotalSeconds -ge $nextBudget){$null=Assert-KhcStorageBudget;$nextBudget=$timer.Elapsed.TotalSeconds+10}
        if($timer.Elapsed.TotalSeconds -gt 350){throw 'Candidate E2E worker deadline; private run remains unsealed.'}
        if($process.HasExited -and $done[0] -and $done[1]){break};Start-Sleep -Milliseconds 100
    }
    $raw=$logs[0].ToString()
    if(-not $raw.EndsWith("`n") -or $raw.Contains("`r") -or $raw.Substring(0,$raw.Length-1).Contains("`n")){throw 'Candidate E2E requires one canonical LF receipt.'}
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($raw)
    # 閉鎖不明でも正規RUN内へ受信原文を保全し、seal/cleanupは許可しない。
    $stream=[IO.File]::Open((Join-Path $WorkDirectory 'endpoint-receipt.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    $summary=& $module {param($reg,$bytes,$id) Invoke-KhcMacCandidateE2eVerifier $reg.ProtocolBytes $reg.Record.protocol_sha256 $bytes $id $reg.Record.record_sha256} $context.Registration $bytes $context.Record.run_id
    if($process.ExitCode -ne $summary.exit){throw 'Candidate E2E SSH exit differs from verified receipt.'}
    if($timer.Elapsed.TotalSeconds -gt 350){throw 'Candidate E2E verification deadline; run remains unsealed.'}
    $receipt=ConvertFrom-Json -AsHashtable -InputObject $raw
    foreach($item in @(@{Name='candidate-e2e-report.json';Bytes=$(if($null -ne $receipt.report_base64){[Convert]::FromBase64String($receipt.report_base64)}else{$null})})){
        if($null -eq $item.Bytes){continue};$stream=[IO.File]::Open((Join-Path $WorkDirectory $item.Name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($item.Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    }
    # 親runnerがJob閉鎖後に原bytesを再検証してprivate sealを保存する。
    if($timer.Elapsed.TotalSeconds -gt 350){throw 'Candidate E2E evidence persistence exceeded worker deadline.'}
    Write-Output (ConvertTo-Json -Compress -InputObject $summary)
    exit ([int]$summary.exit)
}catch{
    $failure=$_
    # timeout/partial受信も固定名・固定上限内の原データだけを保持する。
    if((Test-Path -LiteralPath $WorkDirectory) -and (Test-Path Variable:logs)){
        for($side=0;$side -lt 2;$side++){
            if($logs[$side].Length -eq 0){continue}
            $name=if($side -eq 0){'endpoint-stdout.partial.txt'}else{'endpoint-stderr.partial.txt'}
            try{$data=[Text.UTF8Encoding]::new($false,$true).GetBytes($logs[$side].ToString());$stream=[IO.File]::Open((Join-Path $WorkDirectory $name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($data);$stream.Flush($true)}finally{$stream.Dispose()}}catch{}
        }
    }
    throw $failure
}finally{
    $held=@();if($null -ne $lease){$held=@($lease)}
    & $module {param($p,$s,$held) Complete-KhcVerifierReadLease $p $s $held} $process $spawned $held
}
