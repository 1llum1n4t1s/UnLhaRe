#requires -Version 7.0
# 保存済みprobeを読むだけ。run登録、ACL変更、Prunlet、削除は実行しない。
[CmdletBinding()]
param([string]$ProbeDirectory='D:/Codex/TaskArtifacts/UnLhaRe/goal-restore-20261019/schema6-cleanup-20261026')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Module parser errors'}
foreach($name in @('Assert-KhcRecycleV6ReceiptData','Assert-KhcRecycleV6IdentityData','Assert-KhcRecycleV6MetadataData','Get-KhcRecycleV6Reservation','Assert-KhcRemoteReferenceClassData','Assert-KhcRecycleV6ReservationData','Assert-KhcRecycleV6ProtocolData','Assert-KhcRecycleV6CapacityData','Assert-KhcRecycleV6Tree','Assert-KhcStorageBudget')){
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false)
    if($null -eq $function){throw "Missing validation function: $name"}
    . ([scriptblock]::Create($function.Extent.Text))
}
function Copy-Data($value){ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -InputObject $value -Depth 30)}
$script:passed=0
function Accept([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Output "PASS $Name"}
function Reject([string]$Name,[scriptblock]$Body){$rejected=$false;try{& $Body}catch{$rejected=$true};if(-not $rejected){throw "Accepted invalid case: $Name"};$script:passed++;Write-Output "PASS rejects $Name"}
$preview=Get-Content -LiteralPath (Join-Path $ProbeDirectory 'delete-preview.json') -Raw | ConvertFrom-Json -AsHashtable
$deleted=Get-Content -LiteralPath (Join-Path $ProbeDirectory 'delete-result.json') -Raw | ConvertFrom-Json -AsHashtable
$manifestPath=Join-Path $ProbeDirectory 'operation-metadata/recycle-manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$completion=Get-Content -LiteralPath (Join-Path $ProbeDirectory 'operation-metadata/recycle-0000-complete.json') -Raw | ConvertFrom-Json -AsHashtable
$work=[string]$manifest.entries[0].path
$manifestSha=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
function Check-Metadata($m,$c,$r){Assert-KhcRecycleV6MetadataData -Manifest $m -Completion $c -Receipt $r -ManifestSha256 $manifestSha -WorkDirectory $work -MetadataRoot $manifest.metadataRoot -OwnerSid $manifest.ownerSid -MachineName $manifest.machineName}
Accept 'schema6 preview null size/SHA' {$null=Assert-KhcRecycleV6ReceiptData $preview $work 'delete-preview'}
Accept 'schema6 delete root receipt' {$null=Assert-KhcRecycleV6ReceiptData $deleted $work 'delete-result'}
Accept 'own schema6 metadata and empty security key' {$null=Check-Metadata $manifest $completion $deleted}
foreach($case in @('warning','extra-item','path','kind','status','size','sha256','dryRun','operationId','error')){
    Reject "receipt $case" {
        $r=Copy-Data $deleted
        switch($case){
            warning {$r.warnings=@('warning')}
            extra-item {$r.items+=Copy-Data $r.items[0]}
            path {$r.items[0].path+='-other'}
            kind {$r.items[0].kind='file'}
            status {$r.items[0].status='skipped'}
            size {$r.items[0].size=0}
            sha256 {$r.items[0].sha256='0'*64}
            dryRun {$r.dryRun=$true}
            operationId {$r.operationId='../other'}
            error {$r.items[0].error='failed'}
        }
        $null=Assert-KhcRecycleV6ReceiptData $r $work 'delete-result'
    }
}
Reject 'schema6 purge stage' {$null=Assert-KhcRecycleV6ReceiptData $deleted $work 'purge-preview'}
foreach($case in @('schema','owner','machine','root','entry-path','entry-kind','identity','manifest-sha','opid','action','phase','pidl','physical-path')){
    Reject "metadata $case" {
        $m=Copy-Data $manifest;$c=Copy-Data $completion
        switch($case){
            schema {$m.schema=7}
            owner {$m.ownerSid='S-1-5-18'}
            machine {$m.machineName='OTHER'}
            root {$m.metadataRoot+='-other'}
            entry-path {$m.entries[0].path+='-other'}
            entry-kind {$m.entries[0].kind='file'}
            identity {$c.identity.fileId='0'*32}
            manifest-sha {$c.manifestSha256='0'*64}
            opid {$c.operationId='0'*32}
            action {$c.action='restore'}
            phase {$c.phase='intent'}
            pidl {$c.pidl='%%%'}
            physical-path {$c.physicalPath+='-other'}
        }
        $null=Check-Metadata $m $c $deleted
    }
}
Accept 'minimum reservation' {$r=Get-KhcRecycleV6Reservation 1MB 64;if($r.payload_bytes -ne 1MB -or $r.metadata_bytes -ne 5MB){throw 'reservation mismatch'}}
Accept 'maximum reservation' {$r=Get-KhcRecycleV6Reservation 128MB 4096;if($r.metadata_bytes -ne 257MB){throw 'reservation mismatch'}}
Reject 'negative payload' {$null=Get-KhcRecycleV6Reservation -1 64}
Reject 'zero entry bound' {$null=Get-KhcRecycleV6Reservation 1MB 0}
Reject 'oversized entry bound' {$null=Get-KhcRecycleV6Reservation 1MB 4097}
$reservation=@{schema=1;protocol='prunlet-recycle-v6';run_id=('a'*32);registration_sha256=('b'*64);max_bytes=1MB;max_entries=64;payload_bytes=1MB;metadata_bytes=5MB}
Accept 'protected reservation bounds' {Assert-KhcRecycleV6ReservationData $reservation ('a'*32) ('b'*64)}
foreach($case in @('schema','protocol','run','hash','negative','lower-payload','lower-metadata','entry-overflow')){
    Reject "anchor $case" {
        $a=Copy-Data $reservation
        switch($case){schema {$a.schema=2};protocol {$a.protocol='other'};run {$a.run_id='c'*32};hash {$a.registration_sha256='d'*64};negative {$a.payload_bytes=-1};lower-payload {$a.payload_bytes=0};lower-metadata {$a.metadata_bytes=1MB};entry-overflow {$a.max_entries=4097}}
        Assert-KhcRecycleV6ReservationData $a ('a'*32) ('b'*64)
    }
}
Accept 'legacy completed record remains legacy' {$p=Assert-KhcRecycleV6ProtocolData $false $false $false $false 1 $true $true;if($p -ne 1){throw 'legacy classification'}}
Accept 'new guarded registration is schema6' {$p=Assert-KhcRecycleV6ProtocolData $true $false $false $true 0 $false $false;if($p -ne 6){throw 'new classification'}}
Reject 'forged public complete without private final' {$null=Assert-KhcRecycleV6ProtocolData $true $true $false $true 2 $true $true}
Reject 'private reserve cannot downgrade to schema1 after marker removal' {$null=Assert-KhcRecycleV6ProtocolData $true $true $false $false 1 $true $false}
Reject 'prepare/recover cannot classify removed marker as legacy' {$null=Assert-KhcRecycleV6ProtocolData $true $false $false $false 0 $false $false}
Reject 'private request cannot be orphaned from reserve' {$null=Assert-KhcRecycleV6ProtocolData $false $true $false $false 1 $true $false}
Reject 'schema2 request needs private reserve' {$null=Assert-KhcRecycleV6ProtocolData $false $false $false $true 2 $true $false}
Reject 'partial request publication keeps fail closed' {$null=Assert-KhcRecycleV6ProtocolData $true $false $false $true 2 $true $false}
Reject 'simultaneous lifecycle reserve 1009+1+10+5+margin' {Assert-KhcRecycleV6CapacityData 1009MB 1MB 10MB 5MB 1MB}
Accept 'simultaneous lifecycle exact cap' {Assert-KhcRecycleV6CapacityData 1007MB 1MB 10MB 5MB 1MB}
Reject 'bootstrap probe and records exceed lifecycle cap' {Assert-KhcRecycleV6CapacityData 1023MB 0 1MB 0 1MB}
Accept 'bootstrap probe and records exact cap' {Assert-KhcRecycleV6CapacityData 1022MB 0 1MB 0 1MB}
foreach($name in @('Assert-KhcNoPendingStorageRuns','New-KhcStorageRun','Get-KhcStorageRun','Prepare-KhcStorageRun','Recover-KhcUnstartedStorageRun','Recover-KhcAbandonedStorageRun')){
    $guardFunctionName=$name
    Accept "authoritative protocol guard in $name" {
        $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $guardFunctionName},$false)
        if($f.Extent.Text -notmatch 'Get-KhcRecycleV6RunProtocol'){throw "Missing authoritative protocol guard: $guardFunctionName"}
    }
}
$fixtureEntries=@(
    [ordered]@{path='.';kind='directory'},
    [ordered]@{path='z.bin';kind='file';bytes=3},
    [ordered]@{path='api';kind='directory'},
    [ordered]@{path='api\a.bin';kind='file';bytes=2},
    [ordered]@{path='empty';kind='directory'}
)
$fixtureFiles=@([ordered]@{path='z.bin';bytes=3;sha256=('b'*64)},[ordered]@{path='api\a.bin';bytes=2;sha256=('a'*64)})
$fixtureWantedEntries=@(for($i=$fixtureEntries.Count-1;$i -ge 0;$i--){[pscustomobject]$fixtureEntries[$i]})
$fixtureWantedFiles=@(for($i=$fixtureFiles.Count-1;$i -ge 0;$i--){[pscustomobject]$fixtureFiles[$i]})
$fixtureRun=[pscustomobject]@{Record=[pscustomobject]@{max_entries=64};Request=[pscustomobject]@{expected_entries=$fixtureWantedEntries;expected_files=$fixtureWantedFiles;expected_bytes=5L}}
$script:fixtureTree=[pscustomobject]@{Entries=$fixtureEntries;Files=$fixtureFiles;Metadata=[pscustomobject]@{Bytes=5L}}
# Tree取得だけをmemory DTOに置換し、実際のproduction比較関数を通す。
function Get-KhcWorkInventory {param($WorkDirectory,$MaxEntries);return $script:fixtureTree}
Accept 'mixed OrderedDictionary/PSCustomObject reversed entries and files' {Assert-KhcRecycleV6Tree $fixtureRun 'memory-only'}
Accept 'reverse DTO type direction' {
    $script:fixtureTree=[pscustomobject]@{Entries=$fixtureWantedEntries;Files=$fixtureWantedFiles;Metadata=[pscustomobject]@{Bytes=5L}}
    $reverseRun=[pscustomobject]@{Record=$fixtureRun.Record;Request=[pscustomobject]@{expected_entries=$fixtureEntries;expected_files=$fixtureFiles;expected_bytes=5L}}
    Assert-KhcRecycleV6Tree $reverseRun 'memory-only'
}
foreach($case in @('duplicate-entry','duplicate-file','changed-case','missing-empty-directory','file-size','file-hash')){
    Reject "mixed inventory $case" {
        $entries=@($fixtureEntries | ForEach-Object {Copy-Data $_});$files=@($fixtureFiles | ForEach-Object {Copy-Data $_})
        switch($case){
            duplicate-entry {$entries[1]=Copy-Data $entries[0]}
            duplicate-file {$files[1]=Copy-Data $files[0]}
            changed-case {$entries[2].path='API'}
            missing-empty-directory {$entries=@($entries | Where-Object {$_.path -cne 'empty'})}
            file-size {$files[0].bytes=4}
            file-hash {$files[0].sha256='c'*64}
        }
        $script:fixtureTree=[pscustomobject]@{Entries=$entries;Files=$files;Metadata=[pscustomobject]@{Bytes=5L}}
        Assert-KhcRecycleV6Tree $fixtureRun 'memory-only'
    }
}
$script:macProfile=@{schema=1;protocol='khc-mac-remote-reservation-v1';host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';ordinary_bytes=1536MB;cargo_bytes=1024MB;total_bytes=2684354560L;approval_max_bytes=3221225472L;approval_source='human20261026';created_utc='2026-10-26T00:00:00.0000000Z'}
# Budget本体を通し、全容量取得だけをmemory値へ置換する。D:空き量は読取だけ。
$script:ProjectRoot='memory-project';$script:LegacyTempRoot='memory-ordinary';$script:WorkspaceBase='memory-workspace';$script:LegacyKeepRoot='memory-legacy-keep';$script:TaskArtifactsBase='memory-artifacts';$script:LifecycleCapBytes=1GB
$script:fakeOrdinary=512MB;$script:fakeCargo=5GB
function Assert-KhcDStorageBase {}
function Get-KhcTreeUsage {param($LiteralPath);if($LiteralPath -ceq $script:LegacyTempRoot){return $script:fakeOrdinary};if($LiteralPath -ceq $script:WorkspaceBase){return $script:fakeCargo};return 0L}
function Get-KhcTaskCargoBytes {return $script:fakeCargo}
function Get-KhcLifecycleUsage {return 0L}
function Get-KhcRetirementRetentionBytes {return 0L}
function Get-KhcRecycleV6Charges {return [pscustomobject]@{payload_bytes=0L;metadata_bytes=0L;total_bytes=0L}}
function Get-KhcMacRemoteReservation {return $script:macProfile}
Accept 'remote ordinary and Cargo reach both exact combined caps without double counting' {
    $budget=Assert-KhcStorageBudget
    if($budget.cargo_bytes -ne 6GB -or $budget.external_regular_bytes -ne 2GB -or $budget.total_bytes -ne 8GB -or $budget.lifecycle_bytes -ne 0 -or $budget.actual_tree_total_bytes -ne 5905580032L){throw 'Remote reservation is not included exactly once in charged aggregates.'}
}
Reject 'remote plus ordinary exceeds combined cap by one byte' {$script:fakeOrdinary=512MB+1;try{$null=Assert-KhcStorageBudget}finally{$script:fakeOrdinary=512MB}}
Reject 'remote plus Cargo exceeds combined cap by one byte' {$script:fakeCargo=5GB+1;try{$null=Assert-KhcStorageBudget}finally{$script:fakeCargo=5GB}}
Accept 'optional profile absent leaves historical charged values unchanged' {
    $profileBeforeZero=$script:macProfile;$script:macProfile=$null
    try{$budget=Assert-KhcStorageBudget;if($budget.cargo_bytes -ne 5GB -or $budget.external_regular_bytes -ne 512MB -or $budget.total_bytes -ne 5905580032L -or $budget.remote_total_reserved_bytes -ne 0){throw 'Absent optional Mac profile changes historical charges.'}}finally{$script:macProfile=$profileBeforeZero}
}
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-KhcMacRemoteReservationData'},$false)
if($null -eq $f){throw 'Missing Mac reservation validator'}
. ([scriptblock]::Create($f.Extent.Text))
Accept 'exact authorized Mac profile' {Assert-KhcMacRemoteReservationData $script:macProfile}
Accept 'Mac profile actual JSON serialize-deserialize round trip' {Assert-KhcMacRemoteReservationData (Copy-Data $script:macProfile)}
Accept 'Mac profile explicit UTC DateTime' {$p=Copy-Data $script:macProfile;$p.created_utc=[DateTime]::new(2026,10,26,0,0,0,[DateTimeKind]::Utc);Assert-KhcMacRemoteReservationData $p}
Reject 'Mac profile Unspecified DateTime' {$p=Copy-Data $script:macProfile;$p.created_utc=[DateTime]::new(2026,10,26,0,0,0,[DateTimeKind]::Unspecified);Assert-KhcMacRemoteReservationData $p}
Reject 'Mac profile Local DateTime' {$p=Copy-Data $script:macProfile;$p.created_utc=[DateTime]::new(2026,10,26,0,0,0,[DateTimeKind]::Local);Assert-KhcMacRemoteReservationData $p}
foreach($case in @('schema','protocol','host','root','ordinary','cargo','total','approval','source','timestamp','type','negative','extra-field','missing-field')){
    Reject "Mac reservation $case" {
        $p=Copy-Data $script:macProfile
        switch($case){schema {$p.schema=2};protocol {$p.protocol='other'};host {$p.host='other'};root {$p.root+='/other'};ordinary {$p.ordinary_bytes++};cargo {$p.cargo_bytes++};total {$p.total_bytes++};approval {$p.approval_max_bytes++};source {$p.approval_source='unapproved'};timestamp {$p.created_utc='invalid'};type {$p.cargo_bytes='1073741824'};negative {$p.ordinary_bytes=-1};extra-field {$p.other=1};missing-field {$p.Remove('host')}}
        Assert-KhcMacRemoteReservationData $p
    }
}
foreach($name in @('Assert-KhcMacBuildStartData','Assert-KhcMacBuildTerminalData')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing Mac build validator: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
$buildStart=@{schema=1;protocol='khc-mac-native-build-v1';stage='fetch';source_sha256=('a'*64);script_sha256=('b'*64);host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';started_utc='2026-10-26T00:00:00.0000000Z'}
$buildTerminal=@{stage='fetch';source_sha256=('a'*64);script_sha256=('b'*64);setup_sha256=('c'*64);children_absent=$true;exit=0;status='done'}
Accept 'Mac build immutable start identity' {Assert-KhcMacBuildStartData $buildStart}
Accept 'Mac build terminal success' {Assert-KhcMacBuildTerminalData $buildStart $buildTerminal}
Accept 'Mac build terminal failure resolves children, not success' {$r=Copy-Data $buildTerminal;$r.exit=1;$r.status='failed';Assert-KhcMacBuildTerminalData $buildStart $r}
foreach($case in @('stage','source','script','host','root','schema')){
    Reject "Mac build start $case" {$s=Copy-Data $buildStart;switch($case){stage {$s.stage='other'};source {$s.source_sha256='invalid'};script {$s.script_sha256='invalid'};host {$s.host='other'};root {$s.root+='/other'};schema {$s.schema=2}};Assert-KhcMacBuildStartData $s}
}
foreach($case in @('stage','source','script','children','children-type','exit','status','exit-type','missing-children')){
    Reject "Mac build terminal $case" {$r=Copy-Data $buildTerminal;switch($case){stage {$r.stage='check'};source {$r.source_sha256='d'*64};script {$r.script_sha256='e'*64};children {$r.children_absent=$false};children-type {$r.children_absent='true'};exit {$r.exit=2};status {$r.status='failed'};exit-type {$r.exit='0'};missing-children {$r.Remove('children_absent')}};Assert-KhcMacBuildTerminalData $buildStart $r}
}
foreach($guardFunctionName in @('Enter-KhcCargoLease','New-KhcStorageRun')){
    Accept "Mac pending guard in $guardFunctionName" {$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $guardFunctionName},$false);if($f.Extent.Text -notmatch 'Assert-KhcNoPendingMacBuild'){throw 'Remote pending stage can bypass the shared Cargo/registration gate.'}}
}
foreach($name in @('Assert-KhcMacBuildActivationState','Assert-KhcMacBuildActivationData')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing Mac activation validator: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
Accept 'Mac build initially unused only when activation and directory both absent' {$null=Assert-KhcMacBuildActivationState $false $false 0}
Reject 'Mac activation survives missing stage directory' {$null=Assert-KhcMacBuildActivationState $true $false 0}
Reject 'Mac stage directory has no activation' {$null=Assert-KhcMacBuildActivationState $false $true 1}
Reject 'Mac activation and empty directory have no start' {$null=Assert-KhcMacBuildActivationState $true $true 0}
Accept 'Mac activation and nonempty started ledger' {$null=Assert-KhcMacBuildActivationState $true $true 1}
$activation=@{schema=1;protocol='khc-mac-native-build-activation-v1';source_sha256=('a'*64);script_sha256=('b'*64);host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';activated_utc='2026-10-26T00:00:00.0000000Z'}
Accept 'Mac immutable activation identity' {Assert-KhcMacBuildActivationData $activation}
foreach($case in @('source','script','host','root','schema','protocol','timestamp','extra-field')){
    Reject "Mac activation $case" {$a=Copy-Data $activation;switch($case){source {$a.source_sha256='invalid'};script {$a.script_sha256='invalid'};host {$a.host='other'};root {$a.root+='/other'};schema {$a.schema=2};protocol {$a.protocol='other'};timestamp {$a.activated_utc='invalid'};extra-field {$a.other=1}};Assert-KhcMacBuildActivationData $a}
}
foreach($name in @('Get-KhcMacBuildLedger','Assert-KhcMacBuildIntentState','Assert-KhcMacBuildIntentData','Assert-KhcMacBuildBindingData','Assert-KhcMacBuildAmendmentSpec')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -ne $f){. ([scriptblock]::Create($f.Extent.Text))}
}
$prepareStart=Copy-Data $buildStart;$prepareStart.stage='prepare-source'
$prepareReceipt=Copy-Data $buildTerminal;$prepareReceipt.stage='prepare-source'
$prepareIntent=@{schema=1;protocol='khc-mac-native-build-intent-v1';stage='prepare-source';source_sha256=('a'*64);script_sha256=('b'*64);host='m3mb14';root=$activation.root;started_sha256=('f'*64)}
$fetchIntent=Copy-Data $prepareIntent;$fetchIntent.stage='fetch'
$script:mockMacRecords=@{
    'memory-root/mac-native-build-activation.json'=$activation
    'memory-root/mac-native-build-prepare-source-intent.json'=$prepareIntent
    'memory-root/mac-native-build-fetch-intent.json'=$fetchIntent
    'memory-root/mac-native-build/prepare-source.started.json'=$prepareStart
    'memory-root/mac-native-build/prepare-source.terminal.json'=@{schema=1;protocol='khc-mac-native-build-v1';stage='prepare-source';receipt=$prepareReceipt;completed_utc='2026-10-26T00:00:00.0000000Z'}
}
function Get-KhcRecycleV6AnchorRoot {return 'memory-root'}
function Assert-KhcRecycleV6PrivatePath {param($Path,[switch]$ProtectedRoot);return $Path}
function Assert-KhcPlainPath {param($LiteralPath);return $LiteralPath}
function Test-Path {param($LiteralPath);$p=$LiteralPath.Replace('\','/');return ($p -ceq 'memory-root/mac-native-build' -or $script:mockMacRecords.ContainsKey($p))}
function Get-ChildItem {
    [CmdletBinding()]param($LiteralPath,[switch]$Force,[string]$Filter)
    $parent=$LiteralPath.Replace('\','/').TrimEnd('/')
    foreach($path in $script:mockMacRecords.Keys){if($path.Substring(0,$path.LastIndexOf('/')) -ceq $parent){[pscustomobject]@{FullName=$path;Name=$path.Substring($path.LastIndexOf('/')+1);PSIsContainer=$false}}}
}
function Read-KhcRecycleV6PrivateJson {param($Path);$p=$Path.Replace('\','/');if(-not $script:mockMacRecords.ContainsKey($p)){throw 'Missing in-memory ledger record'};return $script:mockMacRecords[$p]}
function Get-KhcRecycleV6Hash {param($Path);return ('f'*64)}
function Get-KhcMacBuildAmendment {return $null}
Reject 'completed prepare plus fetch intent with missing fetch start blocks ledger' {$null=@(Get-KhcMacBuildLedger)}
foreach($case in @(@($true,$false,$false),@($false,$true,$false),@($false,$false,$true),@($true,$false,$true))){
    Reject "Mac intent/start/terminal orphan $($case -join '/')" {$null=Assert-KhcMacBuildIntentState $case[0] $case[1] $case[2]}
}
Accept 'Mac intent and start remain pending without terminal' {$null=Assert-KhcMacBuildIntentState $true $true $false}
Accept 'Mac intent start terminal complete' {$null=Assert-KhcMacBuildIntentState $true $true $true}
Accept 'Mac exact intent binds full start record hash' {Assert-KhcMacBuildIntentData $prepareIntent $prepareStart ('f'*64)}
foreach($case in @('stage','source','script','hash','schema')){
    Reject "Mac intent binding $case" {$i=Copy-Data $prepareIntent;switch($case){stage {$i.stage='fetch'};source {$i.source_sha256='c'*64};script {$i.script_sha256='d'*64};hash {$i.started_sha256='e'*64};schema {$i.schema=2}};Assert-KhcMacBuildIntentData $i $prepareStart ('f'*64)}
}
foreach($name in @('Assert-KhcMacBuildAmendmentSpec','Assert-KhcMacBuildBindingData')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing amendment validator: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
$amendmentSpec=@{schema=1;protocol='khc-mac-native-build-amendment-v1';task='goal-restore-20261019';host='m3mb14';root=$activation.root;stage='build';source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f';old_controller_sha256='51baf46cb26f441e1148123409a271421bd17944893e9bbd3e2fd68401c56a97';new_controller_sha256=('c'*64);old_check_terminal_sha256='80e848d522773b5ec9a47b3eea677d87d38641b72bb12dd1036c19bed214c161';environment_sha256=('d'*64);cc_shim_sha256=('e'*64);reason='sandboxed-xcrun-cache-and-rust-objcopy-rpath'}
Accept 'exact build-only amendment spec' {Assert-KhcMacBuildAmendmentSpec $amendmentSpec}
foreach($case in @('schema','stage','source','old-controller','same-controller','old-check','host','root','env-format','shim-format','extra')){
    Reject "amendment spec $case" {$s=Copy-Data $amendmentSpec;switch($case){schema {$s.schema='1'};stage {$s.stage='check'};source {$s.source_sha256='0'*64};old-controller {$s.old_controller_sha256='0'*64};same-controller {$s.new_controller_sha256=$s.old_controller_sha256};old-check {$s.old_check_terminal_sha256='0'*64};host {$s.host='other'};root {$s.root+='/other'};env-format {$s.environment_sha256='bad'};shim-format {$s.cc_shim_sha256='bad'};extra {$s.other=1}};Assert-KhcMacBuildAmendmentSpec $s}
}
$amendment=@{schema=1;protocol='khc-mac-native-build-amendment-registration-v1';spec_sha256=('f'*64);spec=$amendmentSpec;registered_utc='2026-10-26T00:00:00.0000000Z'}
$oldActivation=Copy-Data $activation;$oldActivation.source_sha256=$amendmentSpec.source_sha256;$oldActivation.script_sha256=$amendmentSpec.old_controller_sha256
$amendedStart=Copy-Data $buildStart;$amendedStart.stage='build';$amendedStart.source_sha256=$amendmentSpec.source_sha256;$amendedStart.script_sha256=$amendmentSpec.new_controller_sha256;$amendedStart.amendment_sha256='f'*64
Accept 'only amended build changes controller' {Assert-KhcMacBuildBindingData $amendedStart $oldActivation $amendment}
foreach($case in @('missing-amendment','stage','source','controller','amendment-hash','old-build')){
    Reject "amendment build binding $case" {$s=Copy-Data $amendedStart;$a=$amendment;switch($case){missing-amendment {$a=$null};stage {$s.stage='check'};source {$s.source_sha256='0'*64};controller {$s.script_sha256='0'*64};amendment-hash {$s.amendment_sha256='0'*64};old-build {$s.script_sha256=$amendmentSpec.old_controller_sha256;$s.Remove('amendment_sha256')}};Assert-KhcMacBuildBindingData $s $oldActivation $a}
}
$amendedIntent=Copy-Data $prepareIntent;$amendedIntent.stage='build';$amendedIntent.source_sha256=$amendedStart.source_sha256;$amendedIntent.script_sha256=$amendedStart.script_sha256;$amendedIntent.amendment_sha256='f'*64
Accept 'amended intent binds same spec SHA' {Assert-KhcMacBuildIntentData $amendedIntent $amendedStart ('f'*64)}
Reject 'amended intent rejects missing spec SHA' {$i=Copy-Data $amendedIntent;$i.Remove('amendment_sha256');Assert-KhcMacBuildIntentData $i $amendedStart ('f'*64)}
$amendedTerminal=Copy-Data $buildTerminal;$amendedTerminal.stage='build';$amendedTerminal.source_sha256=$amendedStart.source_sha256;$amendedTerminal.script_sha256=$amendedStart.script_sha256;$amendedTerminal.amendment_sha256='f'*64
Accept 'amended terminal echoes same spec SHA' {Assert-KhcMacBuildTerminalData $amendedStart $amendedTerminal}
Reject 'amended terminal rejects missing spec SHA' {$r=Copy-Data $amendedTerminal;$r.Remove('amendment_sha256');Assert-KhcMacBuildTerminalData $amendedStart $r}
Accept 'amendment registration uses one bounded snapshot and no hash/content reopens' {
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Register-KhcMacBuildAmendment'},$false)
    if($f.Extent.Text -match 'Get-Content|Get-KhcRecycleV6Hash' -or @([regex]::Matches($f.Extent.Text,'Read-KhcMacBuildAmendmentSnapshot')).Count -ne 1){throw 'Approval A / parsed B / approval A race is still possible through separate opens.'}
}
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ConvertFrom-KhcMacBuildAmendmentSnapshot'},$false)
if($null -eq $f){throw 'Missing immutable amendment snapshot validator'}
. ([scriptblock]::Create($f.Extent.Text))
$approvedBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json $amendmentSpec -Depth 12))
$approvedSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($approvedBytes)).ToLowerInvariant()
Accept 'same amendment bytes bind approved hash and parsed pins' {$parsed=ConvertFrom-KhcMacBuildAmendmentSnapshot $approvedBytes $approvedSha;if($parsed.new_controller_sha256 -cne $amendmentSpec.new_controller_sha256){throw 'Snapshot parse changed controller'}}
Reject 'A hash cannot authorize different valid B pins' {$b=Copy-Data $amendmentSpec;$b.new_controller_sha256='9'*64;$bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json $b -Depth 12));$null=ConvertFrom-KhcMacBuildAmendmentSnapshot $bytes $approvedSha}
Reject 'invalid UTF8 snapshot' {$bad=[byte[]]@(255);$h=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bad)).ToLowerInvariant();$null=ConvertFrom-KhcMacBuildAmendmentSnapshot $bad $h}
Reject 'oversized snapshot' {$null=ConvertFrom-KhcMacBuildAmendmentSnapshot ([byte[]]::new(65537)) $approvedSha}
Reject 'duplicate spec JSON key' {$bad=[Text.Encoding]::UTF8.GetBytes('{"schema":1,"schema":1}');$h=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bad)).ToLowerInvariant();$null=ConvertFrom-KhcMacBuildAmendmentSnapshot $bad $h}
foreach($name in @('Assert-KhcMacNativeE2eProtocolData','Assert-KhcMacNativeE2eSealState')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
    if($null -eq $f){throw "Missing ps-free validator: $name"}
    . ([scriptblock]::Create($f.Extent.Text))
}
$psFreeProtocol=@{schema=1;protocol='khc-mac-native-e2e-ps-free-v1';task='goal-restore-20261019';host='m3mb14';root=$activation.root;run='mac-native-e2e-ps-free-20261026';windows_max_bytes=8MB;windows_max_entries=96;windows_timeout_seconds=360;remote_global_seconds=300;remote_supervisor_seconds=305;source_sha256=$amendmentSpec.source_sha256;old_failed_build_sha256='1b66fadf5833ad2874738b91b7107ccff9dd906f0b58ab4beb7f936d275ab9b7';previous_e2e_sha256='60311a84931e505b6b2de2810d31ed2d7c3e60c4ca6af66c1baf59c5a1eda12c';endpoint_sha256=('c'*64);e2e_script_sha256=('d'*64);config_sha256=('e'*64);oracle_sha256='343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75';fixture_sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650';cli_sha256='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629';e2e_sha256='b4e8d7c5fe5fa87b74c466cacabe4c94baddf80a1717b66629e0012c59e12ff4';reason='sandbox-ps-exec-denied-use-outer-group-proof'}
Accept 'ps-free exact fixed protocol' {Assert-KhcMacNativeE2eProtocolData $psFreeProtocol}
foreach($case in @('schema','host','root','resource','timeout','source','old-fail','previous-script','cli','endpoint','extra')){
    Reject "ps-free protocol $case" {$p=Copy-Data $psFreeProtocol;switch($case){schema {$p.schema=$true};host {$p.host='other'};root {$p.root+='/other'};resource {$p.windows_max_bytes++};timeout {$p.windows_timeout_seconds=361};source {$p.source_sha256='0'*64};old-fail {$p.old_failed_build_sha256='0'*64};previous-script {$p.previous_e2e_sha256='0'*64};cli {$p.cli_sha256='0'*64};endpoint {$p.endpoint_sha256='bad'};extra {$p.other=1}};Assert-KhcMacNativeE2eProtocolData $p}
}
Accept 'ordinary run does not acquire remote seal requirement' {Assert-KhcMacNativeE2eSealState $false $false $false -RequireSeal}
Accept 'registered remote pending may prepare before canonical seal' {Assert-KhcMacNativeE2eSealState $true $true $false}
Reject 'private remote flag cannot lose registration' {Assert-KhcMacNativeE2eSealState $true $false $false}
Reject 'remote registration cannot lose private reserve flag' {Assert-KhcMacNativeE2eSealState $false $true $false}
Reject 'public receipt alone cannot authorize cleanup' {Assert-KhcMacNativeE2eSealState $true $true $false -RequireSeal}
Accept 'private canonical terminal seal authorizes cleanup' {Assert-KhcMacNativeE2eSealState $true $true $true -RequireSeal}
foreach($name in @('ConvertFrom-KhcBoundedJsonSnapshot','Test-KhcMacNativeE2eJsonEqual','Assert-KhcMacNativeE2eReceiptData')){$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false);if($null -eq $f){throw "Missing terminal validator: $name"};. ([scriptblock]::Create($f.Extent.Text))}
$oracleData=Get-Content -LiteralPath 'D:/Codex/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-native-e2e-oracle.json' -Raw | ConvertFrom-Json -AsHashtable
$goldens=@(for($n=0;$n -lt 3;$n++){$hex=$oracleData.api.folded_zero_count_frames[$n];$bytes=[Convert]::FromHexString($hex);@{index=$n;hex=$hex;bytes=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}})
$remoteReport=@{schema=1;state='passed';tracked_direct_children_absent=$true;windows_run_id=('a'*32);protocol_sha256=('f'*64);registration_sha256=('b'*64);checks=$oracleData.checks;api=$oracleData.api;full_goldens=$goldens;archive_suffixes=$oracleData.archive_suffixes;restored=$oracleData.restored}
foreach($key in @('config_sha256','oracle_sha256','fixture_sha256','cli_sha256','e2e_sha256','old_failed_build_sha256','previous_e2e_sha256','e2e_script_sha256','reason')){$remoteReport[$key]=$psFreeProtocol[$key]}
$reportBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $remoteReport -Depth 25 -Compress))
$endpointReceipt=@{schema=1;protocol='khc-mac-native-e2e-ps-free-terminal-v1';windows_run_id=('a'*32);protocol_sha256=('f'*64);children_absent=$true;tracked_direct_children_absent=$true;exit=0;status='passed';report_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reportBytes)).ToLowerInvariant();report_base64=[Convert]::ToBase64String($reportBytes);error=$null}
foreach($key in @('endpoint_sha256','e2e_script_sha256','config_sha256','oracle_sha256','fixture_sha256','source_sha256','old_failed_build_sha256','previous_e2e_sha256','cli_sha256','e2e_sha256','reason')){$endpointReceipt[$key]=$psFreeProtocol[$key]}
Accept 'canonical endpoint terminal and full report' {$null=Assert-KhcMacNativeE2eReceiptData $endpointReceipt $psFreeProtocol ('f'*64) ('a'*32) $oracleData}
foreach($case in @('children','children-type','windows-id','protocol-sha','source','binary','report-hash','report-missing','status','exit-type','extra')){Reject "endpoint terminal $case" {$r=Copy-Data $endpointReceipt;switch($case){children {$r.children_absent=$false};children-type {$r.children_absent='true'};windows-id {$r.windows_run_id='c'*32};protocol-sha {$r.protocol_sha256='0'*64};source {$r.source_sha256='0'*64};binary {$r.cli_sha256='0'*64};report-hash {$r.report_sha256='0'*64};report-missing {$r.report_base64=$null};status {$r.status='unknown'};exit-type {$r.exit='0'};extra {$r.other=1}};$null=Assert-KhcMacNativeE2eReceiptData $r $psFreeProtocol ('f'*64) ('a'*32) $oracleData}}
Accept 'failed canonical terminal permits cleanup but never pass' {$r=Copy-Data $endpointReceipt;$r.exit=1;$r.status='failed';$r.report_sha256=$null;$r.report_base64=$null;$r.tracked_direct_children_absent=$false;$r.error='E2E failed';$null=Assert-KhcMacNativeE2eReceiptData $r $psFreeProtocol ('f'*64) ('a'*32) $oracleData}
foreach($name in @('ConvertFrom-KhcMacNativeInvocationSnapshot','Get-KhcMacNativeE2eChildCommand')){$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false);if($null -eq $f){throw "Missing child snapshot validator: $name"};. ([scriptblock]::Create($f.Extent.Text))}
$nativeInvocation=[pscustomobject]@{script='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-spatial-mdl-e2e.ps1';parameters=@{WorkDirectory=('D:\Codex\UnLhaRe\goal-restore-20261019\run-'+('a'*32));ProtocolPath='D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-native-e2e-ps-free-protocol.json';ProtocolSha256=('f'*64)}}
$invocationBytes=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($nativeInvocation,5))
$invocationHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($invocationBytes)).ToLowerInvariant()
Accept 'child parses only exact approved invocation snapshot' {$inv=ConvertFrom-KhcMacNativeInvocationSnapshot $invocationBytes $invocationHash;if($inv.script -cne $nativeInvocation.script){throw 'Wrong child worker'}}
Reject 'child approved A hash refuses swapped B worker before dispatch' {$b=[pscustomobject]@{script='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\compare.ps1';parameters=$nativeInvocation.parameters};$bytes=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($b,5));$null=ConvertFrom-KhcMacNativeInvocationSnapshot $bytes $invocationHash}
Reject 'child approved A hash refuses swapped B protocol parameter' {$b=[pscustomobject]@{script=$nativeInvocation.script;parameters=@{WorkDirectory=$nativeInvocation.parameters.WorkDirectory;ProtocolPath=$nativeInvocation.parameters.ProtocolPath;ProtocolSha256=('0'*64)}};$bytes=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($b,5));$null=ConvertFrom-KhcMacNativeInvocationSnapshot $bytes $invocationHash}
Reject 'child snapshot exceeds 32KiB bound' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot ([byte[]]::new(32769)) $invocationHash}
Accept 'native encoded command carries trusted literal SHA and one snapshot parse' {$command=Get-KhcMacNativeE2eChildCommand $invocationHash;if(-not $command.Contains("'$invocationHash'") -or $command -match 'Import-Clixml|Get-Content|Get-FileHash' -or @([regex]::Matches($command,'Read-KhcBoundedSnapshotBytes')).Count -ne 1 -or @([regex]::Matches($command,'ConvertFrom-KhcMacNativeInvocationSnapshot')).Count -ne 1){throw 'Native child command can reopen an untrusted execution input'}}
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-KhcRecycleV6Completed'},$false)
. ([scriptblock]::Create($f.Extent.Text))
$script:completedBinding=@{request_sha256=('f'*64);archive_sha256=('f'*64);exe_sha256=('f'*64);config_sha256=('f'*64)}
$script:completedReserve=@{payload_bytes=1MB;metadata_bytes=5MB;remote_native_e2e_required=$true}
$script:completedFinal=@{schema=1;run_id=('a'*32);reservation_sha256=('f'*64);proof_path=(Join-Path 'memory-run' 'recycle-v6-proof.json');proof_sha256=('f'*64);complete_sha256=('f'*64);payload_bytes=0L;metadata_bytes=5MB;operation_id=$null}
$script:completedProof=@{schema=1;protocol='prunlet-recycle-v6';run_id=('a'*32);operation_id=$null;payload_bytes=0L;metadata_bytes=5MB;disposition='recycle-retained';reclaimed_bytes=0L;root_after_bytes=0L}
foreach($key in $script:completedBinding.Keys){$script:completedFinal[$key]=$script:completedBinding[$key];$script:completedProof[$key]=$script:completedBinding[$key]}
$script:completedProofJson=ConvertTo-Json $script:completedProof -Depth 12
$script:missingCompletedRemoteSeal=$true;$script:completedRemoteRequired=$true
function Get-KhcRecycleV6RunAnchor {param($State,$RunId,[switch]$Request);if($Request){return $script:completedBinding};return $script:completedReserve}
function Read-KhcRecycleV6PrivateJson {param($Path);return $script:completedFinal}
function Get-Content {[CmdletBinding()]param($LiteralPath,[switch]$Raw);return $script:completedProofJson}
function Assert-KhcMacNativeE2eCleanupSeal {param($Run);if($script:completedRemoteRequired -and $script:missingCompletedRemoteSeal){throw 'Missing private remote seal'}}
$script:mockReferenceRequired=$false;$script:mockReferenceSealMissing=$false
function Assert-KhcMacReferenceCleanupSeal {param($Run);if($script:mockReferenceRequired -and $script:mockReferenceSealMissing){throw 'Missing private reference seal'}}
function Assert-KhcMacCandidateE2eCleanupSeal {param($Run);if($script:completedReserve.Contains('remote_candidate_e2e_required')){throw 'Candidate E2E requires its separate private seal'}}
$completedLocation=[pscustomobject]@{StateRoot='memory-state';Directory='memory-run'}
$completedRecord=[pscustomobject]@{run_id=('a'*32);work_directory='memory-work'}
$completedRequest=[pscustomobject]@{protocol='prunlet-recycle-v6';run_id=('a'*32);work_directory='memory-work';expected_bytes=0L;requires_prunlet=$false}
$completedPublic=[pscustomobject]@{Disposition='recycle-retained';ReclaimedBytes=0L}
Reject 'actual completed validator rejects remote seal single-record loss' {$null=Test-KhcRecycleV6Completed $completedLocation ('a'*32) $completedRecord $completedRequest $completedPublic}
Accept 'actual completed validator accepts present canonical remote seal' {$script:missingCompletedRemoteSeal=$false;$result=Test-KhcRecycleV6Completed $completedLocation ('a'*32) $completedRecord $completedRequest $completedPublic;if($result.State -cne 'completed-receipts-verified'){throw 'Completion changed'}}
Accept 'actual completed validator preserves nonremote completion' {$script:missingCompletedRemoteSeal=$true;$script:completedRemoteRequired=$false;$result=Test-KhcRecycleV6Completed $completedLocation ('a'*32) $completedRecord $completedRequest $completedPublic;if($result.State -cne 'completed-receipts-verified'){throw 'Nonremote completion changed'}}
$referenceInvocation=[pscustomobject]@{script='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-canterbury-reference.ps1';parameters=@{WorkDirectory=$nativeInvocation.parameters.WorkDirectory;ProtocolPath='D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\mac-canterbury-reference-protocol.json';ProtocolSha256=('f'*64)}}
$referenceInvocationBytes=[Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($referenceInvocation,5))
$referenceInvocationHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($referenceInvocationBytes)).ToLowerInvariant()
Accept 'reference class dispatches only fixed reference worker' {$inv=ConvertFrom-KhcMacNativeInvocationSnapshot $referenceInvocationBytes $referenceInvocationHash 'reference';if($inv.script -cne $referenceInvocation.script){throw 'Wrong reference worker'}}
Reject 'native class cannot dispatch reference worker' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot $referenceInvocationBytes $referenceInvocationHash 'native-e2e'}
Reject 'reference class cannot dispatch old native worker' {$null=ConvertFrom-KhcMacNativeInvocationSnapshot $invocationBytes $invocationHash 'reference'}
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-KhcRemoteReferenceClassData'},$false)
if($null -eq $f){throw 'Missing mutually exclusive remote class validator'}
. ([scriptblock]::Create($f.Extent.Text))
Reject 'remote E2E and reference required flags cannot both be true' {Assert-KhcRemoteReferenceClassData $true $true}
Accept 'reference classification remains separate' {$class=Assert-KhcRemoteReferenceClassData $false $true;if($class -cne 'reference'){throw 'Reference class downgrade'}}
Reject 'actual private reserve rejects both remote-required classes' {$r=Copy-Data $reservation;$r.remote_native_e2e_required=$true;$r.remote_native_e2e_protocol_sha256='f'*64;$r.remote_reference_required=$true;$r.remote_reference_protocol_sha256='f'*64;Assert-KhcRecycleV6ReservationData $r ('a'*32) ('b'*64)}
Reject 'reference reserve flag without protocol SHA is corrupted' {$r=Copy-Data $reservation;$r.remote_reference_required=$true;Assert-KhcRecycleV6ReservationData $r ('a'*32) ('b'*64)}
Reject 'reference reserve false flag cannot downgrade classification' {$r=Copy-Data $reservation;$r.remote_reference_required=$false;$r.remote_reference_protocol_sha256='f'*64;Assert-KhcRecycleV6ReservationData $r ('a'*32) ('b'*64)}
Accept 'private reference reserve preserves one exact class' {$r=Copy-Data $reservation;$r.remote_reference_required=$true;$r.remote_reference_protocol_sha256='f'*64;Assert-KhcRecycleV6ReservationData $r ('a'*32) ('b'*64)}
foreach($name in @('Get-KhcPortfolioInputProfile','Assert-KhcMacReferenceProtocolData','Assert-KhcMacReferenceManifestData')){$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false);if($null -eq $f){throw "Missing reference validator: $name"};. ([scriptblock]::Create($f.Extent.Text))}
$referenceProfiles=@(@{id='khc';strategy='portfolio-trial';encode_workers=1;decode_workers=1},@{id='lzma2';level=9;dictionary_bytes=8MB;fast_bytes=273;solid=$true;sort_by_type=$true;store_mtime=$true;store_ctime=$false;store_atime=$false;encode_workers=1;decode_workers=1},@{id='ppmd';level=9;memory_bytes=64MB;order=16;solid=$true;sort_by_type=$true;store_mtime=$true;store_ctime=$false;store_atime=$false;encode_workers=1;decode_workers=1})
$referenceProtocol=@{schema=1;protocol='khc-mac-canterbury-reference-v1';task='goal-restore-20261019';host='m3mb14';root=$activation.root;run='mac-canterbury-reference-20261026';purpose='training-reference-only';superiority_decision_allowed=$false;windows_max_bytes=8MB;windows_max_entries=96;windows_timeout_seconds=1800;remote_max_bytes=160MB;remote_max_entries=512;campaign_seconds=1700;encode_seconds=60;decode_seconds=20;cpu_baseline_limit_percent=15;cpu_interval_limit_percent=30;thermal_state_required=0;ac_power_required=$true;rss_eligibility_bytes=128MB;cpu_per_wall_eligibility_max=1.2;warmups=1;orders=@('ABC','BCA','CAB','ACB','CBA','BAC');method_profiles=$referenceProfiles;source_sha256=$amendmentSpec.source_sha256;cli_sha256=$psFreeProtocol.cli_sha256;sevenzip_sha256=('a'*64);e2e_passed_receipt_sha256='0f9b1a1cb744775b64c7cdcbb485efebb2e5f4ba2cf0d58c99ee903255676299';input_manifest_sha256=('b'*64);input_zip_sha256=('c'*64);endpoint_sha256=('d'*64);measurement_sha256=('e'*64);system_metrics_sha256=('f'*64);reason='canterbury-training-reference-pilot-no-superiority-decision'}
Accept 'reference fixed 35-field preregistered protocol' {Assert-KhcMacReferenceProtocolData $referenceProtocol}
foreach($case in @('superiority','purpose','resource','workers','warmup','orders','baseline','ratio','artifact','extra')){Reject "reference protocol $case" {$p=Copy-Data $referenceProtocol;switch($case){superiority {$p.superiority_decision_allowed=$true};purpose {$p.purpose='holdout'};resource {$p.remote_max_bytes++};workers {$p.method_profiles[1].encode_workers=2};warmup {$p.warmups=2};orders {$p.orders=@('BCA','ABC','CAB','ACB','CBA','BAC')};baseline {$p.cpu_baseline_limit_percent=16};ratio {$p.cpu_per_wall_eligibility_max=1.21};artifact {$p.measurement_sha256='bad'};extra {$p.other=1}};Assert-KhcMacReferenceProtocolData $p}}
$canterbury=Get-KhcPortfolioInputProfile 'CanterburyDevelopmentKcs1CountLength20261020'
$referenceManifest=@{schema=1;corpus='Canterbury11';purpose='training-reference-only';files=11;bytes=2810784;manifest_sha256=$canterbury.ManifestSha256;source_container_sha256=$canterbury.ZipSha256;entries=@($canterbury.Entries | ForEach-Object {@{name=$_.name;bytes=$_.bytes;sha256=$_.sha256}})}
Accept 'reference 11 input metadata rows match source profile and ordinal digest' {Assert-KhcMacReferenceManifestData $referenceManifest}
foreach($case in @('purpose','count','size','name','digest','duplicate')){Reject "reference manifest $case" {$m=Copy-Data $referenceManifest;switch($case){purpose {$m.purpose='holdout'};count {$m.files=12};size {$m.entries[0].bytes++};name {$m.entries[0].name='other'};digest {$m.manifest_sha256='0'*64};duplicate {$m.entries[1]=Copy-Data $m.entries[0]}};Assert-KhcMacReferenceManifestData $m}}
foreach($name in @('Assert-KhcMacReferenceMetricData','Assert-KhcMacReferenceReportData','Assert-KhcMacReferenceReceiptData')){$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false);if($null -eq $f){throw "Missing reference result validator: $name"};. ([scriptblock]::Create($f.Extent.Text))}
$metric=@{elapsed_ns=1000000000L;user_seconds=0.3;system_seconds=0.2;peak_rss_bytes=64MB;cpu_per_wall=0.5;normal_exit=$true;exit_code=0;signal=$null;cpu_interval_percent=20.0;environment_before=@{schema=1;cpu_ticks=@(100,100,700,100);logical_cpus=14;thermal_state=0;ac_power=$true};environment_after=@{schema=1;cpu_ticks=@(110,110,780,100);logical_cpus=14;thermal_state=0;ac_power=$true}}
$referenceTrials=@();$methodMap=@{A='khc';B='lzma2';C='ppmd'}
$orders=@('ABC')+@($referenceProtocol.orders)
for($round=0;$round -lt 7;$round++){for($position=0;$position -lt 3;$position++){$method=$methodMap[[string]$orders[$round][$position]];$referenceTrials+=@{method=$method;warmup=($round -eq 0);round=$round-1;position=$position;archive_bytes=1000;archive_sha256=('a'*64);restored_manifest_sha256=$referenceManifest.manifest_sha256;encode=(Copy-Data $metric);decode=(Copy-Data $metric)}}}
$referenceReport=@{schema=1;purpose='training-reference-only';superiority_decision_allowed=$false;reason=$referenceProtocol.reason;windows_run_id=('a'*32);protocol_sha256=('f'*64);source_sha256=$referenceProtocol.source_sha256;cli_sha256=$referenceProtocol.cli_sha256;sevenzip_sha256=$referenceProtocol.sevenzip_sha256;e2e_passed_receipt_sha256=$referenceProtocol.e2e_passed_receipt_sha256;input_manifest_sha256=$referenceProtocol.input_manifest_sha256;input_zip_sha256=$referenceProtocol.input_zip_sha256;input_files=11;input_bytes=2810784;rss_unit='bytes';time_scope='CLI spawn-to-wait4 including launch and scheduling';cpu_observation='host-tick interval averages before/after each CLI';trials=$referenceTrials;status='completed-reference';error=$null}
Accept 'reference complete 21 normal pairs with fixed Latin orders and prerequisites' {Assert-KhcMacReferenceReportData $referenceReport $referenceProtocol ('f'*64) ('a'*32) $referenceManifest}
foreach($case in @('superiority','order','count','rss','ratio','ratio-recompute','cpu','thermal','ac','signal','archive-size','restore','unit')){Reject "reference report $case" {$r=Copy-Data $referenceReport;switch($case){superiority {$r.superiority_decision_allowed=$true};order {$r.trials[3].method='ppmd'};count {$r.trials=@($r.trials[0..19])};rss {$r.trials[0].encode.peak_rss_bytes=129MB};ratio {$r.trials[0].encode.cpu_per_wall=1.21;$r.trials[0].encode.user_seconds=1.01;$r.trials[0].encode.system_seconds=0.2};ratio-recompute {$r.trials[0].encode.cpu_per_wall=0.8};cpu {$r.trials[0].encode.cpu_interval_percent=40};thermal {$r.trials[0].encode.environment_after.thermal_state=1};ac {$r.trials[0].encode.environment_before.ac_power=$false};signal {$r.trials[0].encode.signal=9};archive-size {$r.trials[3].archive_bytes++};restore {$r.trials[0].restored_manifest_sha256='0'*64};unit {$r.rss_unit='KiB'}};Assert-KhcMacReferenceReportData $r $referenceProtocol ('f'*64) ('a'*32) $referenceManifest}}
Accept 'stopped prefix permits only final normal pair eligibility failure' {$r=Copy-Data $referenceReport;$r.status='stopped';$r.error='RSS eligibility';$r.trials=@($r.trials[0..2]);$r.trials[2].encode.peak_rss_bytes=129MB;Assert-KhcMacReferenceReportData $r $referenceProtocol ('f'*64) ('a'*32) $referenceManifest}
Reject 'stopped prefix cannot hide an earlier eligibility failure' {$r=Copy-Data $referenceReport;$r.status='stopped';$r.error='stop';$r.trials=@($r.trials[0..2]);$r.trials[0].encode.peak_rss_bytes=129MB;Assert-KhcMacReferenceReportData $r $referenceProtocol ('f'*64) ('a'*32) $referenceManifest}
$referenceReportBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $referenceReport -Depth 30 -Compress))
$referenceReceipt=@{schema=1;protocol='khc-mac-canterbury-reference-terminal-v1';windows_run_id=('a'*32);protocol_sha256=('f'*64);purpose='training-reference-only';superiority_decision_allowed=$false;reason=$referenceProtocol.reason;children_absent=$true;exit=0;status='completed-reference';report_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($referenceReportBytes)).ToLowerInvariant();report_base64=[Convert]::ToBase64String($referenceReportBytes);error=$null}
foreach($key in @('endpoint_sha256','measurement_sha256','system_metrics_sha256','input_manifest_sha256','input_zip_sha256','source_sha256','cli_sha256','sevenzip_sha256','e2e_passed_receipt_sha256')){$referenceReceipt[$key]=$referenceProtocol[$key]}
Accept 'reference canonical terminal binds report raw bytes' {$null=Assert-KhcMacReferenceReceiptData $referenceReceipt $referenceProtocol ('f'*64) ('a'*32) $referenceManifest}
Reject 'reference terminal without group absence never seals' {$r=Copy-Data $referenceReceipt;$r.children_absent=$false;$null=Assert-KhcMacReferenceReceiptData $r $referenceProtocol ('f'*64) ('a'*32) $referenceManifest}
Accept 'failed reference with no report is cleanup-only terminal' {$r=Copy-Data $referenceReceipt;$r.status='failed';$r.exit=1;$r.error='helper failed';$r.report_sha256=$null;$r.report_base64=$null;$null=Assert-KhcMacReferenceReceiptData $r $referenceProtocol ('f'*64) ('a'*32) $referenceManifest}
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-KhcMacReferenceSealState'},$false);if($null -eq $f){throw 'Missing independent reference seal validator'};. ([scriptblock]::Create($f.Extent.Text))
Reject 'reference private classification cannot lose registration' {Assert-KhcMacReferenceSealState $true $false $false}
Reject 'reference public receipt cannot replace private terminal seal' {Assert-KhcMacReferenceSealState $true $true $false -RequireSeal}
Accept 'reference sealed state remains independent from native E2E' {Assert-KhcMacReferenceSealState $true $true $true -RequireSeal}
Reject 'actual completion path refuses missing reference seal' {$script:mockReferenceRequired=$true;$script:mockReferenceSealMissing=$true;$null=Test-KhcRecycleV6Completed $completedLocation ('a'*32) $completedRecord $completedRequest $completedPublic}
Accept 'actual completion path accepts present reference seal' {$script:mockReferenceSealMissing=$false;$result=Test-KhcRecycleV6Completed $completedLocation ('a'*32) $completedRecord $completedRequest $completedPublic;if($result.State -cne 'completed-receipts-verified'){throw 'Reference completion changed'}}
[pscustomobject]@{state='passed';cases=$script:passed;side_effects='none; AST-only functions, existing probe reads and in-memory tree/budget/ledger DTOs'} | ConvertTo-Json -Compress
