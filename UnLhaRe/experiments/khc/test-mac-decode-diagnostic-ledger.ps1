#requires -Version 7.0
# 失敗条件: 未知/異型field、source/controller/protocol/target/command差替え、期限超過、
# 閉鎖不明、孤立terminal、未解決start、再試行、旧Cargo引数混在。production stateは触らない。
[CmdletBinding()]
param([switch]$NativeVerifier,[switch]$HistoricalLedger,[switch]$RetryVerifier,[switch]$LeafFilesystemProbe,[switch]$QuarantineVerifier,[switch]$CandidateProtocolCompatibility,[switch]$CandidateVerifier,[switch]$CandidateE2eProtocolCompatibility,[switch]$CandidateE2eVerifier)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Module parser errors'}
foreach($name in @('Get-KhcCandidateRunnerDeadlineFailureBytes','Publish-KhcCandidateRunnerResult','Get-KhcCandidateRunnerDeadlineVetoStatus')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing candidate result deadline contract: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach($name in @('Get-KhcMacCandidateE2eKind','Get-KhcMacCandidateE2eProtocol','Assert-KhcMacCandidateE2eProtocol','Get-KhcMacCandidateE2eTrustSpec','Assert-KhcMacCandidateE2eClaimData','Assert-KhcRemoteReferenceClassData','Get-KhcRecycleV6Reservation','Assert-KhcRecycleV6ReservationData','Assert-KhcMacCandidateE2eCleanupSeal','Assert-KhcMacCandidateE2eSummary')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing registered candidate E2E contract: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach($name in @('Get-KhcMacCdfCandidateProtocol','Assert-KhcMacCdfCandidateProtocol','Get-KhcMacCdfCandidateTrustSpec','Assert-KhcMacCdfCandidateState','Assert-KhcMacCdfCandidateSummary')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing candidate contract: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach($name in @('Get-KhcMacDecodeVerifierBundleSpec','Assert-KhcMacDecodeVerifierBundleInventory','Get-KhcMacDecodeVerifierBundle','Assert-KhcMacDecodeRetryAmendment','Assert-KhcMacDecodeRetryState','Get-KhcMacDecodeRetryTrustSpec','Assert-KhcMacDecodeRetryOldEvidence','Assert-KhcMacDecodeRetrySummary','Start-KhcMacDecodeRetry','Complete-KhcVerifierReadLease')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing immutable verifier contract: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach($name in @('Get-KhcMacDecodeDiagnosticCommand','Assert-KhcMacDecodeDiagnosticProtocol','Assert-KhcMacDecodeDiagnosticStart','Assert-KhcMacDecodeDiagnosticTerminal','Assert-KhcMacDecodeDiagnosticState','Assert-KhcMacDecodeDiagnosticFields','Assert-KhcMacDecodeDiagnosticUtc','ConvertFrom-KhcBoundedJsonSnapshot','Test-KhcMacNativeE2eJsonEqual','Assert-KhcMacDecodeDiagnosticSummary')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing pure contract: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
$script:passed=0
function Accept($name,[scriptblock]$body){& $body;$script:passed++}
function Reject($name,[scriptblock]$body){$failed=$false;try{& $body}catch{$failed=$true};if(-not $failed){throw "Accepted invalid $name"};$script:passed++}
# 先行失敗条件: 元例外消失、330秒未満でspawn/gate、非finite時計、wire/raw SHAの衝突、
# scan外cache残存、検証失敗のcache採用、lease未保持、走査中のraw/依存差替え。
foreach($name in @('Initialize-KhcVerifierDirectoryHandle','Enter-KhcChargeScanLeafLease','Merge-KhcCandidateRunnerDeadlineFailure','Assert-KhcCandidateSpawnBudget','Get-KhcChargeScanKey','Copy-KhcChargeScanSummary','Get-KhcChargeScanContext')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing scan/deadline contract: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
Accept 'initial failure preserved when deadline follows' {
    $clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=361.0}}
    $original=[IO.IOException]::new('first admission failure')
    $failure=Merge-KhcCandidateRunnerDeadlineFailure $original $clock
    if($failure -isnot [AggregateException] -or $failure.InnerExceptions[0] -ne $original -or $failure.ToString() -notmatch '360 seconds'){throw 'Original failure lost'}
}
Accept 'within deadline original error identity unchanged' {
    $original=[IO.IOException]::new('original');$clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=359.0}}
    if((Merge-KhcCandidateRunnerDeadlineFailure $original $clock) -ne $original){throw 'Within-deadline failure changed'}
}
foreach($elapsed in @(0.0,29.999,30.0)){Accept "spawn remaining boundary $elapsed" {Assert-KhcCandidateSpawnBudget ([pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=$elapsed}})}}
foreach($elapsed in @(30.001,360.0,-1.0,[double]::NaN,[double]::PositiveInfinity)){Reject "spawn insufficient/invalid clock $elapsed" {Assert-KhcCandidateSpawnBudget ([pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=$elapsed}})}}
Reject 'clock moves between preparation and spawn' {$c=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=29.0}};Assert-KhcCandidateSpawnBudget $c;$c.Elapsed.TotalSeconds=31.0;Assert-KhcCandidateSpawnBudget $c}
# 実runnerのfinally catchを抽出して通す。子/SSHや実run登録は起動しない。
$runnerTokens=$null;$runnerErrors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-storage-experiment.ps1'),[ref]$runnerTokens,[ref]$runnerErrors)
$finalizationCatch=$runnerAst.FindAll({param($n)$n -is [Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text -match '\$context.Lock.Dispose\(\)' -and $n.Body.Extent.Text -match '\$failure'},$true) | Sort-Object {$_.Extent.Text.Length} | Select-Object -First 1
if($null -eq $finalizationCatch -or $runnerErrors.Count){throw 'Runner finalization catch missing'}
$finalizationBody=[scriptblock]::Create($finalizationCatch.Body.Extent.Text.Substring(1,$finalizationCatch.Body.Extent.Text.Length-2))
foreach($candidate in @($true,$false)){
    Accept "spawn admission failure then missing raw receipt, candidate=$candidate" {
        $macCandidateAdmission=$candidate;$failure=$null
        try{Assert-KhcCandidateSpawnBudget ([pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=31.0}})}catch{$failure=$_}
        $initial=$failure.Exception
        $context=[pscustomobject]@{Lock=([pscustomobject]@{Disposed=$false})}
        $context.Lock | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $finalError=[IO.FileNotFoundException]::new('endpoint-receipt.json absent; Mac not started')
        try{throw $finalError}catch{. $finalizationBody}
        if(-not $context.Lock.Disposed){throw 'Finalization lock not disposed'}
        if($candidate){
            if($failure -isnot [AggregateException] -or $failure.InnerExceptions.Count -ne 2 -or $failure.InnerExceptions[0] -ne $initial -or $failure.InnerExceptions[1] -ne $finalError){throw 'Initial admission error overwritten by missing receipt'}
            $clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=361.0}}
            $withDeadline=Merge-KhcCandidateRunnerDeadlineFailure $failure $clock
            if($withDeadline.Flatten().InnerExceptions.Count -ne 3){throw 'Final deadline lost preceding failures'}
        }elseif($failure.Exception -ne $finalError){throw 'Generic finalization behavior changed'}
    }
}
Accept 'candidate finalization-only error retains original ErrorRecord' {
    $macCandidateAdmission=$true;$failure=$null
    $context=[pscustomobject]@{Lock=([pscustomobject]@{})};$context.Lock | Add-Member ScriptMethod Dispose {}
    $finalError=[IO.IOException]::new('finalization-only failure')
    try{throw $finalError}catch{. $finalizationBody}
    if($failure -isnot [Management.Automation.ErrorRecord] -or $failure.Exception -ne $finalError){throw 'Finalization-only error changed'}
}
Accept 'wire and archive bytes are independently keyed' {
    $key=Get-KhcChargeScanKey 'proof' @('a','bc') ('1'*64)
    foreach($different in @((Get-KhcChargeScanKey 'proof' @('ab','c') ('1'*64)),(Get-KhcChargeScanKey 'proof' @('a','bc') ('2'*64)),(Get-KhcChargeScanKey 'other' @('a','bc') ('1'*64)))){if($key -ceq $different){throw 'Cache key collision'}}
}
Accept 'cached summary cannot be mutated by caller' {$s=@{verified=$true;nested=@{value=1}};$copy=Copy-KhcChargeScanSummary $s;$copy.nested.value=2;if($s.nested.value -ne 1){throw 'Cache mutation'}}
Accept 'no scan context outside scan' {if($null -ne (Get-KhcChargeScanContext)){throw 'Cache escaped scan'}}
Accept 'caller variable cannot enable a cache outside a charge scan' {$khcChargeScanMemo=@{Results=@{forged=$true};Leases=@()};if($null -ne (Get-KhcChargeScanContext)){throw 'Caller injected cache'}}
Accept 'nested scans own distinct context and restore outer context' {
    & {
        function Get-KhcRecycleV6Charges {
            param([switch]$Inner)
            $khcChargeScanMemo=@{Results=@{};Leases=@();Name=if($Inner){'inner'}else{'outer'}}
            if($Inner){if((Get-KhcChargeScanContext).Name -cne 'inner'){throw 'Nested scan reused outer cache'};return}
            Get-KhcRecycleV6Charges -Inner
            if((Get-KhcChargeScanContext).Name -cne 'outer'){throw 'Outer scan context not restored'}
        }
        Get-KhcRecycleV6Charges
    }
}
Accept 'pure summaries are stored only after successful complete validation' {
    foreach($pair in @(@('Invoke-KhcMacDecodeDiagnosticVerifier','Assert-KhcMacDecodeDiagnosticSummary'),@('Invoke-KhcMacDecodeRetryVerifier','Assert-KhcMacDecodeRetrySummary'),@('Invoke-KhcMacCdfCandidateVerifier','Assert-KhcMacCdfCandidateSummary'),@('Invoke-KhcMacContinuousProofVerifier','Assert-KhcMacContinuousProofSummary'))){
        $definition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $pair[0]},$false).Extent.Text
        if($definition.IndexOf($pair[1]) -ge $definition.IndexOf('$scan.Results[$scanKey]=') -or $definition -notmatch 'finally'){throw 'Unvalidated or unowned cached result'}
    }
}
Accept 'only pure verification is memoized, each entry remains checked' {
    $chargeAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-KhcRecycleV6Charges'},$false)
    foreach($required in @('Get-KhcMacReferenceRegistration','Get-KhcRecycleV6RunAnchor','Get-KhcMacCandidateE2eRegistration','Assert-KhcRecycleV6PrivatePath','Get-KhcRecycleV6Hash')){if($chargeAst.Extent.Text -notmatch [regex]::Escape($required)){throw "Entry check disappeared: $required"}}
    if($chargeAst.Extent.Text -notmatch 'finally' -or $chargeAst.Extent.Text -notmatch 'Results.Clear\(\)'){throw 'Scan cache not cleared'}
}
# 先行失敗条件: 登録operationを跨ぐmemo共有、metadata/容量の省略、wire違いの誤hit、
# 検証失敗の保存、例外時lease残留。実登録や本番private stateは使用しない。
Accept 'candidate registration alone owns operation verification memo' {
    $newRunAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-KhcStorageRun'},$false)
    if($newRunAst.Extent.Text -notmatch '\$khcCandidateRegistrationMemo' -or $newRunAst.Extent.Text -notmatch 'finally'){throw 'Candidate registration operation ownership missing'}
    $contextAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-KhcCandidateRegistrationContext'},$false)
    if($null -eq $contextAst){throw 'Candidate operation context missing'}
    $chargeAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-KhcRecycleV6Charges'},$false)
    if($chargeAst.Extent.Text -notmatch 'Get-KhcCandidateRegistrationContext' -or $chargeAst.Extent.Text -notmatch '\$ownsMemo'){throw 'Charge scan does not share operation pure memo'}
}
Accept 'candidate E2E cache binds wire caller and held dependencies' {
    $verifier=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-KhcMacCandidateE2eVerifier'},$false).Extent.Text
    foreach($text in @('Get-KhcChargeScanContext','Get-KhcChargeScanKey','wireSha','RunId','RecordSha256','scan.Results','readLease')){if($verifier -notmatch [regex]::Escape($text)){throw "Missing E2E memo binding $text"}}
    if($verifier.IndexOf('Assert-KhcMacCandidateE2eSummary $summary') -ge $verifier.IndexOf('$scan.Results[$scanKey]=')){throw 'Unvalidated E2E memo result'}
}
Accept 'operation and scan envelopes release leases and never cache mutable accounting' {
    $newRunAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-KhcStorageRun'},$false)
    $chargeAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-KhcRecycleV6Charges'},$false)
    $probeDefinitions=@()
    foreach($definition in @($newRunAst,$chargeAst)){
        $outerTry=@($definition.Body.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0]
        if($null -eq $outerTry -or $null -eq $outerTry.Finally){throw 'Ownership envelope missing'}
        $first=$definition.Body.EndBlock.Statements[0].Extent.StartOffset
        $prelude=$definition.Extent.StartScriptPosition.GetFullScript().Substring($first,$outerTry.Extent.StartOffset-$first)
        $parameters=if($definition.Name -ceq 'New-KhcStorageRun'){'param([switch]$RemoteCandidateE2e,[scriptblock]$Action)'}else{'param([scriptblock]$Action)'}
        # 実体の所有・finallyを使い、登録/全treeのI/O本体だけをメモリprobeへ置換する。
        $catches=(@($outerTry.CatchClauses | ForEach-Object {$_.Extent.Text}) -join ' ')
        $probeDefinitions+=('function '+$definition.Name+' {'+$parameters+"`n"+$prelude+'try { & $Action } '+$catches+' finally '+$outerTry.Finally.Extent.Text+'}')
    }
    foreach($name in @('Get-KhcCandidateRegistrationContext','Get-KhcChargeScanContext','Get-KhcChargeScanKey','Copy-KhcChargeScanSummary')){
        $probeDefinitions+= $ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false).Extent.Text
    }
    $probeBody=@'
$script:probeVerifications=0;$script:probeScans=0;$script:probeDisposals=0;$script:probeContexts=@();$script:probeWire='wire-a'
function Test-PureProbe {
    $memo=Get-KhcChargeScanContext
    $key=Get-KhcChargeScanKey 'test-pure' @($script:probeWire) 'held-pins'
    if($memo.Results.ContainsKey($key)){return (Copy-KhcChargeScanSummary $memo.Results[$key])}
    $script:probeVerifications++
    if($script:probeWire -ceq 'invalid'){throw 'raw verification failed'}
    $lease=[pscustomobject]@{};$lease | Add-Member ScriptMethod Dispose {$script:probeDisposals++}
    $memo.Leases.Add($lease);$memo.Results[$key]=@{verified=$true;wire=$script:probeWire}
    return (Copy-KhcChargeScanSummary $memo.Results[$key])
}
function Test-AccountingProbe {
    Get-KhcRecycleV6Charges {
        $script:probeScans++
        $script:probeContexts+=,(Get-KhcChargeScanContext)
        Test-PureProbe
    }
}
New-KhcStorageRun -RemoteCandidateE2e -Action {
    $one=Test-AccountingProbe;$one.verified=$false
    $two=Test-AccountingProbe
    if(-not $two.verified -or $script:probeDisposals -ne 0){throw 'Result mutation or premature lease release'}
}
if($script:probeVerifications -ne 1 -or $script:probeScans -ne 2 -or $script:probeDisposals -ne 1){throw 'Operation reuse/accounting/release failed'}
if($script:probeContexts[0].Results.Count -ne 0){throw 'Operation result survived exit'}
New-KhcStorageRun -Action {$null=Test-AccountingProbe;$null=Test-AccountingProbe}
if($script:probeVerifications -ne 3 -or $script:probeDisposals -ne 3){throw 'Legacy operation changed'}
$failed=$false
try{New-KhcStorageRun -RemoteCandidateE2e -Action {
    $null=Test-AccountingProbe;$script:probeWire='wire-b';$null=Test-AccountingProbe
    $script:probeWire='invalid'
    foreach($i in 1..2){try{$null=Test-AccountingProbe}catch{}}
    throw 'injected registration failure'
}}catch{$failed=$true}
if(-not $failed -or $script:probeVerifications -ne 7 -or $script:probeDisposals -ne 5){throw 'Wire separation, failure caching, or exceptional lease release failed'}
if(@($script:probeContexts | Where-Object {$_.Results.Count -ne 0}).Count){throw 'Failed operation results retained'}
$script:probeWire='wire-a'
New-KhcStorageRun -RemoteCandidateE2e -Action {
    $null=Test-AccountingProbe
    New-KhcStorageRun -Action {$null=Test-AccountingProbe}
    $null=Test-AccountingProbe
}
if($script:probeVerifications -ne 9 -or $script:probeDisposals -ne 7){throw 'Next or nested legacy operation shared context'}
if($null -ne (Get-KhcChargeScanContext) -or $null -ne (Get-KhcCandidateRegistrationContext)){throw 'Context escaped operation'}
$script:disposalFailureContext=$null;$script:afterDisposalFailure=$false;$failure=$null
try{New-KhcStorageRun -RemoteCandidateE2e -Action {
    $memo=Get-KhcCandidateRegistrationContext;$script:disposalFailureContext=$memo
    $memo.Results['proof']=@{verified=$true}
    $bad=[pscustomobject]@{};$bad | Add-Member ScriptMethod Dispose {throw 'injected lease disposal failure'}
    $good=[pscustomobject]@{};$good | Add-Member ScriptMethod Dispose {$script:afterDisposalFailure=$true}
    $memo.Leases.Add($bad);$memo.Leases.Add($good)
    throw 'original operation failure'
}}catch{$failure=$_.Exception}
if(-not $script:afterDisposalFailure -or $script:disposalFailureContext.Results.Count -ne 0 -or $script:disposalFailureContext.Leases.Count -ne 0){throw 'Disposal failure leaked remaining leases or memo'}
if($null -eq $failure -or $failure.ToString() -notmatch 'original operation failure' -or $failure.ToString() -notmatch 'injected lease disposal failure'){throw 'Cleanup failure lost original operation error'}
'@
    & ([scriptblock]::Create(($probeDefinitions -join "`n")+"`n"+$probeBody))
}
# 先行失敗条件: 既知の残時間不足でもclaim/reserve作成に進むこと。
# 実candidate登録branchを抽出し、外部module検索とNewRunだけをメモリ内へ差し替える。
$candidateRegistration=$runnerAst.Find({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'New-KhcStorageRun' -and $n.Extent.Text -match '-RemoteCandidateE2e\b'},$true)
if($null -eq $candidateRegistration){throw 'Candidate registration call missing'}
$candidateRegistrationBlock=$candidateRegistration.Parent
while($candidateRegistrationBlock -isnot [Management.Automation.Language.StatementBlockAst]){$candidateRegistrationBlock=$candidateRegistrationBlock.Parent}
$candidateRegistrationOwner=$candidateRegistrationBlock.Parent
Accept 'registration budget guard belongs only to candidate branch' {
    if($candidateRegistrationOwner -isnot [Management.Automation.Language.IfStatementAst]){throw 'Registration condition missing'}
    $clause=@($candidateRegistrationOwner.Clauses | Where-Object {$_.Item2 -eq $candidateRegistrationBlock})
    if($clause.Count -ne 1 -or $clause[0].Item1.Extent.Text -cne '$macCandidateAdmission'){throw 'Candidate guard affects another branch'}
}
$candidateRegistrationBody=[scriptblock]::Create($candidateRegistrationBlock.Extent.Text.Substring(1,$candidateRegistrationBlock.Extent.Text.Length-2))
$budgetFunction=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-KhcCandidateSpawnBudget'},$false)
$script:registrationBudgetModule=New-Module -ScriptBlock ([scriptblock]::Create($budgetFunction.Extent.Text))
foreach($elapsed in @(0.0,29.999,30.0,30.001,360.0,-1.0,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity)){
    Accept "registration before claim budget boundary $elapsed" {
        $script:registrationCalls=0
        function Get-Module {param($Name) if($Name -cne 'storage-lifecycle'){throw 'Unexpected module lookup'};$script:registrationBudgetModule}
        function New-KhcStorageRun {$script:registrationCalls++;[pscustomobject]@{Synthetic=$true}}
        $candidateEnvelopeTimer=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=$elapsed}}
        $work='not-a-real-registration';$ScriptParameters=@{ProtocolSha256=('a'*64)};$nativeInvocationSha=('b'*64)
        $failed=$false
        try{. $candidateRegistrationBody}catch{$failed=$true}
        $allowed=-not [double]::IsNaN($elapsed) -and -not [double]::IsInfinity($elapsed) -and $elapsed -ge 0 -and $elapsed -le 30
        if($allowed){if($failed -or $script:registrationCalls -ne 1){throw 'Valid registration boundary rejected'}}
        elseif(-not $failed -or $script:registrationCalls -ne 0){throw 'Invalid clock reached New-KhcStorageRun'}
    }
}
Accept 'registration spawn and gate each check parent budget' {
    $runnerText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'run-storage-experiment.ps1'))
    if(([regex]::Matches($runnerText,'Assert-KhcCandidateSpawnBudget \$clock')).Count -ne 3){throw 'Missing registration/check/use recheck'}
}
function Copy-Data($v){ConvertFrom-Json -AsHashtable (ConvertTo-Json -InputObject $v -Depth 30)}
$candidateRunner=@{schema=1;run_id=('a'*32);status='succeeded';runner_sha256=('b'*64);runner_sha256_at_finish=('b'*64);started_utc='2026-10-27T00:00:00.0000000Z';finished_utc='2026-10-27T00:00:01.0000000Z';child_started=$true;child_pid=1234;child_exit_code=0;stdout_eof=$true;stderr_eof=$true;job_active_after_exit=0;cleanup_request_created=$true;failure_message=$null}
foreach($case in @(@{Name='normal';Before=359.0;After=359.5;Expired=$false},@{Name='exact boundary';Before=360.0;After=360.0;Expired=$false},@{Name='save crosses boundary';Before=359.0;After=361.0;Expired=$true},@{Name='already expired before construction';Before=361.0;After=362.0;Expired=$true})){
    $script:deadlineClock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=$case.Before}}
    $script:deadlineStore=[pscustomobject]@{Current=$null;Initial=$null;Veto=$false;Updates=0}
    $script:deadlineAfter=$case.After
    $publish={Publish-KhcCandidateRunnerResult $candidateRunner $script:deadlineClock {
        param($bytes)
        $script:deadlineStore.Initial=$bytes;$script:deadlineStore.Current=$bytes
        # Flush(true)が戻る間に時間が進む境界を再現する。
        $script:deadlineClock.Elapsed.TotalSeconds=$script:deadlineAfter
    } {
        param($original,$failed,$elapsed)
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:deadlineStore.Current)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($original))){throw 'Wrong attempt snapshot'}
        $script:deadlineStore.Veto=$true;$script:deadlineStore.Current=$failed;$script:deadlineStore.Updates++
    }}
    if($case.Expired){Reject "candidate result $($case.Name) cannot return success" $publish}else{Accept "candidate result $($case.Name) succeeds" $publish}
    $persisted=ConvertFrom-Json -AsHashtable -InputObject ([Text.Encoding]::UTF8.GetString($script:deadlineStore.Current))
    Accept "candidate result $($case.Name) durable outcome and pending cleanup retained" {
        if($persisted.status -cne $(if($case.Expired){'failed'}else{'succeeded'}) -or -not $persisted.cleanup_request_created -or $persisted.child_exit_code -ne 0 -or $script:deadlineStore.Veto -ne $case.Expired){throw 'Candidate deadline outcome or closed-child/pending-cleanup evidence changed'}
    }
}
$runnerBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject $candidateRunner))
Reject 'candidate deadline downgrade cannot modify another attempt' {$null=Get-KhcCandidateRunnerDeadlineFailureBytes $runnerBytes ('d'*32) 361}
Reject 'candidate deadline downgrade cannot fabricate deadline failure before timeout' {$null=Get-KhcCandidateRunnerDeadlineFailureBytes $runnerBytes ('a'*32) 360}
$script:deadlineClock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=359.0}};$script:deadlineVetoWritten=$false
Reject 'candidate failed-update I/O still cannot return success' {
    Publish-KhcCandidateRunnerResult $candidateRunner $script:deadlineClock {param($bytes) $script:deadlineClock.Elapsed.TotalSeconds=361.0} {param($original,$failed,$elapsed) $script:deadlineVetoWritten=$true;throw 'synthetic failed result update I/O'}
}
Accept 'candidate failed-update I/O retains negative veto for reader' {if(-not $script:deadlineVetoWritten){throw 'Deadline veto not preserved'}}
foreach($stage in @('Flush','Dispose')){
    $script:deadlineClock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=359.0}}
    $script:initialIoStore=[pscustomobject]@{Current=$null;Veto=$false};$script:initialIoError=$null
    try{
        Publish-KhcCandidateRunnerResult $candidateRunner $script:deadlineClock {
            param($bytes) $script:initialIoStore.Current=$bytes;$script:deadlineClock.Elapsed.TotalSeconds=361.0;throw [IO.IOException]::new("synthetic initial $stage after full write")
        } {
            param($original,$failed,$elapsed) $script:initialIoStore.Veto=$true;$script:initialIoStore.Current=$failed
        }
    }catch{$script:initialIoError=$_.Exception}
    Accept "candidate initial $stage failure after full write still persists negative deadline outcome" {
        if($null -eq $script:initialIoError -or -not $script:initialIoStore.Veto -or -not $script:initialIoError.ToString().Contains("synthetic initial $stage") -or (ConvertFrom-Json -AsHashtable -InputObject ([Text.Encoding]::UTF8.GetString($script:initialIoStore.Current))).status -cne 'failed'){throw 'Initial I/O error bypassed post-save deadline veto or lost its original cause'}
    }
}
$script:deadlineClock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=359.0}};$script:deadlineVetoWritten=$false;$initialWithinError=$null
try{Publish-KhcCandidateRunnerResult $candidateRunner $script:deadlineClock {param($bytes) $script:deadlineClock.Elapsed.TotalSeconds=359.5;throw [IO.IOException]::new('synthetic within-deadline I/O')} {param($original,$failed,$elapsed) $script:deadlineVetoWritten=$true}}catch{$initialWithinError=$_.Exception}
Accept 'candidate within-deadline I/O failure never returns success or fabricates timeout' {if($null -eq $initialWithinError -or -not $initialWithinError.ToString().Contains('synthetic within-deadline I/O') -or $script:deadlineVetoWritten){throw 'Within-deadline I/O failure was lost or changed into a timeout'}}
$script:deadlineClock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=359.0}};$script:deadlineVetoWritten=$false;$combinedIoError=$null
try{Publish-KhcCandidateRunnerResult $candidateRunner $script:deadlineClock {param($bytes) $script:deadlineClock.Elapsed.TotalSeconds=361.0;throw [IO.IOException]::new('synthetic original flush I/O')} {param($original,$failed,$elapsed) $script:deadlineVetoWritten=$true;throw [IO.IOException]::new('synthetic veto persistence I/O')}}catch{$combinedIoError=$_.Exception}
Accept 'candidate initial I/O and impossible veto both remain failures with both causes' {if($null -eq $combinedIoError -or -not $script:deadlineVetoWritten -or -not $combinedIoError.ToString().Contains('synthetic original flush I/O') -or -not $combinedIoError.ToString().Contains('synthetic veto persistence I/O')){throw 'Combined I/O errors lost the original cause or skipped the veto attempt'}}
$veto=@{schema=1;protocol='khc-candidate-runner-deadline-failure-v1';run_id=('a'*32);record_sha256=('b'*64);protocol_sha256=('c'*64);original_result_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($runnerBytes)).ToLowerInvariant();elapsed_seconds=361.0;recorded_utc='2026-10-27T00:00:00.0000000Z'}
Accept 'candidate negative veto overrides original succeeded result' {if((Get-KhcCandidateRunnerDeadlineVetoStatus $veto ('a'*32) ('b'*64) ('c'*64)) -cne 'failed'){throw 'Deadline veto did not fail the outcome'}}
Reject 'candidate negative veto cannot bind another attempt' {$null=Get-KhcCandidateRunnerDeadlineVetoStatus $veto ('d'*32) ('b'*64) ('c'*64)}
Reject 'candidate negative veto invalid data cannot fall back to success' {$v=Copy-Data $veto;$v.elapsed_seconds=359;$null=Get-KhcCandidateRunnerDeadlineVetoStatus $v ('a'*32) ('b'*64) ('c'*64)}
$setter=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Set-KhcCandidateRunnerDeadlineFailure'},$false)
$native=$setter.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('namespace Khc.Storage { public static class CandidateResultHandle')},$true)
Accept 'candidate result no-follow RW handle implementation compiles without file operations' {if($null -eq $native){throw 'Missing candidate result native handle'};if(-not ('Khc.Storage.CandidateResultHandle' -as [type])){Add-Type -TypeDefinition $native.Value};if($null -eq ('Khc.Storage.CandidateResultHandle' -as [type]).GetMethod('Open')){throw 'Missing candidate result open method'}}
$e2e=Get-KhcMacCandidateE2eProtocol ('a'*64)
Accept 'candidate E2E exact protocol' {Assert-KhcMacCandidateE2eProtocol $e2e}
foreach($key in @($e2e.Keys)){Reject "candidate E2E typed field $key" {$v=Copy-Data $e2e;$v[$key]=if($key -ceq 'superiority_decision_allowed'){1}else{$true};Assert-KhcMacCandidateE2eProtocol $v}}
Reject 'candidate E2E unknown protocol field' {$v=Copy-Data $e2e;$v.extra=1;Assert-KhcMacCandidateE2eProtocol $v}
Reject 'candidate E2E unfrozen pins refuse registration' {Get-KhcMacCandidateE2eTrustSpec ('a'*64) ('b'*64)}
$e2eSha='c'*64
$e2eSummary=@{schema=1;protocol=$e2e.protocol;protocol_sha256=$e2eSha;endpoint_sha256=$e2e.endpoint_sha256;source_sha256=$e2e.source_sha256;purpose=$e2e.purpose;verified=$true}
Accept 'candidate E2E protocol verifier summary' {Assert-KhcMacCandidateE2eSummary $e2eSummary $e2e $e2eSha}
$report=@{registration_sha256=('d'*64);windows_run_id=('a'*32);windows_registration_sha256=('b'*64);protocol_sha256=$e2eSha}
$reportBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject $report));$reportSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reportBytes)).ToLowerInvariant()
# 純粋wire型/identity境界のDTO。実FS closure/API file検証は固定native verifierが担当。
$e2eReceipt=@{schema=1;protocol=$e2e.protocol;purpose=$e2e.purpose;windows_run_id=('a'*32);windows_registration_sha256=('b'*64);protocol_sha256=$e2eSha;endpoint_sha256=$e2e.endpoint_sha256;source_sha256=$e2e.source_sha256;example_sha256=$e2e.example_sha256;candidate_cli_sha256=$e2e.candidate_cli_sha256;candidate_build_receipt_sha256=$e2e.candidate_build_receipt_sha256;candidate_build_closure_sha256=$e2e.candidate_build_closure_sha256;remote_registration_sha256=('d'*64);report_sha256=$reportSha;report_base64=[Convert]::ToBase64String($reportBytes);closure_proof=@{synthetic='wire-boundary-only'};closure_sha256=('e'*64);children_absent=$true;postchecks_ok=$true;runtime_seconds=20.0;status='done';exit=0;error=$null}
$e2eReceiptBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 20 -InputObject $e2eReceipt))
$e2eFullSummary=Copy-Data $e2eSummary
foreach($key in @('windows_run_id','windows_registration_sha256','report_sha256','closure_sha256','status','exit')){$e2eFullSummary[$key]=$e2eReceipt[$key]}
$e2eFullSummary.receipt_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($e2eReceiptBytes)).ToLowerInvariant();$e2eFullSummary.cleanup_allowed=$true
Accept 'candidate E2E raw report/receipt/registration binding' {Assert-KhcMacCandidateE2eSummary $e2eFullSummary $e2e $e2eSha $e2eReceiptBytes ('a'*32) ('b'*64)}
foreach($key in @($e2eFullSummary.Keys)){Reject "candidate E2E summary type $key" {$v=Copy-Data $e2eFullSummary;$v[$key]=if($key -cin @('verified','cleanup_allowed')){1}else{$true};Assert-KhcMacCandidateE2eSummary $v $e2e $e2eSha $e2eReceiptBytes ('a'*32) ('b'*64)}}
Reject 'candidate E2E unknown closure cannot seal' {$v=Copy-Data $e2eFullSummary;$v.cleanup_allowed=$false;Assert-KhcMacCandidateE2eSummary $v $e2e $e2eSha $e2eReceiptBytes ('a'*32) ('b'*64)}
Reject 'candidate E2E cross registration cannot seal' {Assert-KhcMacCandidateE2eSummary $e2eFullSummary $e2e $e2eSha $e2eReceiptBytes ('a'*32) ('f'*64)}
Reject 'candidate E2E raw report/receipt substitution cannot seal' {Assert-KhcMacCandidateE2eSummary $e2eFullSummary $e2e $e2eSha ([Text.Encoding]::UTF8.GetBytes('{}')) ('a'*32) ('b'*64)}
Accept 'candidate E2E separate terminal class' {if((Assert-KhcRemoteReferenceClassData $false $false $true) -cne 'candidate-e2e'){throw 'Wrong remote class'}}
foreach($state in @(@($true,$false,$true),@($false,$true,$true),@($true,$true,$true))){Reject 'candidate E2E cannot mix remote classes' {Assert-KhcRemoteReferenceClassData $state[0] $state[1] $state[2]}}
$claim=@{schema=1;protocol='khc-mac-cdf-candidate-e2e-claim-v1';run_id=('a'*32);record_sha256=('b'*64);protocol_sha256=('c'*64);registered_utc='2026-10-27T00:00:00.0000000Z'}
Accept 'candidate E2E one-purpose claim' {Assert-KhcMacCandidateE2eClaimData $claim ('a'*32) ('b'*64) ('c'*64)}
foreach($key in @($claim.Keys)){Reject "candidate E2E typed claim $key" {$v=Copy-Data $claim;$v[$key]=$true;Assert-KhcMacCandidateE2eClaimData $v ('a'*32) ('b'*64) ('c'*64)}}
Reject 'candidate E2E second GUID cannot reuse purpose' {Assert-KhcMacCandidateE2eClaimData $claim ('d'*32) ('b'*64) ('c'*64)}
$size=Get-KhcRecycleV6Reservation 8MB 96
$e2eReserve=@{schema=1;protocol='prunlet-recycle-v6';run_id=('a'*32);registration_sha256=('b'*64);max_bytes=8MB;max_entries=96;payload_bytes=$size.payload_bytes;metadata_bytes=$size.metadata_bytes;remote_candidate_e2e_required=$true;remote_candidate_e2e_protocol_sha256=('c'*64)}
Accept 'candidate E2E real reserve DTO keeps its own class' {Assert-KhcRecycleV6ReservationData $e2eReserve ('a'*32) ('b'*64)}
Reject 'candidate E2E false flag cannot downgrade class' {$v=Copy-Data $e2eReserve;$v.remote_candidate_e2e_required=$false;Assert-KhcRecycleV6ReservationData $v ('a'*32) ('b'*64)}
Reject 'candidate E2E cross class reserve rejected' {$v=Copy-Data $e2eReserve;$v.remote_native_e2e_required=$true;$v.remote_native_e2e_protocol_sha256='d'*64;Assert-KhcRecycleV6ReservationData $v ('a'*32) ('b'*64)}
$runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-storage-experiment.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Storage runner parse errors'}
$runnerBind=[scriptblock]::Create($runnerAst.ParamBlock.Extent.Text+"`nreturn `$PSCmdlet.ParameterSetName")
Accept 'candidate E2E strict storage entrance' {if((& $runnerBind -MacCdfCandidateE2e -ProtocolSha256 ('c'*64)) -cne 'MacCdfCandidateE2e'){throw 'Wrong storage parameter set'}}
foreach($pair in @(@{ScriptPath='D:\arbitrary.ps1';ScriptParameters=@{}},@{MaxRunMiB=9},@{MaxEntries=97},@{TimeoutSeconds=400},@{Target='arbitrary'})){
    Reject 'candidate E2E cannot override worker/input/budget/deadline' {& $runnerBind -MacCdfCandidateE2e -ProtocolSha256 ('c'*64) @pair}
}
$candidateKind=Get-KhcMacCandidateE2eKind
# 固定worker/protocolと実run-GUID形だけを許すtyped invocation。ファイルには保存しない。
$candidateInv=[pscustomobject]@{script=$candidateKind.Worker;parameters=@{WorkDirectory=('D:\Codex\UnLhaRe\goal-restore-20261019\run-'+('a'*32));ProtocolPath=$candidateKind.ProtocolPath;ProtocolSha256=('c'*64)}}
$converter=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ConvertFrom-KhcMacNativeInvocationSnapshot'},$false).Extent.Text
. ([scriptblock]::Create($converter))
$invRaw=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($candidateInv));$invSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($invRaw)).ToLowerInvariant()
Accept 'candidate E2E typed invocation fixed worker and exact parameters' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot $invRaw $invSha 'candidate-e2e'}
Reject 'candidate E2E invocation cannot use old class' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot $invRaw $invSha 'native-e2e'}
Reject 'candidate E2E invocation original bytes cannot swap' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot ([Text.Encoding]::UTF8.GetBytes('swapped')) $invSha 'candidate-e2e'}
foreach($change in @('worker','protocol','parameters')){
    Reject "candidate E2E invocation $change" {
        $v=[pscustomobject]@{script=$candidateInv.script;parameters=@{}+$candidateInv.parameters}
        switch($change){worker{$v.script='D:\arbitrary.ps1'};protocol{$v.parameters.ProtocolPath='D:\arbitrary.json'};parameters{$v.parameters.Input='D:\arbitrary.bin'}}
        $raw=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($v));$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        $null=ConvertFrom-KhcMacNativeInvocationSnapshot $raw $sha 'candidate-e2e'
    }
}
foreach($sealed in @($false,$true)){
    $script:syntheticCandidateSeal=$sealed
    $check={& {
        function Test-Path {param($LiteralPath) return $true}
        function Read-KhcRecycleV6PrivateJson {param($Path) return $e2eReserve}
        function Get-KhcMacCandidateE2eRegistration {param($State,$RunId,$Reserve,[switch]$RequireSeal) if(-not $RequireSeal -or -not $script:syntheticCandidateSeal){throw 'Candidate E2E remote closure unsealed'}}
        Assert-KhcMacCandidateE2eCleanupSeal ([pscustomobject]@{StateRoot='D:\memory';RunId=('a'*32)})
    }}
    if($sealed){Accept 'candidate E2E cleanup requires verified private seal' $check}else{Reject 'candidate E2E unknown closure blocks cleanup' $check}
}
function New-FakeVerifierProcess([bool]$Exited,[bool]$KillThrows,[bool]$WaitReturns){
    $value=[pscustomobject]@{HasExited=$Exited;KillThrows=$KillThrows;WaitReturns=$WaitReturns;Disposed=$false;KillCalls=0;WaitCalls=0}
    $value | Add-Member ScriptMethod Kill {param($tree) $this.KillCalls++;if($this.KillThrows){throw 'synthetic Kill failure'}}
    $value | Add-Member ScriptMethod WaitForExit {param($milliseconds) if($milliseconds -ne 5000){throw 'Unbounded wait'};$this.WaitCalls++;if($this.WaitReturns){$this.HasExited=$true};return $this.WaitReturns}
    $value | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    return $value
}
function New-FakeVerifierLease {
    $value=[pscustomobject]@{Disposed=$false}
    $value | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    return ,@($value)
}
$script:quarantined=@()
function Protect-KhcUnclosedVerifier {param($Process,$ReadLease,[string]$Reason) $script:quarantined+=,[pscustomobject]@{Process=$Process;Lease=$ReadLease;Reason=$Reason}}
foreach($kind in @('kill-exception','wait-false','already-exited','normal-exit','killed-and-exited','not-spawned')){
    $script:quarantined=@()
    $process=New-FakeVerifierProcess ($kind -cin @('already-exited','normal-exit')) ($kind -ceq 'kill-exception') ($kind -ceq 'killed-and-exited')
    $readLease=New-FakeVerifierLease
    if($kind -cin @('kill-exception','wait-false')){
        Reject "unconfirmed verifier $kind fails closed" {Complete-KhcVerifierReadLease $process $true $readLease}
        Accept "unconfirmed verifier $kind retains process and lease" {if($process.Disposed -or $readLease[0].Disposed -or $script:quarantined.Count -ne 1 -or -not [object]::ReferenceEquals($process,$script:quarantined[0].Process) -or -not [object]::ReferenceEquals($readLease,$script:quarantined[0].Lease)){throw 'Unconfirmed verifier lease was released or lost'}}
    }else{
        Accept "confirmed verifier $kind releases lease without quarantine" {Complete-KhcVerifierReadLease $process ($kind -cne 'not-spawned') $readLease;if(-not $process.Disposed -or -not $readLease[0].Disposed -or $script:quarantined.Count -ne 0){throw 'Confirmed verifier leaked resources or quarantine'}}
    }
}
$guard=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-KhcVerifierQuarantineClear'},$false).Extent.Text
Reject 'persistent unresolved marker blocks without launching verifier' {& {
    function Assert-KhcPlainPath {param($LiteralPath) return $LiteralPath}
    function Test-Path {param($LiteralPath) return $true}
    . ([scriptblock]::Create($guard))
    Assert-KhcVerifierQuarantineClear
}}
$oldController='da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc'
$bundleSpec=Get-KhcMacDecodeVerifierBundleSpec $oldController
$bundleEntries=@(foreach($name in $bundleSpec.Pins.Keys){@{Name=$name;Sha256=$bundleSpec.Pins[$name];IsDirectory=$false;IsReparsePoint=$false}})
Accept 'exact immutable bundle inventory' {Assert-KhcMacDecodeVerifierBundleInventory $oldController $bundleEntries}
Reject 'unknown controller has no fallback' {Get-KhcMacDecodeVerifierBundleSpec ('a'*64)}
Reject 'upper case SHA has no alias' {Get-KhcMacDecodeVerifierBundleSpec $oldController.ToUpperInvariant()}
Reject 'receipt path cannot select bundle' {Get-KhcMacDecodeVerifierBundleSpec $bundleSpec.Directory}
foreach($kind in @('hash','link','directory','missing','extra','duplicate')){
    Reject "immutable bundle $kind" {
        $v=@(Copy-Data $bundleEntries)
        switch($kind){hash{$v[0].Sha256='0'*64};link{$v[0].IsReparsePoint=$true};directory{$v[0].IsDirectory=$true};missing{$v=$v[1..3]};extra{$v+=@{Name='other.py';Sha256='0'*64;IsDirectory=$false;IsReparsePoint=$false}};duplicate{$v[0]=$v[1]}}
        Assert-KhcMacDecodeVerifierBundleInventory $oldController $v
    }
}
$root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
$cdf=Get-KhcMacCdfCandidateProtocol ('a'*64) ('b'*64)
Accept 'candidate fixed pure protocol' {Assert-KhcMacCdfCandidateProtocol $cdf}
foreach($key in @($cdf.Keys)){Reject "candidate protocol type $key" {$v=Copy-Data $cdf;$v[$key]=if($key -ceq 'superiority_decision_allowed'){1}else{$true};Assert-KhcMacCdfCandidateProtocol $v}}
Reject 'candidate unknown protocol field' {$v=Copy-Data $cdf;$v.extra=1;Assert-KhcMacCdfCandidateProtocol $v}
Reject 'candidate preserved history swap' {$v=Copy-Data $cdf;$v.preserved_sha256['journal/mac-decode-phase-retry.closure.json']='0'*64;Assert-KhcMacCdfCandidateProtocol $v}
Reject 'candidate build selection swap' {$v=Copy-Data $cdf;$v.cargo_command=@('cargo','build');Assert-KhcMacCdfCandidateProtocol $v}
Reject 'candidate unfrozen dependencies cannot register' {Get-KhcMacCdfCandidateTrustSpec ('a'*64) ('b'*64) ('c'*64)}
Accept 'candidate absent' {Assert-KhcMacCdfCandidateState $false $false}
Accept 'candidate closed' {Assert-KhcMacCdfCandidateState $true $true}
Reject 'candidate orphan terminal' {Assert-KhcMacCdfCandidateState $false $true}
Reject 'candidate partial/unclosed start' {Assert-KhcMacCdfCandidateState $true $false}
$cdfBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $cdf -Depth 20 -Compress));$cdfSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cdfBytes)).ToLowerInvariant()
$cdfStart=@{protocol_sha256=$cdfSha;protocol_base64=[Convert]::ToBase64String($cdfBytes)}
$cdfSummary=@{schema=1;protocol=$cdf.protocol;protocol_sha256=$cdfSha;source_sha256=$cdf.source_sha256;controller_sha256=$cdf.controller_sha256;purpose=$cdf.purpose;verified=$true}
Accept 'candidate protocol summary binding' {Assert-KhcMacCdfCandidateSummary $cdfSummary $cdfStart}
foreach($key in @($cdfSummary.Keys)){Reject "candidate summary typed $key" {$v=Copy-Data $cdfSummary;$v[$key]=if($key -ceq 'verified'){1}else{$true};Assert-KhcMacCdfCandidateSummary $v $cdfStart}}
Reject 'candidate summary raw protocol swap' {$v=Copy-Data $cdfStart;$v.protocol_base64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'));Assert-KhcMacCdfCandidateSummary $cdfSummary $v}
$a=@{schema=1;protocol='khc-mac-decode-phase-retry-v1';old_protocol_sha256='64f6aae8c18c83f5f966462c96e1d4ecc3bb34af0a2f114b9844c129539f0088';old_receipt_sha256='84c7e314b0a79c2ac9d55e34772c8f20339e29079dbd17868605c0e08f27f4ca';old_closure_sha256='d12c7079556b9f44e5e0e952847040f9a467a380a977badf9102669ecc7f91a6';old_controller_sha256=$oldController;source_sha256='1ffe78d045d85e8919fddc166a4a97c997b88ee70fba5ca8a0df20be447c7f55';root=$root;source_directory="$root/decode-phase-20261027/source";target="$root/cargo-target/decode-phase-20261027";additional_attempts=1;cargo_timeout_seconds=300;native_final_seconds=350;ssh_timeout_seconds=380;additional_target_max_bytes=536870912L;ordinary_max_bytes=1610612736L;cargo_max_bytes=1073741824L;total_max_bytes=2684354560L;controller_sha256=('e'*64);snapshot_sha256=('f'*64)}
Accept 'retry amendment pure schema' {Assert-KhcMacDecodeRetryAmendment $a}
foreach($key in @($a.Keys)){Reject "retry amendment typed $key" {$v=Copy-Data $a;$v[$key]=$true;Assert-KhcMacDecodeRetryAmendment $v}}
Reject 'retry amendment unknown field' {$v=Copy-Data $a;$v.extra=1;Assert-KhcMacDecodeRetryAmendment $v}
Reject 'retry adds another attempt' {$v=Copy-Data $a;$v.additional_attempts=2;Assert-KhcMacDecodeRetryAmendment $v}
Reject 'retry old controller alias' {$v=Copy-Data $a;$v.controller_sha256=$oldController;Assert-KhcMacDecodeRetryAmendment $v}
Reject 'unfrozen retry cannot execute' {Get-KhcMacDecodeRetryTrustSpec $a.controller_sha256 $a.snapshot_sha256}
foreach($state in @(@($false,$false,$true),@($false,$true,$false),@($false,$true,$true),@($true,$false,$false),@($true,$false,$true),@($true,$true,$false))){Reject 'retry orphan or pending' {Assert-KhcMacDecodeRetryState $state[0] $state[1] $state[2]}}
Accept 'retry absent' {Assert-KhcMacDecodeRetryState $false $false $false}
Accept 'retry terminal closed' {Assert-KhcMacDecodeRetryState $true $true $true}
$oldStart=@{protocol_sha256=$a.old_protocol_sha256;spec=@{controller_sha256=$oldController}}
$oldReceipt=@{status='failed';exit=1;closure_sha256=$a.old_closure_sha256;postchecks_ok=$true;wait_confirmed=$true;group_absent=$true}
Accept 'retry exact old prerequisites' {Assert-KhcMacDecodeRetryOldEvidence $oldStart $oldReceipt $a.old_receipt_sha256}
foreach($key in @($oldReceipt.Keys)){Reject "retry old prerequisite $key" {$v=Copy-Data $oldReceipt;$v[$key]=if($key -cin @('postchecks_ok','wait_confirmed','group_absent')){$false}else{$true};Assert-KhcMacDecodeRetryOldEvidence $oldStart $v $a.old_receipt_sha256}}
Reject 'retry old raw receipt changed' {Assert-KhcMacDecodeRetryOldEvidence $oldStart $oldReceipt ('0'*64)}
$p=@{schema=1;protocol='khc-mac-decode-phase-build-v1';purpose='decode-phase-diagnostic';host='m3mb14';root=$root;source_sha256=('a'*64);controller_sha256=('b'*64);base_source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f';old_cli_sha256='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629';source="$root/source-diagnostic-$('a'*64)";target="$root/cargo-target/decode-phase-20261027";toolchain='1.99.1-aarch64-apple-darwin';cargo_command=@(Get-KhcMacDecodeDiagnosticCommand);cargo_seconds=300;native_seconds=350;ssh_seconds=380;target_max_bytes=536870912L;cargo_max_bytes=1073741824L;ordinary_max_bytes=1610612736L;total_max_bytes=2684354560L}
$p.Remove('source');$p.Remove('old_cli_sha256');$p.Remove('cargo_seconds');$p.Remove('native_seconds');$p.Remove('ssh_seconds');$p.Remove('target_max_bytes')
$p.task='goal-restore-20261019';$p.source_directory="$root/decode-phase-20261027/source";$p.baseline_cli_sha256='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629';$p.archive_sha256='234de239da6302ac69ca564729f7658a10c42889a96b1f8796136ea3af9192ee';$p.reference_terminal_sha256='88bcfebefe228162fe12c4434d0a6cf493d7d0b8c8f01b6ed6a745c2774a370e';$p.supervisor_sha256='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30';$p.setup_sha256='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1';$p.build_verifier_sha256='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb';$p.source_manifest_sha256='e'*64;$p.generator_sha256='f'*64;$p.superiority_decision_allowed=$false;$p.cargo_timeout_seconds=300;$p.native_final_seconds=350;$p.ssh_timeout_seconds=380;$p.additional_target_max_bytes=536870912L
$pBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $p -Depth 20 -Compress))
$pSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pBytes)).ToLowerInvariant()
$s=@{schema=1;protocol='khc-mac-decode-diagnostic-start-v1';purpose='decode-phase-diagnostic';protocol_sha256=$pSha;protocol_base64=[Convert]::ToBase64String($pBytes);spec=$p;started_utc='2026-10-27T00:00:00.0000000Z'}
$t=@{schema=1;protocol=$p.protocol;purpose=$p.purpose;source_sha256=$p.source_sha256;controller_sha256=$p.controller_sha256;protocol_sha256=$s.protocol_sha256;root=$root;target=$p.target;cargo_command=@(Get-KhcMacDecodeDiagnosticCommand);status='done';exit=0;runtime_seconds=310.0;cargo_runtime_seconds=290.0;binary_sha256=('d'*64);wait_confirmed=$true;group_absent=$true;postchecks_ok=$true}
$t.binary_path="$($p.target)/aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic";$t.closure_proof=@{synthetic='pure-type-boundary-only'};$t.closure_sha256='e'*64;$t.error=$null
$amendmentBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $a -Depth 20 -Compress))
$amendmentSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($amendmentBytes)).ToLowerInvariant()
$registration=@{amendment_sha256=$amendmentSha;amendment_base64=[Convert]::ToBase64String($amendmentBytes)}
$retrySummary=@{schema=1;protocol=$a.protocol;verified=$true;amendment_sha256=$amendmentSha;old_receipt_sha256=$a.old_receipt_sha256;snapshot_sha256=$a.snapshot_sha256}
Accept 'retry pure amendment summary' {Assert-KhcMacDecodeRetrySummary $retrySummary $registration}
$rt=Copy-Data $t;$rt.protocol=$a.protocol;$rt.protocol_sha256=$amendmentSha;$rt.amendment_sha256=$amendmentSha;$rt.source_sha256=$a.source_sha256;$rt.controller_sha256=$a.controller_sha256;$rt.snapshot_sha256=$a.snapshot_sha256;$rt.old_receipt_sha256=$a.old_receipt_sha256
$rtBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $rt -Depth 20 -Compress));$rtBase64=[Convert]::ToBase64String($rtBytes)
$rs=Copy-Data $retrySummary;$rs.receipt_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rtBytes)).ToLowerInvariant();$rs.status=$rt.status;$rs.exit=$rt.exit;$rs.binary_sha256=$rt.binary_sha256;$rs.closure_sha256=$rt.closure_sha256;$rs.cleanup_allowed=$true
Accept 'retry raw receipt summary binding' {Assert-KhcMacDecodeRetrySummary $rs $registration $rtBase64 $p}
foreach($key in @($rs.Keys)){Reject "retry summary type $key" {$v=Copy-Data $rs;$v[$key]=if($key -cin @('verified','cleanup_allowed')){1}else{$true};Assert-KhcMacDecodeRetrySummary $v $registration $rtBase64 $p}}
Reject 'retry unknown closure summary' {$v=Copy-Data $rs;$v.cleanup_allowed=$false;Assert-KhcMacDecodeRetrySummary $v $registration $rtBase64 $p}
Reject 'retry raw receipt swap' {Assert-KhcMacDecodeRetrySummary $rs $registration ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))) $p}
Reject 'retry raw amendment swap' {$v=Copy-Data $registration;$v.amendment_base64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'));Assert-KhcMacDecodeRetrySummary $retrySummary $v}
Reject 'unfrozen retry start fails before production access' {Start-KhcMacDecodeRetry $amendmentBytes $amendmentSha}
Accept 'valid protocol' {Assert-KhcMacDecodeDiagnosticProtocol $p}
Accept 'valid start' {Assert-KhcMacDecodeDiagnosticStart $s}
Accept 'valid terminal' {Assert-KhcMacDecodeDiagnosticTerminal $s $t}
foreach($key in @($p.Keys)){Reject "protocol type $key" {$v=Copy-Data $p;$v[$key]=$true;Assert-KhcMacDecodeDiagnosticProtocol $v}}
foreach($key in @($s.Keys)){Reject "start type $key" {$v=Copy-Data $s;$v[$key]=$true;Assert-KhcMacDecodeDiagnosticStart $v}}
foreach($key in @($t.Keys | Where-Object {$_ -notin @('wait_confirmed','group_absent','postchecks_ok')})){Reject "terminal type $key" {$v=Copy-Data $t;$v[$key]=$true;Assert-KhcMacDecodeDiagnosticTerminal $s $v}}
foreach($key in @('wait_confirmed','group_absent','postchecks_ok')){Reject "boolean type $key" {$v=Copy-Data $t;$v[$key]=1;Assert-KhcMacDecodeDiagnosticTerminal $s $v};Reject "unknown closure $key" {$v=Copy-Data $t;$v[$key]=$false;Assert-KhcMacDecodeDiagnosticTerminal $s $v}}
foreach($key in @('source_sha256','controller_sha256','protocol_sha256','target','root')){Reject "cross identity $key" {$v=Copy-Data $t;$v[$key]='e'*64;Assert-KhcMacDecodeDiagnosticTerminal $s $v}}
foreach($key in @('runtime_seconds','cargo_runtime_seconds')){Reject "deadline $key" {$v=Copy-Data $t;$v[$key]=381;Assert-KhcMacDecodeDiagnosticTerminal $s $v};Reject "negative $key" {$v=Copy-Data $t;$v[$key]=-1;Assert-KhcMacDecodeDiagnosticTerminal $s $v}}
foreach($kind in @('p','s','t')){Reject "unknown $kind" {$v=Copy-Data (Get-Variable $kind -ValueOnly);$v.extra=1;switch($kind){p{Assert-KhcMacDecodeDiagnosticProtocol $v};s{Assert-KhcMacDecodeDiagnosticStart $v};t{Assert-KhcMacDecodeDiagnosticTerminal $s $v}}}}
Reject 'changed command' {$v=Copy-Data $t;$v.cargo_command+= '--help';Assert-KhcMacDecodeDiagnosticTerminal $s $v}
Reject 'NaN runtime' {$v=Copy-Data $t;$v.runtime_seconds=[double]::NaN;Assert-KhcMacDecodeDiagnosticTerminal $s $v}
Reject 'raw protocol swap' {$v=Copy-Data $s;$v.protocol_base64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'));Assert-KhcMacDecodeDiagnosticStart $v}
Reject 'raw protocol spec swap' {$v=Copy-Data $s;$v.spec.controller_sha256='f'*64;Assert-KhcMacDecodeDiagnosticStart $v}
Reject 'orphan terminal' {Assert-KhcMacDecodeDiagnosticState $false $true $null}
Reject 'pending start' {Assert-KhcMacDecodeDiagnosticState $true $false $null}
Accept 'no diagnostic' {Assert-KhcMacDecodeDiagnosticState $false $false $null}
Accept 'closed diagnostic' {Assert-KhcMacDecodeDiagnosticState $true $true $t}
Reject 'false closure pending' {$v=Copy-Data $t;$v.group_absent=$false;Assert-KhcMacDecodeDiagnosticState $true $true $v}
Accept 'closed failure evidence' {$v=Copy-Data $t;$v.status='failed';$v.exit=1;$v.binary_sha256=$null;Assert-KhcMacDecodeDiagnosticTerminal $s $v}
Accept 'closed failed postcheck evidence' {$v=Copy-Data $t;$v.status='failed';$v.exit=1;$v.postchecks_ok=$false;$v.binary_sha256=$null;Assert-KhcMacDecodeDiagnosticTerminal $s $v;Assert-KhcMacDecodeDiagnosticState $true $true $v}
Accept 'closed deadline failure retains actual elapsed' {$v=Copy-Data $t;$v.status='failed';$v.exit=1;$v.postchecks_ok=$false;$v.binary_sha256=$null;$v.runtime_seconds=400.0;$v.cargo_runtime_seconds=350.0;Assert-KhcMacDecodeDiagnosticTerminal $s $v;Assert-KhcMacDecodeDiagnosticState $true $true $v}
$receiptBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $t -Depth 20 -Compress))
$receiptBase64=[Convert]::ToBase64String($receiptBytes)
$summary=@{schema=1;protocol=$p.protocol;protocol_sha256=$s.protocol_sha256;source_sha256=$p.source_sha256;controller_sha256=$p.controller_sha256;purpose=$p.purpose;verified=$true;receipt_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($receiptBytes)).ToLowerInvariant();binary_sha256=$t.binary_sha256;closure_sha256=$t.closure_sha256;status=$t.status;exit=$t.exit;cleanup_allowed=$true}
Accept 'native verifier summary binding' {Assert-KhcMacDecodeDiagnosticSummary $summary $s $receiptBase64}
foreach($key in @($summary.Keys)){Reject "native summary type $key" {$v=Copy-Data $summary;$v[$key]=if($key -cin @('verified','cleanup_allowed')){1}else{$true};Assert-KhcMacDecodeDiagnosticSummary $v $s $receiptBase64}}
Reject 'native summary unknown' {$v=Copy-Data $summary;$v.extra=1;Assert-KhcMacDecodeDiagnosticSummary $v $s $receiptBase64}
Reject 'native summary closure unknown' {$v=Copy-Data $summary;$v.cleanup_allowed=$false;Assert-KhcMacDecodeDiagnosticSummary $v $s $receiptBase64}
Reject 'native summary raw swap' {Assert-KhcMacDecodeDiagnosticSummary $summary $s ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}')))}
Reject 'native summary source swap' {$v=Copy-Data $summary;$v.source_sha256='f'*64;Assert-KhcMacDecodeDiagnosticSummary $v $s $receiptBase64}
$gateway=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-serial-cargo.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Gateway parser errors'}
# parameter bindingのみ実行し、import/初期化/SSH/Cargoには進まない。
$bind=[scriptblock]::Create($gateway.ParamBlock.Extent.Text+"`nreturn `$PSCmdlet.ParameterSetName")
Accept 'diagnostic binding' {if((& $bind -MacDecodeDiagnostic -ProtocolSha256 ('c'*64)) -cne 'MacDecodeDiagnostic'){throw 'Wrong parameter set'}}
Accept 'retry binding' {if((& $bind -MacDecodeRetry -AmendmentSha256 ('c'*64)) -cne 'MacDecodeRetry'){throw 'Wrong retry parameter set'}}
Accept 'candidate binding' {if((& $bind -MacCdfCandidate -ProtocolSha256 ('c'*64)) -cne 'MacCdfCandidate'){throw 'Wrong candidate parameter set'}}
foreach($pair in @(@{CargoArguments=@('check')},@{TransientMiB=14},@{Toolchain='1.99.1'},@{MacDecodeDiagnostic=$true},@{MacDecodeRetry=$true;AmendmentSha256=('c'*64)},@{SourcePath='D:\arbitrary'},@{Command='check'},@{TargetDir='D:\arbitrary'})){
    Reject 'candidate rejects mixed or arbitrary execution options' {& $bind -MacCdfCandidate -ProtocolSha256 ('c'*64) @pair}
}
foreach($pair in @(@{CargoArguments=@('check')},@{TransientMiB=14},@{Toolchain='1.99.1'},@{MacDecodeDiagnostic=$true;ProtocolSha256=('c'*64)},@{SourcePath='D:\arbitrary'},@{Command='check'})){
    Reject 'retry rejects mixed or arbitrary execution options' {& $bind -MacDecodeRetry -AmendmentSha256 ('c'*64) @pair}
}
Accept 'old Cargo binding' {if((& $bind -CargoArguments @('check')) -cne 'WindowsCargo'){throw 'Wrong old parameter set'}}
foreach($pair in @(@{CargoArguments=@('check')},@{TransientMiB=14},@{Toolchain='1.99.1'})){
    Reject 'old Cargo option mixed into diagnostic' {& $bind -MacDecodeDiagnostic -ProtocolSha256 ('c'*64) @pair}
}
foreach($pair in @(@{SourcePath='D:\arbitrary'},@{TargetDir='D:\arbitrary'},@{Command='check'},@{TimeoutSeconds=900})){
    Reject 'arbitrary diagnostic execution override' {& $bind -MacDecodeDiagnostic -ProtocolSha256 ('c'*64) @pair}
}
foreach($name in @('Start-KhcMacDecodeDiagnostic','Assert-KhcNoPendingMacBuild')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    . ([scriptblock]::Create($f.Extent.Text))
}
# インメモリstubのみ。開始記録の差替えでもpurpose一回性を回避できない。
$script:TaskId='goal-restore-20261019'
function Get-KhcMacRemoteReservation {return @{fixed=$true}}
function Assert-KhcNoPendingStorageRuns {}
function Get-KhcMacBuildLedger {return @()}
function Get-KhcMacCdfCandidateLedger {return $script:fakeCandidate}
$script:fakeCandidate=[pscustomobject]@{Start=$null;Terminal=$null}
$candidateStartAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Start-KhcMacCdfCandidate'},$false).Extent.Text
Accept 'candidate start charges metadata only and is one-shot after failure' {& {
    . ([scriptblock]::Create($candidateStartAst))
    function Get-KhcMacCdfCandidateTrustSpec {return @{trusted='in-memory-only'}}
    function Assert-KhcNoPendingStorageRuns {}
    function Assert-KhcNoPendingMacBuild {}
    function Get-KhcMacCdfCandidateLedger {return $script:localCandidate}
    function Invoke-KhcMacCdfCandidateVerifier {return @{verified=$true}}
    function Assert-KhcStorageBudget {param($ReserveBytes,$CargoReserveBytes=0) if($ReserveBytes -ne 1MB -or $CargoReserveBytes -ne 0 -or $PSBoundParameters.ContainsKey('CargoReserveBytes')){throw 'Remote reservation double charged'}}
    function Assert-KhcRecycleV6CapacityData {}
    function Get-KhcLifecycleUsage {return 0}
    function Get-KhcRecycleV6Charges {return @{total_bytes=0}}
    function Get-KhcRecycleV6AnchorRoot {return 'D:\in-memory-candidate'}
    function Write-KhcNewJson {param($Path,$Value) $script:candidateWrites++}
    $script:candidateWrites=0;$script:localCandidate=[pscustomobject]@{Start=$null;Terminal=$null}
    Start-KhcMacCdfCandidate $cdfBytes $cdfSha
    $script:localCandidate=[pscustomobject]@{Start=@{started=$true};Terminal=@{status='failed'}}
    $rejected=$false;try{Start-KhcMacCdfCandidate $cdfBytes $cdfSha}catch{$rejected=$true}
    if(-not $rejected -or $script:candidateWrites -ne 1){throw 'Candidate one-shot failed'}
}}
function Assert-KhcVerifierQuarantineClear {}
$script:fakeRetry=[pscustomobject]@{Amendment=$null;Start=$null;Terminal=$null}
function Get-KhcMacDecodeRetryLedger {return $script:fakeRetry}
$script:fakeLedger=[pscustomobject]@{Start=$s;Terminal=$t}
function Get-KhcMacDecodeDiagnosticLedger {return $script:fakeLedger}
Reject 'one-shot prevents repeated source' {Start-KhcMacDecodeDiagnostic $p ('c'*64)}
Reject 'one-shot prevents another source' {$v=Copy-Data $p;$v.source_sha256='e'*64;Start-KhcMacDecodeDiagnostic $v ('c'*64)}
$script:fakeLedger=[pscustomobject]@{Start=$s;Terminal=$null}
Reject 'old Cargo shared pending guard' {Assert-KhcNoPendingMacBuild}
$script:fakeLedger=[pscustomobject]@{Start=$s;Terminal=$t}
Accept 'closed shared pending guard' {Assert-KhcNoPendingMacBuild}
$script:fakeCandidate=[pscustomobject]@{Start=@{partial=$true};Terminal=$null}
Reject 'candidate partial start blocks every old Cargo' {Assert-KhcNoPendingMacBuild}
$script:fakeCandidate=[pscustomobject]@{Start=$null;Terminal=$null}
$script:fakeRetry=[pscustomobject]@{Amendment=@{registered=$true};Start=$null;Terminal=$null}
Reject 'retry registration without start blocks old Cargo' {Assert-KhcNoPendingMacBuild}
$script:fakeRetry=[pscustomobject]@{Amendment=@{registered=$true};Start=@{started=$true};Terminal=$null}
Reject 'retry pending start blocks old Cargo' {Assert-KhcNoPendingMacBuild}
$script:fakeRetry=[pscustomobject]@{Amendment=$null;Start=$null;Terminal=$null}
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Save-KhcMacDecodeDiagnosticTerminal'},$false)
. ([scriptblock]::Create($f.Extent.Text))
$script:fakeLedger=[pscustomobject]@{Start=$s;Terminal=$null}
$script:written=$false
function Write-KhcNewJson {param($Path,$Value) $script:written=$true}
function Invoke-KhcMacDecodeDiagnosticVerifier {throw 'Synthetic forged closure refused by native verifier'}
Reject 'forged closure cannot seal' {Save-KhcMacDecodeDiagnosticTerminal $receiptBytes}
Accept 'native verifier refusal never writes' {if($script:written){throw 'Forged closure was sealed'}}
Reject 'raw receipt substitution cannot seal' {Save-KhcMacDecodeDiagnosticTerminal ([Text.Encoding]::UTF8.GetBytes('{}'))}
if($NativeVerifier){
    foreach($name in @('Invoke-KhcMacDecodeDiagnosticVerifier','Assert-KhcPlainPath','Get-KhcRecycleV6Hash','Enter-KhcMacDecodeVerifierReadLease')){
        $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
        . ([scriptblock]::Create($f.Extent.Text))
    }
    $scanInput=Join-Path $PSScriptRoot 'storage-lifecycle.psm1'
    $scanSha=(Get-FileHash -LiteralPath $scanInput -Algorithm SHA256).Hash.ToLowerInvariant()
    Reject 'scan held-handle rejects changed raw identity' {
        $held=$null
        try{$held=Enter-KhcChargeScanLeafLease @{$scanInput=('0'*64)}}finally{if($null -ne $held){foreach($handle in $held.Handles){$handle.Dispose()}}}
    }
    Accept 'scan holds exactly hashed file against later writers and releases it' {
        $held=Enter-KhcChargeScanLeafLease @{$scanInput=$scanSha}
        try{
            if($held.Identity -cne ($scanInput+'='+$scanSha) -or $held.Handles.Count -ne 1){throw 'Held raw identity mismatch'}
            $writer=$null;$blocked=$false
            try{$writer=[IO.File]::Open($scanInput,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)}catch [IO.IOException]{$blocked=$true}finally{if($null -ne $writer){$writer.Dispose()}}
            if(-not $blocked){throw 'Later writer could open hashed input'}
        }finally{foreach($handle in $held.Handles){$handle.Dispose()}}
        # handle再取得は読み取りのみ。元source/bundleへの書込み・renameを試みない。
        $reader=[IO.File]::OpenRead($scanInput);$reader.Dispose()
    }
    $python='C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    # 親担当のpure fixtureをmemoryだけで受け渡す。native_main/Cargo/SSHは呼ばない。
    $code=@'
import ast,base64,importlib.util,json,sys
from pathlib import Path
path=Path(sys.argv[1])/'test-mac-decode-phase-build.py'
frozen_spec=importlib.util.spec_from_file_location('frozen_phase_pure_fixture',str(Path(sys.argv[2])/'mac-decode-phase-build.py'))
frozen=importlib.util.module_from_spec(frozen_spec);frozen_spec.loader.exec_module(frozen)
fixture=next(n for n in ast.parse(path.read_text(encoding='utf-8')).body if isinstance(n,ast.FunctionDef) and n.name=='fixture')
scope=dict(M=frozen);exec(compile(ast.Module(body=[fixture],type_ignores=[]),str(path),'exec'),scope)
p,r=scope['fixture']();pb=frozen.canonical(p)
print(json.dumps(dict(protocol=base64.b64encode(pb).decode(),protocol_sha=frozen.digest(pb),receipt=base64.b64encode(frozen.canonical(r)).decode())))
'@
    $wireText=& $python -I -B -c $code $PSScriptRoot $bundleSpec.Directory
    if($LASTEXITCODE -ne 0){throw 'Native pure fixture process failed'}
    $wire=ConvertFrom-Json -AsHashtable -InputObject $wireText
    $nativeSpec=ConvertFrom-Json -AsHashtable -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($wire.protocol)))
    $nativeStart=@{schema=1;protocol='khc-mac-decode-diagnostic-start-v1';purpose='decode-phase-diagnostic';protocol_sha256=$wire.protocol_sha;protocol_base64=$wire.protocol;spec=$nativeSpec;started_utc='2026-10-27T00:00:00.0000000Z'}
    Accept 'native pure protocol subprocess' {$null=Invoke-KhcMacDecodeDiagnosticVerifier $nativeStart}
    Accept 'native pure receipt subprocess' {$null=Invoke-KhcMacDecodeDiagnosticVerifier $nativeStart $wire.receipt}
    Reject 'native pure raw receipt swap subprocess' {$null=Invoke-KhcMacDecodeDiagnosticVerifier $nativeStart ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}')))}
}
if($HistoricalLedger){
    Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
    $historicalModule=Get-Module storage-lifecycle
    # 現在のcontroller/dependencyが利用不能な状態をin-memory hash gateで再現する。
    # repoファイルは変更せず、真のprivate ledgerと凍結bundleのみを読む。
    $evidence=& $historicalModule {
        $anchor=Get-KhcRecycleV6AnchorRoot
        $startPath=Join-Path $anchor 'mac-decode-diagnostic.started.json'
        $sealPath=Join-Path $anchor 'mac-decode-diagnostic.terminal.json'
        $startBefore=Get-KhcRecycleV6Hash $startPath;$sealBefore=Get-KhcRecycleV6Hash $sealPath
        $script:HistoricalHashDelegate=(Get-Item Function:Get-KhcRecycleV6Hash).ScriptBlock
        function script:Get-KhcRecycleV6Hash {
            param([string]$Path)
            if($Path.StartsWith('D:\Dev\UnLhaRe\',[StringComparison]::OrdinalIgnoreCase)){throw 'Current repository verifier unavailable in historical regression'}
            & $script:HistoricalHashDelegate $Path
        }
        try{
            $ledger=Get-KhcMacDecodeDiagnosticLedger
            if($null -eq $ledger.Start -or $null -eq $ledger.Terminal -or $ledger.Terminal.status -cne 'failed'){throw 'Expected historical failed-closed diagnostic missing'}
            Assert-KhcMacDecodeDiagnosticState $true $true $ledger.Terminal
            $seal=Read-KhcRecycleV6PrivateJson $sealPath
            if((Get-KhcRecycleV6Hash $startPath) -cne $startBefore -or (Get-KhcRecycleV6Hash $sealPath) -cne $sealBefore){throw 'Historical ledger changed during read-only regression'}
            [pscustomobject]@{protocol_sha256=$ledger.Start.protocol_sha256;controller_sha256=$ledger.Start.spec.controller_sha256;receipt_sha256=$seal.receipt_sha256;closure_sha256=$ledger.Terminal.closure_sha256;status=$ledger.Terminal.status;start_file_sha256=$startBefore;seal_file_sha256=$sealBefore;ledger_unchanged=$true}
        }finally{Set-Item Function:script:Get-KhcRecycleV6Hash $script:HistoricalHashDelegate;Remove-Variable HistoricalHashDelegate -Scope Script}
    }
    Accept 'historical ledger independent of current verifier' {if($evidence.controller_sha256 -cne $oldController){throw 'Unexpected historical controller'}}
    Accept 'historical receipt identity' {if($evidence.receipt_sha256 -cne '84c7e314b0a79c2ac9d55e34772c8f20339e29079dbd17868605c0e08f27f4ca'){throw 'Historical receipt changed'}}
    $leaseChecks=& $historicalModule {
        $bundle=Get-KhcMacDecodeVerifierBundleSpec 'da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc'
        $path=Join-Path $bundle.Directory 'mac-decode-phase-build.py'
        # Openだけを試し、write/delete/rename自体は一切行わない。
        $lease=Enter-KhcMacDecodeVerifierReadLease $bundle
        $blocked=0
        try{
            try{$writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite);$writer.Dispose()}catch [IO.IOException]{$blocked++}
            foreach($directory in @($bundle.Directory,[IO.Path]::GetDirectoryName($bundle.Directory))){try{$deleteCapability=[Khc.Storage.VerifierDirectoryHandle]::Open($directory,65536);$deleteCapability.Dispose()}catch{$blocked++}}
            $reader=[IO.File]::OpenRead($path);try{if($reader.ReadByte() -lt 0){throw 'Verifier read failed'}}finally{$reader.Dispose()}
        }finally{for($i=$lease.Count-1;$i -ge 0;$i--){$lease[$i].Dispose()}}
        # 先行write handleがある場合もShareRead取得が失敗し、hash/起動に進めない。
        $writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try{try{$unexpected=Enter-KhcMacDecodeVerifierReadLease $bundle;foreach($handle in $unexpected){$handle.Dispose()}}catch [IO.IOException]{$blocked++}catch [ComponentModel.Win32Exception]{if($_.Exception.NativeErrorCode -ne 32){throw};$blocked++}}finally{$writer.Dispose()}
        return $blocked
    }
    Accept 'held verifier denies later writes and task directory deletion; prior writer fails closed' {if($leaseChecks -ne 4){throw "Expected four sharing refusals, got $leaseChecks"}}
    Write-Output ($evidence | ConvertTo-Json -Compress)
}
if($CandidateE2eVerifier){
    Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -DisableNameChecking
    $e2eModule=Get-Module storage-lifecycle
    $actual=& $e2eModule {Read-KhcMacCandidateE2eProtocol 'D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-cdf-candidate-e2e-protocol.json' '95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c'}
    Accept 'registered candidate E2E real protocol bounded stdin produces one summary' {$out=@(& $e2eModule {param($p) Invoke-KhcMacCandidateE2eVerifier $p.Bytes '95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c'} $actual);if($out.Count -ne 1 -or -not $out[0].verified){throw 'Candidate E2E protocol output shape'}}
    $code=@'
import ast,base64,importlib.util,json,sys
from pathlib import Path
path=Path(sys.argv[1])/'test-mac-decode-phase-build.py'
spec=importlib.util.spec_from_file_location('candidate_e2e_frozen',str(Path(sys.argv[2])/'mac-cdf-candidate-e2e-endpoint.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
fixture=next(n for n in ast.parse(path.read_text(encoding='utf-8')).body if isinstance(n,ast.FunctionDef) and n.name=='fixture')
scope=dict(M=m.candidate().old_controller());exec(compile(ast.Module(body=[fixture],type_ignores=[]),str(path),'exec'),scope)
_,old=scope['fixture']();proof=old['closure_proof'];p=m.parse(base64.b64decode(sys.argv[3]));psha=m.digest(m.canonical(p));oracle=m.load_oracle()
required,optional,rows=m.expected_api_files(oracle);records=[dict(path=x,bytes=1,sha256='a'*64) for x in sorted(required)]
for row in records:
 if row['path'].endswith('/sentinel'):row.update(bytes=4,sha256=m.digest(b'keep'))
report=dict(schema=1,scope='candidate-example-correctness-only',api=oracle['api'],files=records,directories=['api','api/source','api/api-output','api/accepted-all-output','api/legacy-compat-output','api/rejected-frames','api/rejected-trailing','api/rejected-truncated'],archive_suffixes=rows,registration_sha256='d'*64,windows_run_id='a'*32,windows_registration_sha256='b'*64,protocol_sha256=psha)
rb=m.canonical(report);r={k:p[k] for k in ('schema','protocol','purpose','endpoint_sha256','source_sha256','example_sha256','candidate_cli_sha256','candidate_build_receipt_sha256','candidate_build_closure_sha256')}
r.update(windows_run_id='a'*32,windows_registration_sha256='b'*64,protocol_sha256=psha,remote_registration_sha256='d'*64,report_sha256=m.digest(rb),report_base64=base64.b64encode(rb).decode(),closure_proof=proof,closure_sha256=m.digest(m.canonical(proof)),children_absent=True,postchecks_ok=True,runtime_seconds=42.,status='done',exit=0,error=None)
done=base64.b64encode(m.canonical(r)).decode();r.update(status='failed',exit=1,postchecks_ok=False,runtime_seconds=310.,error='\u3042'*4096)
failed=base64.b64encode(m.canonical(r)).decode();wire=dict(mode='receipt',protocol_base64=sys.argv[3],protocol_sha256=psha,receipt_base64=failed)
large=len(m.canonical(wire));r.update(closure_proof=None,closure_sha256=None,children_absent=False)
print(json.dumps(dict(done=done,failed=failed,unknown=base64.b64encode(m.canonical(r)).decode(),large_wire_bytes=large)))
'@
    $wire=& 'C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -I -B -c $code $PSScriptRoot $actual.Trust.Directory ([Convert]::ToBase64String($actual.Bytes))
    if($LASTEXITCODE -ne 0){throw 'Candidate E2E memory-only receipt fixture failed'}
    $wire=ConvertFrom-Json -AsHashtable -InputObject $wire
    Accept 'candidate E2E frozen success report/FS receipt over stdin' {$null=& $e2eModule {param($p,$raw) Invoke-KhcMacCandidateE2eVerifier $p.Bytes '95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c' ([Convert]::FromBase64String($raw)) ('a'*32) ('b'*64)} $actual $wire.done}
    Accept 'candidate E2E failed-closed stdin exceeds Windows argv without truncation' {if($wire.large_wire_bytes -le 32768 -or $wire.large_wire_bytes -gt 262144){throw 'Expected bounded large stdin fixture'};$null=& $e2eModule {param($p,$raw) Invoke-KhcMacCandidateE2eVerifier $p.Bytes '95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c' ([Convert]::FromBase64String($raw)) ('a'*32) ('b'*64)} $actual $wire.failed}
    Reject 'candidate E2E unknown closure cannot seal or authorize cleanup' {$null=& $e2eModule {param($p,$raw) Invoke-KhcMacCandidateE2eVerifier $p.Bytes '95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c' ([Convert]::FromBase64String($raw)) ('a'*32) ('b'*64)} $actual $wire.unknown}
    Reject 'candidate E2E real verifier rejects another registered identity' {$null=& $e2eModule {param($p,$raw) Invoke-KhcMacCandidateE2eVerifier $p.Bytes '95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c' ([Convert]::FromBase64String($raw)) ('a'*32) ('f'*64)} $actual $wire.done}
    Write-Output "Candidate E2E bounded stdin fixture: $($wire.large_wire_bytes) bytes; no storage registration or binary execution"
}
if($CandidateE2eProtocolCompatibility){
    $code=@'
import base64,importlib.util,sys
from pathlib import Path
path=Path(sys.argv[1])/'mac-cdf-candidate-e2e-endpoint.py'
spec=importlib.util.spec_from_file_location('candidate_e2e_schema_only',str(path));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
print(base64.b64encode(m.canonical(m.expected_protocol('a'*64))).decode())
'@
    $wire=& 'C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -I -B -c $code $PSScriptRoot
    if($LASTEXITCODE -ne 0){throw 'Candidate E2E schema constructor failed'}
    $prototype=ConvertFrom-Json -AsHashtable -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($wire)))
    Accept 'candidate E2E native/PS schema compatibility only' {Assert-KhcMacCandidateE2eProtocol $prototype}
}
if($CandidateVerifier){
    Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -DisableNameChecking
    $candidateModule=Get-Module storage-lifecycle
    $start=& $candidateModule {
        $bytes=Read-KhcBoundedSnapshotBytes 'D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-cdf-candidate-build-protocol.json' 32768
        return @{protocol_sha256='8c6f4576d868e43158ade779ee176719bc6a7281d4420a4bfe3d371d25ab0082';protocol_base64=[Convert]::ToBase64String($bytes)}
    }
    Accept 'frozen candidate real protocol pure subprocess' {$null=& $candidateModule {param($s) Invoke-KhcMacCdfCandidateVerifier $s} $start}
    $trust=Get-KhcMacCdfCandidateTrustSpec '2f11f23570c9553430cded38b3920ee878867a0a0f8ef5bb9486bcacdf9e1aa5' '80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f' $start.protocol_sha256
    $code=@'
import ast,base64,importlib.util,json,sys
from pathlib import Path
path=Path(sys.argv[1])/'test-mac-decode-phase-build.py'
spec=importlib.util.spec_from_file_location('candidate_frozen',str(Path(sys.argv[2])/'mac-cdf-candidate-build.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
fixture=next(n for n in ast.parse(path.read_text(encoding='utf-8')).body if isinstance(n,ast.FunctionDef) and n.name=='fixture')
scope=dict(M=m.old_controller());exec(compile(ast.Module(body=[fixture],type_ignores=[]),str(path),'exec'),scope)
_,r=scope['fixture']();p=m.parse(base64.b64decode(sys.argv[3]))
for key in ('schema','protocol','purpose','source_sha256','controller_sha256','root','target','cargo_command','binary_path'):r[key]=p[key]
r['protocol_sha256']=m.digest(m.canonical(p));done=base64.b64encode(m.canonical(r)).decode()
r.update(status='failed',exit=1,binary_sha256=None,postchecks_ok=False,error='synthetic failed postcheck',runtime_seconds=400.,cargo_runtime_seconds=350.)
failed=base64.b64encode(m.canonical(r)).decode();r.update(closure_proof=None,closure_sha256=None,wait_confirmed=False,group_absent=False)
print(json.dumps(dict(done=done,failed=failed,unknown=base64.b64encode(m.canonical(r)).decode())))
'@
    $wire=& 'C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -I -B -c $code $PSScriptRoot $trust.Directory $start.protocol_base64
    if($LASTEXITCODE -ne 0){throw 'Candidate synthetic receipt generation failed'}
    $wire=ConvertFrom-Json -AsHashtable -InputObject $wire
    Accept 'candidate frozen success receipt pure subprocess' {$null=& $candidateModule {param($s,$raw) Invoke-KhcMacCdfCandidateVerifier $s $raw} $start $wire.done}
    Accept 'candidate frozen failed closed receipt pure subprocess' {$null=& $candidateModule {param($s,$raw) Invoke-KhcMacCdfCandidateVerifier $s $raw} $start $wire.failed}
    Reject 'candidate unknown closure cannot seal' {$null=& $candidateModule {param($s,$raw) Invoke-KhcMacCdfCandidateVerifier $s $raw} $start $wire.unknown}
}
if($CandidateProtocolCompatibility){
    $code=@'
import base64,importlib.util,sys
from pathlib import Path
path=Path(sys.argv[1])/'mac-cdf-candidate-build.py'
spec=importlib.util.spec_from_file_location('candidate_schema_only',str(path));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
print(base64.b64encode(m.canonical(m.expected_protocol('a'*64,m.SNAPSHOT_SHA))).decode())
'@
    $wire=& 'C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -I -B -c $code $PSScriptRoot
    if($LASTEXITCODE -ne 0){throw 'Unfrozen candidate schema constructor failed'}
    $prototype=ConvertFrom-Json -AsHashtable -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($wire)))
    Accept 'candidate native/PS protocol schema compatibility only; not an execution pin' {Assert-KhcMacCdfCandidateProtocol $prototype}
}
if($QuarantineVerifier){
    # 別PowerShell host内だけでstatic quarantineを作る。実child起動/marker保存は行わない。
    $childCode=@'
$ErrorActionPreference='Stop'
Import-Module '__MODULE__' -Force -DisableNameChecking
$m=Get-Module storage-lifecycle
$proof=& $m {
 function script:Assert-KhcRecycleV6PrivatePath {param($Path,[switch]$ProtectedRoot) return $Path}
 function script:Assert-KhcPlainPath {param($LiteralPath) return $LiteralPath}
 function script:Test-Path {param($LiteralPath) return $false}
 function script:Write-KhcNewJson {param($Path,$Value) $script:CapturedMarker=$Value}
 $process=[Diagnostics.Process]::new();$lease=[Collections.Generic.List[IDisposable]]::new();$lease.Add([IO.MemoryStream]::new())
 $weakProcess=[WeakReference]::new($process);$weakLease=[WeakReference]::new($lease)
 Protect-KhcUnclosedVerifier $process $lease 'synthetic termination unknown'
 if($script:CapturedMarker.protocol -cne 'khc-verifier-unresolved-v1'){throw 'Marker DTO not captured'}
 function script:Write-KhcNewJson {param($Path,$Value) throw 'synthetic disk failure'}
 $writeFailed=$false
 try{Protect-KhcUnclosedVerifier ([Diagnostics.Process]::new()) ([Collections.Generic.List[IDisposable]]::new()) 'synthetic second termination unknown'}catch{$writeFailed=$_.Exception.Message.Contains('persistent blocking cannot be guaranteed')}
 if(-not $writeFailed -or [Khc.Storage.VerifierQuarantineState]::Count -ne 2){throw 'Marker failure lost quarantine or limitation'}
 return [pscustomobject]@{Process=$weakProcess;Lease=$weakLease}
}
[GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect()
if(-not $proof.Process.IsAlive -or -not $proof.Lease.IsAlive){throw 'Quarantine lost strong references'}
Import-Module '__MODULE__' -Force -DisableNameChecking
$blocked=$false
try{& (Get-Module storage-lifecycle) {Assert-KhcVerifierQuarantineClear}}catch{$blocked=$_.Exception.Message.Contains('quarantined')}
if(-not $blocked){throw 'Module reload bypassed static quarantine'}
[Console]::WriteLine('quarantine-strong-reference-marker-reload-passed')
'@
    $childCode=$childCode.Replace('__MODULE__',(Join-Path $PSScriptRoot 'storage-lifecycle.psm1').Replace("'","''"))
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=(Get-Process -Id $PID).Path;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode)))){$info.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::new();$child.StartInfo=$info
    try{
        $null=$child.Start();$output=$child.StandardOutput.ReadToEndAsync();$errorOutput=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(15000)){$child.Kill($true);$null=$child.WaitForExit(5000);throw 'Quarantine isolated probe timeout'}
        $text=$output.GetAwaiter().GetResult();$errorText=$errorOutput.GetAwaiter().GetResult()
        Accept 'static quarantine retains references, blocks after reload, and survives marker failure' {if($child.ExitCode -ne 0 -or $errorText.Length -gt 0 -or $text.Trim() -cne 'quarantine-strong-reference-marker-reload-passed'){throw "Quarantine isolated probe failed: $errorText $text"}}
    }finally{$child.Dispose()}
}
if($LeafFilesystemProbe){
    Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -DisableNameChecking
    & (Get-Module storage-lifecycle) {
        $bundle=Get-KhcMacDecodeVerifierBundleSpec 'da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc'
        $lease=Enter-KhcMacDecodeVerifierReadLease $bundle
        foreach($handle in $lease){$handle.Dispose()}
    }
    if($null -eq ('Khc.Storage.VerifierDirectoryHandle' -as [type]).GetMethod('OpenLeaf')){throw 'Missing native no-follow leaf contract: OpenLeaf'}
    $probe='D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-verifier-leaf-probe-20261027'
    $probeParent=Split-Path $probe -Parent
    foreach($path in @($probeParent,$probe)){if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe leaf probe parent'}}
    if(Test-Path -LiteralPath $probe){throw 'Leaf probe already exists; clean the previous dedicated probe before another creation.'}
    $null=[IO.Directory]::CreateDirectory($probe)
    $null=[IO.Directory]::CreateDirectory((Join-Path $probe 'directory'))
    foreach($name in @('regular.bin','linked-target.bin')){$stream=[IO.File]::Open((Join-Path $probe $name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write([byte[]]@(108,101,97,102));$stream.Flush($true)}finally{$stream.Dispose()}}
    $null=New-Item -ItemType HardLink -Path (Join-Path $probe 'hardlink.bin') -Target (Join-Path $probe 'linked-target.bin')
    # file symlink作成は当環境で管理者権限不足を確認済み。再試行・昇格しない。
    # junctionは別のreparse種別の実測であり、file symlink実測の代替とはしない。
    $null=New-Item -ItemType Junction -Path (Join-Path $probe 'junction') -Target (Join-Path $probe 'directory')
    Accept 'native regular leaf accepts same-handle hash and read' {
        $stream=[Khc.Storage.VerifierDirectoryHandle]::OpenLeaf((Join-Path $probe 'regular.bin'))
        try{$hasher=[Security.Cryptography.SHA256]::Create();try{$hash=[Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant()}finally{$hasher.Dispose()};if($hash -cne '9f91161f43433e49a6de6db680d79f60159f2e4ac9172621a12846428158440b'){throw 'Unexpected same-handle leaf hash'}}finally{$stream.Dispose()}
    }
    foreach($name in @('directory','hardlink.bin','linked-target.bin','junction')){Reject "native no-follow leaf refuses $name" {$stream=[Khc.Storage.VerifierDirectoryHandle]::OpenLeaf((Join-Path $probe $name));$stream.Dispose()}}
    foreach($attributes in @(0x400,0x410)){Reject 'synthetic handle symlink/reparse attributes refused' {[Khc.Storage.VerifierDirectoryHandle]::ValidateLeafAttributes($attributes,1,1)}}
    Reject 'synthetic handle nondisk file refused' {[Khc.Storage.VerifierDirectoryHandle]::ValidateLeafAttributes(0,1,2)}
    Write-Output 'File symlink filesystem case untested: construction required unavailable administrator privilege; no retry or elevation.'
    Write-Output "Dedicated leaf filesystem probe retained for Prunlet cleanup: $probe"
}
if($RetryVerifier){
    Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -DisableNameChecking
    $retryModule=Get-Module storage-lifecycle
    $result=& $retryModule {
        $path='D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-decode-phase-retry-amendment.json'
        $bytes=Read-KhcBoundedSnapshotBytes $path 32768
        $registration=@{amendment_sha256='f2a4979ed0f796b98876a324734998329eb40255b8593350ee439165873ae46e';amendment_base64=[Convert]::ToBase64String($bytes)}
        $summary=Invoke-KhcMacDecodeRetryVerifier $registration
        return [pscustomobject]@{Registration=$registration;Summary=$summary}
    }
    Accept 'frozen retry amendment subprocess with actual old raw evidence' {if(-not $result.Summary.verified){throw 'Retry amendment not verified'}}
    $retryTrust=Get-KhcMacDecodeRetryTrustSpec '771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe' 'b99b4338cc3253181402b215fa826230d6284a9044ba9520efc04af1d0253806'
    $code=@'
import ast,base64,importlib.util,json,sys
from pathlib import Path
path=Path(sys.argv[1])/'test-mac-decode-phase-build.py'
spec=importlib.util.spec_from_file_location('retry_frozen',str(Path(sys.argv[2])/'mac-decode-phase-retry.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
fixture=next(n for n in ast.parse(path.read_text(encoding='utf-8')).body if isinstance(n,ast.FunctionDef) and n.name=='fixture')
scope=dict(M=m.load_old_controller());exec(compile(ast.Module(body=[fixture],type_ignores=[]),str(path),'exec'),scope)
_,r=scope['fixture']();a=m.parse(base64.b64decode(sys.argv[3]));amendment_sha=m.digest(m.canonical(a))
r.update(protocol=a['protocol'],protocol_sha256=amendment_sha,amendment_sha256=amendment_sha,source_sha256=a['source_sha256'],controller_sha256=a['controller_sha256'],snapshot_sha256=a['snapshot_sha256'],old_receipt_sha256=a['old_receipt_sha256'])
done=base64.b64encode(m.canonical(r)).decode()
r.update(status='failed',exit=1,binary_sha256=None,postchecks_ok=False,error='synthetic postcheck failure',runtime_seconds=400.,cargo_runtime_seconds=350.)
failed=base64.b64encode(m.canonical(r)).decode()
r.update(closure_proof=None,closure_sha256=None,wait_confirmed=False,group_absent=False)
print(json.dumps(dict(done=done,failed=failed,unknown=base64.b64encode(m.canonical(r)).decode())))
'@
    $wireText=& 'C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -I -B -c $code $PSScriptRoot $retryTrust.Directory $result.Registration.amendment_base64
    if($LASTEXITCODE -ne 0){throw 'Retry synthetic receipt generation failed'}
    $retryWire=ConvertFrom-Json -AsHashtable -InputObject $wireText
    Accept 'frozen retry success receipt subprocess' {$null=& $retryModule {param($r,$raw) Invoke-KhcMacDecodeRetryVerifier $r $raw} $result.Registration $retryWire.done}
    Accept 'frozen retry closed failure receipt subprocess' {$null=& $retryModule {param($r,$raw) Invoke-KhcMacDecodeRetryVerifier $r $raw} $result.Registration $retryWire.failed}
    Reject 'frozen retry unknown closure cannot seal' {$null=& $retryModule {param($r,$raw) Invoke-KhcMacDecodeRetryVerifier $r $raw} $result.Registration $retryWire.unknown}
}
Write-Output "Mac decode diagnostic pure contracts: $script:passed passed"
