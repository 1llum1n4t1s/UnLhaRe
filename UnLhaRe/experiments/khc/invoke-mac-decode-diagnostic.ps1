#requires -Version 7.0
# 固定診断専用。利用者の入口はrun-serial-cargo.ps1。
[CmdletBinding(DefaultParameterSetName='Initial')]
param(
    [Parameter(Mandatory,ParameterSetName='Initial')][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ProtocolSha256,
    [Parameter(Mandatory,ParameterSetName='Retry')][switch]$Retry,
    [Parameter(Mandatory,ParameterSetName='Retry')][ValidatePattern('\A[0-9a-f]{64}\z')][string]$AmendmentSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$module=Get-Module storage-lifecycle
if($PSCmdlet.ParameterSetName -ceq 'Retry'){
    if(-not $Retry){throw 'Retry must be explicitly true.'}
    $retrySnapshot=& $module {
        param($sha)
        $path=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-decode-phase-retry-amendment.json')
        $bytes=Read-KhcBoundedSnapshotBytes $path 32768
        $spec=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 32768
        Assert-KhcMacDecodeRetryAmendment $spec
        $trust=Get-KhcMacDecodeRetryTrustSpec $spec.controller_sha256 $spec.snapshot_sha256
        if($sha -cne $trust.AmendmentSha256){throw 'Retry amendment must match the reviewed fixed raw SHA.'}
        return [pscustomobject]@{Spec=$spec;Bytes=$bytes}
    } $AmendmentSha256
}
$protocolPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-decode-phase-build-protocol.json')
$snapshot=if($Retry){$null}else{& $module {
    param($path,$sha)
    $bytes=Read-KhcBoundedSnapshotBytes $path 32768
    $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if($actual -cne $sha){throw 'Diagnostic protocol snapshot SHA mismatch.'}
    $value=ConvertFrom-Json -AsHashtable -InputObject ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
    Assert-KhcMacDecodeDiagnosticProtocol $value
    return [pscustomobject]@{Spec=$value;Base64=[Convert]::ToBase64String($bytes)}
} $protocolPath $ProtocolSha256}
$spec=if($Retry){$retrySnapshot.Spec}else{$snapshot.Spec}
$ssh='C:\Program Files\Git\usr\bin\ssh.exe'
if(-not (Test-Path -LiteralPath $ssh -PathType Leaf)){throw 'Approved absolute SSH executable missing.'}
$lease=$null;$process=$null;$recorded=$false;$saved=$false;$spawned=$false
try{
    $lease=Enter-KhcCargoLease
    if($Retry){& $module {param($raw,$sha) Start-KhcMacDecodeRetry $raw $sha} $retrySnapshot.Bytes $AmendmentSha256}
    else{& $module {param($p,$sha,$raw) Start-KhcMacDecodeDiagnostic $p $sha $raw} $spec $ProtocolSha256 $snapshot.Base64}
    $recorded=$true
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$ssh;$info.WorkingDirectory=$PSScriptRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    # root・ツール名は固定、埋込みSHAは検証済み小文字hexのみ。
    $command='[ "$(/usr/bin/shasum -a 256 {0}/tools/mac-decode-phase-build.py | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && [ "$(/usr/bin/shasum -a 256 {0}/journal/mac-decode-phase-build-protocol.json | /usr/bin/cut -d '' '' -f 1)" = "{2}" ] && /usr/bin/python3 -I -B {0}/tools/mac-decode-phase-build.py --protocol-sha {2}' -f $spec.root,$spec.controller_sha256,$ProtocolSha256
    if($Retry){$command='[ "$(/usr/bin/shasum -a 256 {0}/tools/mac-decode-phase-retry.py | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && [ "$(/usr/bin/shasum -a 256 {0}/journal/mac-decode-phase-retry-amendment.json | /usr/bin/cut -d '' '' -f 1)" = "{2}" ] && /usr/bin/python3 -I -B {0}/tools/mac-decode-phase-retry.py --amendment-sha {2}' -f $spec.root,$spec.controller_sha256,$AmendmentSha256}
    foreach($arg in @('-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','m3mb14',$command)){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    if(-not $process.Start()){throw 'SSH process did not start.'};$spawned=$true
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
                    if($logs[$side].Length+$count -gt $cap){throw 'SSH diagnostic output exceeds bounded memory limit.'}
                    $null=$logs[$side].Append($buffers[$side],0,$count)
                    $tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)
                }
            }
        }
        if($timer.Elapsed.TotalSeconds -gt 380){throw 'SSH diagnostic deadline exceeded; remote closure unknown.'}
        if($process.HasExited -and $done[0] -and $done[1]){break}
        Start-Sleep -Milliseconds 100
    }
    $lines=@($logs[0].ToString() -split '\r?\n' | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($lines.Count -ne 1){throw 'Diagnostic requires exactly one terminal JSON line.'}
    if($logs[0].ToString() -cne $lines[0]+"`n"){throw 'Diagnostic terminal must retain the exact canonical native line.'}
    # native canonical JSONの原bytesを保持し、PSの再serializeを検証根拠にしない。
    $receiptBytes=[Text.UTF8Encoding]::new($false).GetBytes($lines[0]+"`n")
    $receipt=ConvertFrom-Json -InputObject $lines[0] -AsHashtable
    if(-not $Retry){& $module {param($r) $ledger=Get-KhcMacDecodeDiagnosticLedger;Assert-KhcMacDecodeDiagnosticTerminal $ledger.Start $r} $receipt}
    if($process.ExitCode -ne $receipt.exit){throw 'SSH exit differs from diagnostic terminal.'}
    if($Retry){& $module {param($raw) Save-KhcMacDecodeRetryTerminal $raw} $receiptBytes}
    else{& $module {param($raw) Save-KhcMacDecodeDiagnosticTerminal $raw} $receiptBytes}
    $saved=$true
    Write-Output (ConvertTo-Json -InputObject $receipt -Depth 20 -Compress)
    exit ([int]$receipt.exit)
}catch{
    if($recorded -and -not $saved){throw "Diagnostic start remains unresolved; every next Cargo/registration stays blocked. $($_.Exception.Message)"}
    throw
}finally{
    try{
        if($null -ne $process){try{if($spawned -and -not $process.HasExited){$process.Kill($true);if(-not $process.WaitForExit(5000)){throw 'Local SSH termination unknown; remote diagnostic remains unresolved.'}}}finally{$process.Dispose()}}
    }finally{if($null -ne $lease){$lease.Dispose()}}
}
