# 先行失敗条件: 旧run/binding差替え、claim共有、予約引下げ、未知field、虚偽seal。
# 実state・SSH・登録には触れない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Join-Path (Split-Path $PSScriptRoot -Parent) 'storage-lifecycle.psm1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($module,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'module parse failure'}
foreach($name in @('Get-KhcMacCandidateRecoveryE2eKind','Assert-KhcMacCandidateRecoveryRegistrationData','Assert-KhcMacCandidateRecoveryReceiptData','Assert-KhcMacCandidateRecoveryPendingData')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
$passed=0
function Accept([scriptblock]$s){& $s;$script:passed++}
function Reject([scriptblock]$s){$failed=$false;try{& $s}catch{$failed=$true};if(-not $failed){throw 'invalid data accepted'};$script:passed++}
$kind=Get-KhcMacCandidateRecoveryE2eKind
$new='a'*32;$record='b'*64;$invocation='c'*64;$amendment='d'*64;$fence='e'*64
$reserve=@{run_id=$new;registration_sha256=$record;max_bytes=8388608;max_entries=96;remote_candidate_recovery_required=$true}
$registration=@{schema=1;protocol='khc-mac-cdf-candidate-recovery-registration-v1';run_id=$new;record_sha256=$record;invocation_sha256=$invocation;old_run_id=$kind.OldRunId;windows_binding_sha256=$kind.WindowsBindingSha256;amendment_sha256=$amendment;fence_proof_sha256=$fence;protocol_sha256=$kind.ProtocolSha256;worker_sha256=('f'*64)}
$claim=@{schema=1;protocol='khc-mac-cdf-candidate-recovery-claim-v1';run_id=$new;record_sha256=$record;old_run_id=$kind.OldRunId;amendment_sha256=$amendment;fence_proof_sha256=$fence}
Accept {Assert-KhcMacCandidateRecoveryRegistrationData $registration $claim $reserve $new $record $invocation ('f'*64)}
$wireRegistration=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress $registration)
$wireClaim=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress $claim)
$wireReserve=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress $reserve)
if($wireRegistration.schema -isnot [long] -or $wireClaim.schema -isnot [long]){throw 'fixture must exercise JSON Int64'}
Accept {Assert-KhcMacCandidateRecoveryRegistrationData $wireRegistration $wireClaim $wireReserve $new $record $invocation ('f'*64)}
foreach($key in @('protocol','run_id','record_sha256','invocation_sha256','old_run_id','windows_binding_sha256','amendment_sha256','fence_proof_sha256','protocol_sha256','worker_sha256')){
    foreach($badValue in @(@{v=@()},@{v=$null},@{v=$true},@{v=1})){
        $bad=@{}+$registration;$bad[$key]=$badValue.v
        $wire=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress -Depth 8 $bad)
        Reject {Assert-KhcMacCandidateRecoveryRegistrationData $wire $wireClaim $wireReserve $new $record $invocation ('f'*64)}
    }
}
foreach($key in @('protocol','run_id','record_sha256','old_run_id','amendment_sha256','fence_proof_sha256')){
    foreach($badValue in @(@{v=@()},@{v=$null},@{v=$true},@{v=1})){
        $bad=@{}+$claim;$bad[$key]=$badValue.v
        $wire=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress -Depth 8 $bad)
        Reject {Assert-KhcMacCandidateRecoveryRegistrationData $wireRegistration $wire $wireReserve $new $record $invocation ('f'*64)}
    }
}
foreach($key in @('run_id','registration_sha256')){
    $bad=@{}+$reserve;$bad[$key]=@()
    $wire=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress -Depth 8 $bad)
    Reject {Assert-KhcMacCandidateRecoveryRegistrationData $wireRegistration $wireClaim $wire $new $record $invocation ('f'*64)}
}
foreach($badValue in @('1',$true)){$bad=@{}+$registration;$bad.schema=$badValue;Reject {Assert-KhcMacCandidateRecoveryRegistrationData $bad $claim $reserve $new $record $invocation ('f'*64)}}
foreach($key in @('old_run_id','windows_binding_sha256','amendment_sha256','fence_proof_sha256','protocol_sha256','worker_sha256','run_id','record_sha256','invocation_sha256')){
    $bad=@{}+$registration;$bad[$key]='0'*64
    Reject {Assert-KhcMacCandidateRecoveryRegistrationData $bad $claim $reserve $new $record $invocation ('f'*64)}
}
$bad=@{}+$claim;$bad.run_id='0'*32;Reject {Assert-KhcMacCandidateRecoveryRegistrationData $registration $bad $reserve $new $record $invocation ('f'*64)}
$bad=@{}+$reserve;$bad.max_bytes=1;Reject {Assert-KhcMacCandidateRecoveryRegistrationData $registration $claim $bad $new $record $invocation ('f'*64)}
$bad=@{}+$reserve;$bad.max_bytes='8388608';Reject {Assert-KhcMacCandidateRecoveryRegistrationData $registration $claim $bad $new $record $invocation ('f'*64)}
$bad=@{}+$reserve;$bad.max_entries='96';Reject {Assert-KhcMacCandidateRecoveryRegistrationData $registration $claim $bad $new $record $invocation ('f'*64)}
$bad=@{}+$registration;$bad.extra=1;Reject {Assert-KhcMacCandidateRecoveryRegistrationData $bad $claim $reserve $new $record $invocation ('f'*64)}
$raw=[Text.Encoding]::UTF8.GetBytes('receipt fixture')
$rawSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
$receipt=@{schema=1;protocol=$kind.Protocol;verified=$false;content_verified=$true;verification_scope='receipt-content-only';recovery_authorized=$false;native_execution_enabled=$false;protocol_sha256=$kind.ProtocolSha256;endpoint_sha256=$kind.EndpointSha256;source_sha256='36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05';purpose='candidate-example-correctness-only';windows_run_id=$new;windows_registration_sha256=$record;receipt_sha256=$rawSha;report_sha256=$null;closure_sha256=$null;status='failed';exit=1;cleanup_allowed=$false}
Accept {Assert-KhcMacCandidateRecoveryReceiptData $receipt $registration $raw}
$wireReceipt=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress $receipt)
if($wireReceipt.schema -isnot [long] -or $wireReceipt.exit -isnot [long]){throw 'receipt JSON fixture must exercise Int64'}
Accept {Assert-KhcMacCandidateRecoveryReceiptData $wireReceipt $wireRegistration $raw}
foreach($key in @('protocol','verification_scope','protocol_sha256','endpoint_sha256','source_sha256','purpose','windows_run_id','windows_registration_sha256','receipt_sha256','status')){
    foreach($badValue in @(@{v=@()},@{v=$null},@{v=$true},@{v=1})){
        $bad=@{}+$receipt;$bad[$key]=$badValue.v
        $wire=ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress -Depth 8 $bad)
        Reject {Assert-KhcMacCandidateRecoveryReceiptData $wire $wireRegistration $raw}
    }
}
foreach($key in @('schema','exit')){foreach($badValue in @('1',$true)){$bad=@{}+$receipt;$bad[$key]=$badValue;Reject {Assert-KhcMacCandidateRecoveryReceiptData $bad $registration $raw}}}
$done=@{}+$receipt;$done.status='done';$done.exit=0;$done.report_sha256=('2'*64);$done.closure_sha256=('3'*64)
Accept {Assert-KhcMacCandidateRecoveryReceiptData $done $registration $raw}
foreach($key in @('report_sha256','closure_sha256')){$bad=@{}+$done;$bad[$key]=$null;Reject {Assert-KhcMacCandidateRecoveryReceiptData $bad $registration $raw}}
foreach($key in @('verified','recovery_authorized','cleanup_allowed')){$bad=@{}+$receipt;$bad[$key]=$true;Reject {Assert-KhcMacCandidateRecoveryReceiptData $bad $registration $raw}}
$bad=@{}+$receipt;$bad.verification_scope='authenticated';Reject {Assert-KhcMacCandidateRecoveryReceiptData $bad $registration $raw}
$bad=@{}+$receipt;$bad.windows_run_id='0'*32;Reject {Assert-KhcMacCandidateRecoveryReceiptData $bad $registration $raw}
Reject {Assert-KhcMacCandidateRecoveryReceiptData $receipt $registration ([byte[]](1,2))}
$pending=@($kind.OldRunId,$new)
Accept {Assert-KhcMacCandidateRecoveryPendingData $pending $new $kind.WindowsBindingSha256}
foreach($ids in @(@($kind.OldRunId),@($new),@($kind.OldRunId,$new,('1'*32)),@($kind.OldRunId,$kind.OldRunId,$new))){
    Reject {Assert-KhcMacCandidateRecoveryPendingData $ids $new $kind.WindowsBindingSha256}
}
Reject {Assert-KhcMacCandidateRecoveryPendingData $pending $new ('0'*64)}
Write-Output "Recovery lifecycle pure assertions: $passed passed"
