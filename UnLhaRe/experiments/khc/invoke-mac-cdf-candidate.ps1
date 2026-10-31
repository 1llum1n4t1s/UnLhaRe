#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ProtocolSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$module=Get-Module storage-lifecycle
$snapshot=& $module {
    param($sha)
    Assert-KhcVerifierQuarantineClear
    $path='D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-cdf-candidate-build-protocol.json'
    $bytes=Read-KhcBoundedSnapshotBytes $path 32768
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 32768
    Assert-KhcMacCdfCandidateProtocol $protocol
    $null=Get-KhcMacCdfCandidateTrustSpec $protocol.controller_sha256 $protocol.snapshot_sha256 $sha
    return [pscustomobject]@{Spec=$protocol;Bytes=$bytes}
} $ProtocolSha256
$spec=$snapshot.Spec
$ssh='C:\Program Files\Git\usr\bin\ssh.exe'
if(-not (Test-Path -LiteralPath $ssh -PathType Leaf)){throw 'Approved absolute SSH executable missing.'}
$lease=$null;$process=$null;$recorded=$false;$saved=$false;$spawned=$false
try{
    $lease=Enter-KhcCargoLease
    & $module {param($bytes,$sha) Start-KhcMacCdfCandidate $bytes $sha} $snapshot.Bytes $ProtocolSha256
    $recorded=$true
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$ssh;$info.WorkingDirectory=$PSScriptRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    # 全埋込み値は固定ROOTと検証済み小文字hexのみ。
    $command='[ "$(/usr/bin/shasum -a 256 {0}/tools/mac-cdf-candidate-build.py | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && [ "$(/usr/bin/shasum -a 256 {0}/journal/mac-cdf-candidate-build-protocol.json | /usr/bin/cut -d '' '' -f 1)" = "{2}" ] && /usr/bin/python3 -I -B {0}/tools/mac-cdf-candidate-build.py --protocol-sha {2}' -f $spec.root,$spec.controller_sha256,$ProtocolSha256
    foreach($arg in @('-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','m3mb14',$command)){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    if(-not $process.Start()){throw 'Candidate SSH did not start.'};$spawned=$true
    $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(4096),[char[]]::new(4096));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
    $tasks=@($readers[0].ReadAsync($buffers[0],0,4096),$readers[1].ReadAsync($buffers[1],0,4096));$done=@($false,$false);$timer=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        for($side=0;$side -lt 2;$side++){if(-not $done[$side] -and $tasks[$side].IsCompleted){
            $count=$tasks[$side].GetAwaiter().GetResult()
            if($count -eq 0){$done[$side]=$true}else{
                $cap=if($side -eq 0){1MB}else{64KB}
                if($logs[$side].Length+$count -gt $cap){throw 'Candidate SSH output exceeds bounded memory.'}
                $null=$logs[$side].Append($buffers[$side],0,$count);$tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)
            }
        }}
        if($timer.Elapsed.TotalSeconds -gt 380){throw 'Candidate SSH deadline exceeded; remote closure remains unknown.'}
        if($process.HasExited -and $done[0] -and $done[1]){break};Start-Sleep -Milliseconds 100
    }
    $text=$logs[0].ToString()
    $lines=@($text -split '\r?\n' | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($lines.Count -ne 1 -or $text -cne $lines[0]+"`n"){throw 'Candidate requires exactly one canonical native receipt line.'}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)
    $receipt=ConvertFrom-Json -AsHashtable -InputObject $lines[0]
    if($process.ExitCode -ne $receipt.exit){throw 'Candidate SSH exit differs from native receipt.'}
    & $module {param($raw) Save-KhcMacCdfCandidateTerminal $raw} $bytes
    $saved=$true
    Write-Output $text.TrimEnd("`n")
    exit ([int]$receipt.exit)
}catch{
    if($recorded -and -not $saved){throw "Candidate remains unresolved; subsequent Cargo is blocked. $($_.Exception.Message)"}
    throw
}finally{
    $held=@();if($null -ne $lease){$held=@($lease)}
    & $module {param($p,$s,$leases) Complete-KhcVerifierReadLease $p $s $leases} $process $spawned $held
}
