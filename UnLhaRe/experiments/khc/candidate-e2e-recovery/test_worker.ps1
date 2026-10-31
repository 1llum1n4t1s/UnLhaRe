#requires -Version 7.0
# 先行失敗条件: 未登録/偽env/旧protocol/未知pathからの起動、SSH前のgate漏れ、
# content-only receiptの許可昇格。実登録・SSH・Mac・fixture書込みは行わない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$worker=Join-Path $PSScriptRoot 'mac-cdf-candidate-e2e-recovery.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($worker,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Recovery worker missing or parser failure'}
$passed=0
function Accept([scriptblock]$body){& $body;$script:passed++}
function Reject([scriptblock]$body){$failed=$false;try{& $body}catch{$failed=$true};if(-not $failed){throw 'Invalid recovery worker input accepted'};$script:passed++}
foreach($name in @('Get-KhcRecoveryWorkerContract','Assert-KhcRecoveryWorkerInvocation','Assert-KhcRecoveryWorkerIntegration','Assert-KhcRecoveryReceiptAuthorization')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing real worker contract: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
$contract=Get-KhcRecoveryWorkerContract
$work='D:\Codex\UnLhaRe\goal-restore-20261019\run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
Accept {Assert-KhcRecoveryWorkerInvocation $work $contract.ProtocolPath $contract.ProtocolSha256}
foreach($bad in @(('0'*64),'173EF073007C62D9A5DC013BB5724C1EA8C8177EE6327A6081EA752540403DBF')){Reject {Assert-KhcRecoveryWorkerInvocation $work $contract.ProtocolPath $bad}}
foreach($bad in @('relative','D:\elsewhere\run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','D:\Codex\UnLhaRe\goal-restore-20261019\run-a')){Reject {Assert-KhcRecoveryWorkerInvocation $bad $contract.ProtocolPath $contract.ProtocolSha256}}
Reject {Assert-KhcRecoveryWorkerInvocation $work 'D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-cdf-candidate-e2e-protocol.json' $contract.ProtocolSha256}
Reject {Assert-KhcRecoveryWorkerIntegration}
foreach($summary in @(@{verified=$true;cleanup_allowed=$true},@{verified=$false;content_verified=$true;verification_scope='receipt-content-only';cleanup_allowed=$false;recovery_authorized=$false;native_execution_enabled=$false})){
    Reject {Assert-KhcRecoveryReceiptAuthorization $summary}
}
Accept {
    $commands=@($ast.EndBlock.Statements | Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]})
    $integration=@($commands | Where-Object {$_.Extent.Text -match '^Assert-KhcRecoveryWorkerIntegration'})
    $import=@($commands | Where-Object {$_.Extent.Text -match '^Import-Module'})
    $timer=@($commands | Where-Object {$_.Extent.Text -match '^\$timer=\[Diagnostics.Stopwatch\]::StartNew\(\)'})
    if($timer.Count -ne 1 -or $timer[0].Extent.StartOffset -ge $integration[0].Extent.StartOffset){throw 'Worker deadline excludes recovery admission preparation'}
    if($integration.Count -ne 1 -or $import.Count -ne 1 -or $integration[0].Extent.StartOffset -ge $import[0].Extent.StartOffset){throw 'Recovery gate must precede real module/state interaction'}
    $text=$ast.Extent.Text
    foreach($required in @('Get-KhcMacCandidateRecoveryE2eRegistration','Assert-KhcMacCandidateRecoveryE2ePending','Invoke-KhcMacCandidateRecoveryE2eVerifier','Complete-KhcVerifierReadLease','FileMutexLease','cargo.lock','endpoint-recovery-receipt.json','candidate-e2e-recovery-report.json','ConnectTimeout=10','StrictHostKeyChecking=yes','131072','16384','350')){
        if($text -notmatch [regex]::Escape($required)){throw "Missing concrete worker behavior: $required"}
    }
    if($text -match '\bGet-KhcMacCandidateE2eRegistration\b' -or $text -match '\bInvoke-KhcMacCandidateE2eVerifier\b'){throw 'Recovery worker fell back to old registration/verifier'}
    if(([regex]::Matches($text,'Assert-KhcRecoveryWorkerIntegration')).Count -lt 3){throw 'Missing immediate SSH recheck'}
}
Accept {
    $script:originalImport=$false
    function Import-Module {$script:originalImport=$true;throw 'Must never import real lifecycle'}
    $saved=$env:KHC_STORAGE_RUN_RECORD
    try{
        $env:KHC_STORAGE_RUN_RECORD='forged-record'
        $failure=$null
        try{& $worker -WorkDirectory $work -ProtocolPath $contract.ProtocolPath -ProtocolSha256 $contract.ProtocolSha256}catch{$failure=$_}
        if($null -eq $failure -or $failure.Exception.Message -notmatch 'recovery integration missing'){throw 'Native worker did not refuse before lifecycle interaction'}
        if($script:originalImport){throw 'Worker touched real lifecycle before authorization'}
    }finally{$env:KHC_STORAGE_RUN_RECORD=$saved}
}
Write-Output "Recovery worker pure contracts: $passed passed; no storage registration, files, SSH or Mac invocation"
