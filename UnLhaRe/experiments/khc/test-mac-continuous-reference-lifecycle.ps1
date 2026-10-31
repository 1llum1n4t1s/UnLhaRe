#requires -Version 7.0
# ASTから純粋関数だけを取得。登録・SSH・展開・削除は行わない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Module parser errors'}
foreach($name in @('Get-KhcMacReferenceKind','Assert-KhcMacReferenceInvocationPair','Assert-KhcMacContinuousProofSummary','Assert-KhcMacContinuousSealData','ConvertFrom-KhcMacNativeInvocationSnapshot','Assert-KhcMacContinuousProofCopy','Get-KhcRecycleV6Charges')){
    $function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $function){throw "Missing pure contract: $name"}
    . ([scriptblock]::Create($function.Extent.Text))
}
$script:passed=0
function Accept($name,[scriptblock]$body){& $body;$script:passed++}
function Reject($name,[scriptblock]$body){$failed=$false;try{& $body}catch{$failed=$true};if(-not $failed){throw "Accepted invalid $name"};$script:passed++}
$old=Get-KhcMacReferenceKind 'khc-mac-canterbury-reference-v1'
$new=Get-KhcMacReferenceKind 'khc-mac-canterbury-continuous-reference-v1'
Accept 'old fixed pair' {Assert-KhcMacReferenceInvocationPair $old.Protocol $old.Worker $old.ProtocolPath 1800}
Accept 'new fixed pair' {Assert-KhcMacReferenceInvocationPair $new.Protocol $new.Worker $new.ProtocolPath 180}
Reject 'unknown protocol' {Get-KhcMacReferenceKind 'unknown'}
Reject 'cross worker' {Assert-KhcMacReferenceInvocationPair $new.Protocol $old.Worker $new.ProtocolPath 180}
Reject 'cross protocol path' {Assert-KhcMacReferenceInvocationPair $new.Protocol $new.Worker $old.ProtocolPath 180}
Reject 'old timeout for new protocol' {Assert-KhcMacReferenceInvocationPair $new.Protocol $new.Worker $new.ProtocolPath 1800}
$summary=@{schema=1;protocol=$new.Protocol;run_id=('a'*32);protocol_sha256=('b'*64);endpoint_sha256='4092605d8384666954dd00994a0145d4e81656096d617a957a1512fb9bc34a42';archive_bytes=100;archive_sha256=('c'*64);receipt_sha256=('d'*64);status='completed-reference';exit=0;children_absent=$true;cleanup_allowed=$true;report_sha256=('e'*64);capture_count=64;cli_count=42;pair_count=21;purpose='training-reference-only';superiority_decision_allowed=$false}
function Copy-Data($value){ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -InputObject $value -Depth 30)}
function Check-Summary($value){Assert-KhcMacContinuousProofSummary $value ('a'*32) ('b'*64) ('c'*64) 100}
Accept 'complete local verifier summary' {Check-Summary $summary}
foreach($key in @('protocol','run_id','purpose','exit','archive_bytes','capture_count','children_absent','cleanup_allowed','superiority_decision_allowed')){
    Reject "summary typed $key" {$s=Copy-Data $summary;$s[$key]=if($key -cin @('children_absent','cleanup_allowed','superiority_decision_allowed')){1}else{$true};Check-Summary $s}
}
foreach($key in @('archive_sha256','receipt_sha256','protocol_sha256','endpoint_sha256','report_sha256')){
    Reject "summary SHA $key" {$s=Copy-Data $summary;$s[$key]='0'*63;Check-Summary $s}
}
Reject 'unknown summary type' {$s=Copy-Data $summary;$s.protocol='unknown';Check-Summary $s}
Reject 'successful missing capture' {$s=Copy-Data $summary;$s.capture_count=63;Check-Summary $s}
Reject 'success with unknown closure' {$s=Copy-Data $summary;$s.children_absent=$false;$s.cleanup_allowed=$false;Check-Summary $s}
Accept 'failed unknown closure is evidence only' {$s=Copy-Data $summary;$s.status='failed';$s.exit=1;$s.report_sha256=$null;$s.children_absent=$false;$s.cleanup_allowed=$false;Check-Summary $s}
$seal=@{schema=1;protocol='khc-mac-continuous-reference-terminal-seal-v1';run_id=('a'*32);registration_sha256=('f'*64);protocol_sha256=('b'*64);receipt_sha256=('d'*64);receipt_utf8='{}';confirmed_utc='2026-10-27T00:00:00.0000000Z';proof_path='D:\private\mac-reference-proof.zip';proof_sha256=('c'*64);proof_bytes=100;verifier_sha256=('e'*64)}
function Check-Seal($value){Assert-KhcMacContinuousSealData $value ('a'*32) ('f'*64) ('b'*64) $seal.proof_path ('c'*64) 100}
Accept 'new private seal binding' {Check-Seal $seal}
foreach($key in @('protocol','run_id','registration_sha256','protocol_sha256','proof_path','proof_bytes')){Reject "seal typed $key" {$s=Copy-Data $seal;$s[$key]=$true;Check-Seal $s}}
Reject 'seal ZIP swap' {$s=Copy-Data $seal;$s.proof_sha256='0'*64;Check-Seal $s}
Reject 'seal unknown field' {$s=Copy-Data $seal;$s.extra=1;Check-Seal $s}
foreach($pair in @(@($old.Worker,$old.ProtocolPath),@($new.Worker,$new.ProtocolPath))){
    $inv=[pscustomobject]@{script=$pair[0];parameters=@{WorkDirectory=('D:\Codex\UnLhaRe\goal-restore-20261019\run-'+('a'*32));ProtocolPath=$pair[1];ProtocolSha256=('b'*64)}}
    $raw=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($inv));$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
    Accept 'typed invocation fixed pair' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot $raw $sha 'reference'}
    $inv.parameters.ProtocolPath=if($pair[1] -ceq $new.ProtocolPath){$old.ProtocolPath}else{$new.ProtocolPath}
    $raw=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($inv));$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
    Reject 'typed invocation cross pair' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot $raw $sha 'reference'}
}
$copy=[Text.Encoding]::UTF8.GetBytes('retained-private-proof')
$copySha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($copy)).ToLowerInvariant()
Accept 'interrupted same private copy can resume' {Assert-KhcMacContinuousProofCopy $copy $copySha $copy.Length}
Reject 'interrupted different private copy cannot resume' {Assert-KhcMacContinuousProofCopy ([Text.Encoding]::UTF8.GetBytes('swapped')) $copySha $copy.Length}
# CreateNew後・seal前の状態を実charges関数へ注入。fixture/ACL/削除なし。
function Get-KhcRecycleV6AnchorRoot {'D:\memory\recycle-v6'}
function Get-KhcLifecycleStateRoots {return 'D:\memory'}
function Assert-KhcRecycleV6PrivatePath {param($Path,[switch]$ProtectedRoot)return $Path}
function Test-Path {param($LiteralPath)return $true}
function Get-ChildItem {param($LiteralPath,[switch]$Force,[switch]$Directory,$ErrorAction)
    if($LiteralPath -ceq 'D:\memory\recycle-v6'){[pscustomobject]@{Name=('mac-reference-'+('a'*32)+'-continuous-proof.zip');FullName=('D:\memory\recycle-v6\mac-reference-'+('a'*32)+'-continuous-proof.zip');PSIsContainer=$false;Length=100}}
}
function Read-KhcRecycleV6PrivateJson {param($Path)return @{}}
function Get-KhcMacReferenceRegistration {param($state,$id,$reserve)return [pscustomobject]@{Protocol=@{protocol='khc-mac-canterbury-continuous-reference-v1'};Record=@{protocol_sha256=('b'*64)}}}
function Invoke-KhcMacContinuousProofVerifier {param($ArchivePath,$ProtocolSha256,$RunId)return $summary}
Accept 'unsealed private copy is charged without unknown-name refusal' {$charges=Get-KhcRecycleV6Charges;if($charges.total_bytes -ne 0){throw 'Unexpected external recycle payload charge'}}
[pscustomobject]@{state='passed';cases=$script:passed;side_effects='none'}|ConvertTo-Json -Compress
