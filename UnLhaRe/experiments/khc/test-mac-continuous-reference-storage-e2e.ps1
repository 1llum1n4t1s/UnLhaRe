#requires -Version 7.0
<#
失敗条件（実装前に固定）:
1. 成功proofのConfirm→private ZIP→seal→登録再読→cleanup検査が実I/Oで通らない。
2. closed failedを拒否する、またはunknown closureをsealしてしまう。
3. work ZIP参照不可後にprivate proofだけで再検証できない。
4. private ZIP改変を受理してしまう。
5. copy完成・seal前中断後、同一bytesのcopyを安全に再利用できない。
境界差替: state入口、fixture内のACL/lock、SSH応答のみ。検証器・hash・ZIP/
JSON読書き・registration/seal/cleanup判定は抽出した本体を実行する。
出力は専用fixtureへ2MiB/96entries以内で保持する。削除・codec・SSHなし。
#>
[CmdletBinding()]
param([string]$ResumeFixtureRoot='',[switch]$VerifyOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:FixtureRoot=$null
$script:RunId='b'*32
$script:InjectSealFailure=$false
$script:FallbackReads=0
$script:Passed=0
$script:SetupCase=$false
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:Passed++}
function MustReject([scriptblock]$Body,[string]$Message){$rejected=$false;try{& $Body}catch{$rejected=$true};Check $rejected $Message}

$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Module parse failed'}
$functions=@('Assert-KhcPlainPath','Get-KhcPortfolioInputProfile','Assert-KhcRemoteReferenceClassData','Assert-KhcRecycleV6ReservationData',
    'Get-KhcRecycleV6Reservation','Get-KhcRecycleV6Hash','Read-KhcRecycleV6PrivateJson','Get-KhcRecycleV6RunAnchor',
    'Read-KhcBoundedSnapshotBytes','ConvertFrom-KhcBoundedJsonSnapshot','Test-KhcMacNativeE2eJsonEqual',
    'Get-KhcMacReferenceKind','Assert-KhcMacReferenceInvocationPair','Assert-KhcMacContinuousProofSummary',
    'Assert-KhcMacContinuousSealData','Get-KhcMacContinuousVerifierPin','Assert-KhcMacContinuousProofCopy',
    'Invoke-KhcMacContinuousProofVerifier','Assert-KhcMacReferenceProtocolData','Assert-KhcMacReferenceManifestData',
    'Assert-KhcMacReferenceSealState','Get-KhcMacReferenceRegistration','Assert-KhcMacReferenceCleanupSeal',
    'Assert-KhcRecycleV6CapacityData','Get-KhcRecycleV6Charges','Confirm-KhcMacReferenceTerminal')
foreach($name in $functions){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $node){throw "Missing body: $name"}
    $text=$node.Extent.Text
    if($name -ceq 'Confirm-KhcMacReferenceTerminal'){
        # named machine-wide mutexだけをfixture内のleaseへ差替。serial.lockは実ファイル。
        $registration='[Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state ''registration.lock''))'
        $cargo='[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state ''cargo.lock''))'
        if(-not $text.Contains($registration) -or -not $text.Contains($cargo)){throw 'Lock boundary changed'}
        $text=$text.Replace($registration,'[IO.MemoryStream]::new()').Replace($cargo,'[IO.MemoryStream]::new()')
    }
    if($name -ceq 'Get-KhcRecycleV6Charges'){
        # 本番Prunlet probeの存在だけは隔離state入口へ差替。reference分岐は原実体。
        $probeGuard='if(-not (Test-Path -LiteralPath (Join-Path $mandatory ''probe.json''))){throw ''Probe reservation anchor is missing.''}'
        if(-not $text.Contains($probeGuard)){throw 'Probe state boundary changed'}
        $text=$text.Replace($probeGuard,'$null=Assert-FixturePath $mandatory')
    }
    . ([scriptblock]::Create($text))
}
$writer=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-KhcNewJson'},$false)
. ([scriptblock]::Create($writer.Extent.Text.Replace('function Write-KhcNewJson','function Write-FixtureActualNewJson')))

function Assert-FixturePath([string]$Path){
    $resolved=Assert-KhcPlainPath $Path
    if($null -eq $script:FixtureRoot -or ($resolved -cne $script:FixtureRoot -and -not $resolved.StartsWith($script:FixtureRoot+'\',[StringComparison]::Ordinal))){throw 'Fixture boundary escape'}
    return $resolved
}
function Measure-Fixture {
    $total=0L;$entries=0
    # 今回の失敗rootも合算し、新root作成で固定枠を回避しない。
    foreach($root in Get-ChildItem -LiteralPath $script:TaskRoot -Directory -Filter 'continuous-reference-storage-e2e-*'){
        $null=Assert-KhcPlainPath $root.FullName;$entries++
        foreach($item in Get-ChildItem -LiteralPath $root.FullName -Recurse -Force){
            $null=Assert-KhcPlainPath $item.FullName
            $entries++;if(-not $item.PSIsContainer){$total+=$item.Length}
        }
    }
    if($total -gt 2MB -or $entries -gt 96){throw "Fixture quota exceeded: $total bytes / $entries entries"}
    [pscustomobject]@{Bytes=$total;Entries=$entries}
}
function Assert-FixtureRoom([long]$AdditionalBytes=0,[int]$AdditionalEntries=0){
    $usage=Measure-Fixture
    if($usage.Bytes+$AdditionalBytes -gt 2MB -or $usage.Entries+$AdditionalEntries -gt 96){throw 'Fixture prospective quota exceeded'}
}
function Write-FixtureBytes([string]$Path,[byte[]]$Bytes){
    $path=Assert-FixturePath $Path
    if(Test-Path -LiteralPath $path){
        if(-not $script:SetupCase -and $path -cne (Join-Path $script:FixtureRoot 'fixture-only.txt')){throw 'Existing non-setup fixture output'}
        $old=[IO.File]::ReadAllBytes($path)
        if($path.EndsWith('invocation.clixml',[StringComparison]::Ordinal)){
            $left=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString($old))
            $right=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString($Bytes))
            if($left.script -cne $right.script -or -not (Test-KhcMacNativeE2eJsonEqual $left.parameters $right.parameters)){throw 'Existing fixture invocation differs'}
        }elseif([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($old)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))){throw 'Existing fixture bytes differ'}
        return
    }
    Assert-FixtureRoom $Bytes.Length 1
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Write-KhcNewJson {
    param([string]$Path,[object]$Value)
    $path=Assert-FixturePath $Path
    if($script:SetupCase -and (Test-Path -LiteralPath $path)){
        $existing=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        if(-not (Test-KhcMacNativeE2eJsonEqual $existing $Value)){throw 'Existing fixture setup identity differs'}
        return
    }
    if($script:InjectSealFailure -and $path -ceq (Join-Path $script:Private "mac-reference-$script:RunId.json")){throw 'Injected interruption after private ZIP copy before seal'}
    Assert-FixtureRoom ([Text.Encoding]::UTF8.GetByteCount(($Value|ConvertTo-Json -Depth 12))) 1
    Write-FixtureActualNewJson $path $Value
}
# 以下だけがstate/環境境界。fixture外のprivate ACLや登録へ到達しない。
function Assert-KhcRecycleV6PrivatePath {param([string]$Path,[switch]$ProtectedRoot)
    $path=Assert-FixturePath $Path
    if(-not (Test-Path -LiteralPath $path)){throw 'Missing fixture private path'}
    return $path
}
function Get-KhcStorageRunLocation {param([string]$RunId)
    if($RunId -cne $script:RunId){throw 'Unexpected fixture run'}
    [pscustomobject]@{StateRoot=$script:State;RecordPath=(Join-Path $script:RunDirectory 'run.json')}
}
function Get-KhcRecycleV6AnchorRoot {return $script:Private}
function Get-KhcLifecycleStateRoots {return $script:State}
function Get-KhcLifecycleUsage {return (Measure-Fixture).Bytes}
function Assert-KhcNoPendingStorageRuns {param($AllowedRecordPath,[switch]$AllowInactiveOwner)$null=Assert-FixturePath $AllowedRecordPath}
function Get-KhcMacNativeE2eRegistration {param($State,$RunId,$Reserve)return $null}
function Get-KhcRecycleV6RunProtocol {param($State,$RunId)$null=Assert-FixturePath $State;if($RunId -cne $script:RunId){throw 'Unknown fixture run'};return 6}
function Assert-KhcStorageBudget {param([long]$ReserveBytes=0)
    # 本番の2MiB余白予約に代えて、fixtureの次copy+seal最大だけを2MiB枠へ予約。
    if($ReserveBytes -gt 0){Assert-FixtureRoom ((Get-Item -LiteralPath (Join-Path $script:Work 'reference-proof.zip')).Length+65536) 2}else{$null=Measure-Fixture}
}
function Invoke-KhcMacContinuousRemote {param($Mode,$RunId,$ProtocolSha256)
    if($RunId -cne $script:RunId -or $ProtocolSha256 -cne $script:ProtocolSha){throw 'Wrong fixture SSH identity'}
    $bytes=Read-KhcBoundedSnapshotBytes (Join-Path $script:Work 'reference-receipt.json')
    if($Mode -ceq 'inspect'){return [pscustomobject]@{Bytes=$bytes;ExitCode=$(if($script:CaseKind -ceq 'success'){0}else{1});ErrorBytes=0}}
    if($Mode -ceq 'read-terminal'){$script:FallbackReads++;return [pscustomobject]@{Bytes=$bytes;ExitCode=0;ErrorBytes=0}}
    throw 'Unexpected SSH operation in storage E2E'
}

$taskRoot=Assert-KhcPlainPath (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019');$script:TaskRoot=$taskRoot
if(-not [IO.Directory]::Exists($taskRoot)){throw 'Existing task work root required'}
if($VerifyOnly -and -not $ResumeFixtureRoot){throw 'VerifyOnly requires an existing ResumeFixtureRoot'}
if($ResumeFixtureRoot){
    $script:FixtureRoot=Assert-KhcPlainPath $ResumeFixtureRoot
    if([IO.Path]::GetDirectoryName($script:FixtureRoot) -cne $taskRoot -or [IO.Path]::GetFileName($script:FixtureRoot) -cnotmatch '^continuous-reference-storage-e2e-[0-9a-f]{32}$' -or -not [IO.Directory]::Exists($script:FixtureRoot)){throw 'Invalid existing fixture resume root'}
}else{$script:FixtureRoot=Join-Path $taskRoot ('continuous-reference-storage-e2e-'+[Guid]::NewGuid().ToString('N'))}
$null=Assert-KhcPlainPath $script:FixtureRoot
if(-not $VerifyOnly){
$null=[IO.Directory]::CreateDirectory($script:FixtureRoot)
# Writeabilityは専用領域のCreateNewで実測。既存ファイルには書き込まない。
Write-FixtureBytes (Join-Path $script:FixtureRoot 'fixture-only.txt') ([Text.Encoding]::UTF8.GetBytes('synthetic storage E2E; no production seal; retain for Prunlet cleanup'))
$python='C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$generator=@'
import base64,importlib.util,json,sys
from pathlib import Path
p=Path(sys.argv[1])/'test-mac-continuous-reference-proof.py'
s=importlib.util.spec_from_file_location('storage_fixture',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
out={}
for kind,success in [('success',True),('failed',False),('unknown',False)]:
    protocol,terminal,files,sha=m.fixture(success)
    if kind=='unknown':
        closure=m.F.M.REF.load_json(files['closure.json']);closure['complete']=False
        files['closure.json']=m.F.M.canonical(closure)
        terminal.update(children_absent=False,closure_sha256=m.F.M.digest(files['closure.json']))
        files['terminal.json']=m.F.M.canonical(terminal)
    data=m.archive(files)
    result=m.M.verify_archive(data,sha,'b'*32)
    out[kind]=dict(archive=base64.b64encode(data).decode(),terminal=base64.b64encode(files['terminal.json']).decode(),protocol=base64.b64encode(files['protocol.json']).decode(),protocol_sha=sha)
print(json.dumps(out,separators=(',',':')))
'@
$generated=& $python -I -B -c $generator $PSScriptRoot
if($LASTEXITCODE -ne 0){throw 'Synthetic proof generator failed'}
$data=ConvertFrom-Json -AsHashtable $generated
$manifestBytes=[IO.File]::ReadAllBytes((Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-canterbury-input-manifest.json'))
if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant() -cne '458a2048459bbcae07a771c072d5e387af910c9916545919e42cbb3bcfbb87af'){throw 'Fixture manifest source pin'}
}

function New-FixtureCase([string]$Name,[string]$Kind){
    $script:SetupCase=$true
    $case=Assert-FixturePath (Join-Path $script:FixtureRoot $Name)
    $script:State=Join-Path $case 'state';$script:Private=Join-Path $script:State 'recycle-v6'
    $script:RunDirectory=Join-Path (Join-Path $script:State 'runs') $script:RunId
    $script:Work=Join-Path $case 'work';$script:CaseKind=$Kind
    $script:ProtocolSha=$data[$Kind].protocol_sha
    Assert-FixtureRoom 0 6
    foreach($directory in @($script:RunDirectory,$script:Private,$script:Work)){$null=[IO.Directory]::CreateDirectory((Assert-FixturePath $directory))}
    $run=@{run_id=$script:RunId;max_bytes=8MB;max_entries=96;work_directory=$script:Work}
    Write-KhcNewJson (Join-Path $script:RunDirectory 'run.json') $run
    $recordSha=Get-KhcRecycleV6Hash (Join-Path $script:RunDirectory 'run.json')
    $reserveSize=Get-KhcRecycleV6Reservation 8MB 96
    $reserve=@{schema=1;protocol='prunlet-recycle-v6';run_id=$script:RunId;registration_sha256=$recordSha;max_bytes=8MB;max_entries=96;payload_bytes=$reserveSize.payload_bytes;metadata_bytes=$reserveSize.metadata_bytes;remote_reference_required=$true;remote_reference_protocol_sha256=$script:ProtocolSha}
    Write-KhcNewJson (Join-Path $script:Private "$script:RunId.reserve.json") $reserve
    Write-KhcNewJson (Join-Path $script:RunDirectory 'recycle-v6.json') @{schema=1;protocol='prunlet-recycle-v6';reservation_sha256=(Get-KhcRecycleV6Hash (Join-Path $script:Private "$script:RunId.reserve.json"))}
    $kindData=Get-KhcMacReferenceKind 'khc-mac-canterbury-continuous-reference-v1'
    $inv=[pscustomobject]@{script=$kindData.Worker;parameters=@{WorkDirectory=$script:Work;ProtocolPath=$kindData.ProtocolPath;ProtocolSha256=$script:ProtocolSha}}
    Write-FixtureBytes (Join-Path $script:RunDirectory 'invocation.clixml') ([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($inv)))
    Write-KhcNewJson (Join-Path $script:Private "mac-reference-$script:RunId-registration.json") @{schema=1;protocol='khc-mac-reference-registration-v1';run_id=$script:RunId;record_sha256=$recordSha;worker_path=$kindData.Worker;worker_sha256=(Get-KhcRecycleV6Hash $kindData.Worker);invocation_sha256=(Get-KhcRecycleV6Hash (Join-Path $script:RunDirectory 'invocation.clixml'));protocol_sha256=$script:ProtocolSha;protocol_utf8=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data[$Kind].protocol));manifest_utf8=[Text.Encoding]::UTF8.GetString($manifestBytes)}
    $proofPath=Join-Path $script:Work 'reference-proof.zip'
    if(Test-Path -LiteralPath $proofPath){
        $verified=Invoke-KhcMacContinuousProofVerifier -ArchivePath $proofPath -ProtocolSha256 $script:ProtocolSha -RunId $script:RunId
        $data[$Kind].archive=[Convert]::ToBase64String([IO.File]::ReadAllBytes($proofPath))
    }
    Write-FixtureBytes $proofPath ([Convert]::FromBase64String($data[$Kind].archive))
    Write-FixtureBytes (Join-Path $script:Work 'reference-receipt.json') ([Convert]::FromBase64String($data[$Kind].terminal))
    $null=Get-KhcRecycleV6RunAnchor $script:State $script:RunId
    $script:SetupCase=$false
}
function Invoke-FixtureConfirm {
    $receipt=Join-Path $script:Work 'reference-receipt.json'
    Confirm-KhcMacReferenceTerminal -RunId $script:RunId -ReceiptPath $receipt -ExpectedSha256 (Get-KhcRecycleV6Hash $receipt)
}
function Read-FixtureSeal {
    $reserve=Get-KhcRecycleV6RunAnchor $script:State $script:RunId
    $registration=Get-KhcMacReferenceRegistration $script:State $script:RunId $reserve -RequireSeal
    Assert-KhcMacReferenceCleanupSeal ([pscustomobject]@{StateRoot=$script:State;RunId=$script:RunId})
    return $registration
}

if($VerifyOnly){
    function Get-FixtureReadSnapshot {
        $rows=@(Get-ChildItem -LiteralPath $script:FixtureRoot -Recurse -Force -File|Sort-Object FullName|ForEach-Object {
            $path=Assert-FixturePath $_.FullName
            [ordered]@{path=$path;bytes=$_.Length;sha256=(Get-KhcRecycleV6Hash $path);write_ticks=$_.LastWriteTimeUtc.Ticks}
        })
        return ConvertTo-Json -Compress -Depth 4 -InputObject $rows
    }
    $before=Get-FixtureReadSnapshot
    $null=Measure-Fixture
    foreach($name in @('success','closed-failed','copy-interrupted','unknown-closure')){
        $case=Assert-FixturePath (Join-Path $script:FixtureRoot $name)
        $script:State=Join-Path $case 'state';$script:Private=Join-Path $script:State 'recycle-v6'
        $script:RunDirectory=Join-Path (Join-Path $script:State 'runs') $script:RunId
        $script:Work=Join-Path $case 'work'
        if($name -ceq 'unknown-closure'){
            MustReject {$null=Read-FixtureSeal} 'Unknown closure passed stored cleanup-seal revalidation'
            $registration=Read-KhcRecycleV6PrivateJson (Join-Path $script:Private "mac-reference-$script:RunId-registration.json")
            $proof=Invoke-KhcMacContinuousProofVerifier -ArchivePath (Join-Path $script:Work 'reference-proof.zip') -ProtocolSha256 $registration.protocol_sha256 -RunId $script:RunId
            Check (-not $proof.cleanup_allowed -and -not $proof.children_absent) 'Unknown proof unexpectedly permits cleanup'
            Check (-not [IO.File]::Exists((Join-Path $script:Private "mac-reference-$script:RunId.json"))) 'Unknown proof has a private seal'
            continue
        }
        $registration=Read-FixtureSeal
        $seal=Read-KhcRecycleV6PrivateJson $registration.SealPath
        $receipt=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($seal.receipt_utf8)) $seal.receipt_sha256
        Check ($receipt.status -ceq $(if($name -ceq 'closed-failed'){'failed'}else{'completed-reference'})) 'Stored seal outcome differs'
        Check ((Get-KhcRecycleV6Hash $seal.proof_path) -ceq $seal.proof_sha256 -and (Get-Item -LiteralPath $seal.proof_path).Length -eq $seal.proof_bytes) 'Stored private proof SHA/length mismatch'
        if($name -ceq 'success'){
            Check (-not [IO.File]::Exists((Join-Path $script:Work 'reference-proof.zip')) -and [IO.File]::Exists((Join-Path $script:Work 'reference-proof.zip.held'))) 'Success work proof absence/held proof changed'
        }
    }
    $usage=Measure-Fixture
    Check ((Get-FixtureReadSnapshot) -ceq $before) 'VerifyOnly changed retained fixture bytes or write timestamps'
    [pscustomobject]@{state='passed';mode='verify-only';cases=$script:Passed;fixture_root=$script:FixtureRoot;bytes=$usage.Bytes;entries=$usage.Entries;write_operations=0;raw_extraction=$false;production_registration_written=$false}|ConvertTo-Json -Compress
    return
}

try{
    New-FixtureCase 'success' 'success'
    $result=Invoke-FixtureConfirm
    Check ($result.State -ceq 'continuous-reference-terminal-sealed') 'Success did not seal'
    $null=Read-FixtureSeal
    Check ([IO.File]::Exists((Join-Path $script:Private "mac-reference-$script:RunId-continuous-proof.zip"))) 'Missing real private ZIP'
    $workZip=Assert-FixturePath (Join-Path $script:Work 'reference-proof.zip')
    $held=Assert-FixturePath (Join-Path $script:Work 'reference-proof.zip.held')
    [IO.File]::Move($workZip,$held)
    $null=Read-FixtureSeal
    Check (-not [IO.File]::Exists($workZip)) 'Work proof still accessible'
    $privateZip=Assert-FixturePath (Join-Path $script:Private "mac-reference-$script:RunId-continuous-proof.zip")
    $original=[IO.File]::ReadAllBytes($privateZip);$changed=[byte[]]$original.Clone();$changed[0]=$changed[0] -bxor 1
    [IO.File]::WriteAllBytes($privateZip,$changed)
    MustReject {$null=Read-FixtureSeal} 'Modified private ZIP was accepted'
    [IO.File]::WriteAllBytes($privateZip,$original)
    $null=Read-FixtureSeal

    New-FixtureCase 'closed-failed' 'failed'
    $result=Invoke-FixtureConfirm
    Check ($result.Status -ceq 'failed' -and $result.ChildrenAbsent) 'Closed failure was not cleanup-sealed'
    $null=Read-FixtureSeal
    Check ($script:FallbackReads -gt 0) 'Failed-terminal read-only fallback not exercised'

    New-FixtureCase 'unknown-closure' 'unknown'
    MustReject {$null=Invoke-FixtureConfirm} 'Unknown closure was sealed'
    Check (-not (Test-Path -LiteralPath (Join-Path $script:Private "mac-reference-$script:RunId.json"))) 'Unknown-closure seal exists'
    MustReject {$null=Read-FixtureSeal} 'Unknown closure passed cleanup seal check'

    New-FixtureCase 'copy-interrupted' 'success'
    $script:InjectSealFailure=$true
    MustReject {$null=Invoke-FixtureConfirm} 'Seal-write interruption was not observed'
    $script:InjectSealFailure=$false
    $privateZip=Assert-FixturePath (Join-Path $script:Private "mac-reference-$script:RunId-continuous-proof.zip")
    Check ([IO.File]::Exists($privateZip)) 'Interruption occurred before real private copy'
    $before=Get-KhcRecycleV6Hash $privateZip
    $charges=Get-KhcRecycleV6Charges
    Check ($charges.total_bytes -gt 0) 'Unsealed copy lost reserve charges'
    $result=Invoke-FixtureConfirm
    Check ($result.State -ceq 'continuous-reference-terminal-sealed' -and (Get-KhcRecycleV6Hash $privateZip) -ceq $before) 'Same-copy resume changed private proof'
    $null=Read-FixtureSeal
    $usage=Measure-Fixture
    [pscustomobject]@{state='passed';cases=$script:Passed;fixture_root=$script:FixtureRoot;bytes=$usage.Bytes;entries=$usage.Entries;retained=$true;production_registration_written=$false;ssh='fixture response only';raw_extraction=$false}|ConvertTo-Json -Compress
}catch{
    Write-Output (ConvertTo-Json -Compress @{state='failed';fixture_root=$script:FixtureRoot;retained=$true;error=$_.Exception.Message})
    throw
}
