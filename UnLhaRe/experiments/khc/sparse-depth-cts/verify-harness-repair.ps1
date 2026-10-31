#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-sparse-depth-cts-20261001-harness-repair'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$owned=[Collections.Generic.List[string]]::new()
function No-Reparse([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse rejected: $p"};$p=[IO.Path]::GetDirectoryName($p)}
}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Hold([string]$Path,[string]$Role,[string]$Expected=''){
    No-Reparse $Path;$locks.Add([IO.File]::Open($Path,'Open','Read','Read'))
    $id=Identity $Path;if($Expected -and $id.sha256 -cne $Expected){throw "Pin mismatch: $Path"}
    $ids.Add([pscustomobject]@{role=$Role;path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null});$id
}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()};$owned.Add($Path)}
function Check([string]$Name){$checks.Add([pscustomobject]@{name=$Name;passed=$true})}
function Same-Bytes([string]$Left,[string]$Right){
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Left)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($Right))){throw "Full byte mismatch: $Left / $Right"}
}
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$Expected=0){
    $row=[ordered]@{program=$Program;argv=$Argv;exit=$null;expected_exit=$Expected;timeout=$false;stdout='';stderr=''};$calls.Add($row)
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($arg in $Argv){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$outTask=$null;$errTask=$null
    try{
        $started=$p.Start();if(-not $started){throw 'Child start failed'}
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(120000)){$row.timeout=$true;throw '120s child timeout'}
        $row.stdout=$outTask.GetAwaiter().GetResult();$row.stderr=$errTask.GetAwaiter().GetResult();$row.exit=$p.ExitCode
        if($row.exit -ne $Expected -or ($Expected -eq 0 -and $row.stderr) -or ($Expected -ne 0 -and $row.stdout)){throw 'Unexpected child exit/output'}
        [pscustomobject]$row
    }finally{
        if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()}
        if($null -ne $outTask){$row.stdout=$outTask.GetAwaiter().GetResult()};if($null -ne $errTask){$row.stderr=$errTask.GetAwaiter().GetResult()};if($started){$row.exit=$p.ExitCode};$p.Dispose()
    }
}
function Refuse([string]$Exe,[string]$InputPath,[string]$OutputPath,[string]$Reason){
    $row=Invoke-Child $Exe @($InputPath,$OutputPath) 1
    if($row.stderr -notmatch $Reason -or (Test-Path -LiteralPath $OutputPath)){throw "Refusal/publication mismatch: $Reason"}
    Check "refusal-$([IO.Path]::GetFileNameWithoutExtension($InputPath))-$([IO.Path]::GetFileName($Exe))"
}
function Audit-Check([object]$Audit,[bool]$Reference,[int]$Budget){
 $fields=@('events','processed','replayed','active_events','activations','deactivations','forced','reference_checks','pending')
 foreach($field in $fields){if($Audit.$field.Count -ne 7 -or @($Audit.$field | Where-Object {$_ -lt 0}).Count){throw 'Audit class fields invalid'}}
 if($Audit.maximum_records -ne $Budget -or $Audit.reserved_records -gt $Budget -or $Audit.peak_reserved_records -gt $Budget -or $Audit.peak_reserved_records -lt $Audit.reserved_records -or ($Audit.pending | Measure-Object -Sum).Sum -gt $Audit.reserved_records){throw 'Journal budget audit mismatch'}
 for($c=0;$c -lt 7;$c++){
  if($Audit.processed[$c]+$Audit.pending[$c] -ne $Audit.events[$c] -or $Audit.replayed[$c]+$Audit.active_events[$c] -ne $Audit.processed[$c] -or $Audit.processed[$c] -gt $Audit.events[$c] -or $Audit.forced[$c] -gt $Audit.activations[$c] -or $Audit.deactivations[$c] -gt $Audit.activations[$c]){throw 'Prefix/update accounting mismatch'}
  if(($Reference -and $Audit.reference_checks[$c] -ne $Audit.active_events[$c]) -or (-not $Reference -and $Audit.reference_checks[$c] -ne 0)){throw 'Reference coverage mismatch'}
 }
}
function Audit-Key([object]$Audit){
 $result=[ordered]@{}
 foreach($field in @('events','processed','replayed','active_events','activations','deactivations','forced','pending','reserved_records','peak_reserved_records','maximum_records')){$result[$field]=$Audit.$field}
 $result | ConvertTo-Json -Depth 4 -Compress
}
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;size_result=$null;fixed_schedule=$null;small_journal_schedule=$null;inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;limitations=@('Finite CLI E2E and continuous Q15 reference, not independent numeric oracle or every hidden state/error proof.','Native/forcedportable Windows x64 only; f64 gain/primary/bayes portability remains unproven.','New research model and magic; not old-frame-compatible optimization or product parent-handle race-safety evidence.','Logical journal capacity is bounded, not a hard process memory limit or measured peak memory.','No speed, holdout, product adoption or general 7-Zip superiority claim.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"sparse-depth-cts","retain":"finite CLI E2E, reference and small-journal artifacts, sources and terminal report"}'))
try{
 $pins=[ordered]@{
 'experiments/khc/SPARSE_DEPTH_CTS_CONTRACT_20261001.md'='9BF4D51256A929EFFED842E5157D211D48466EA74BD9E411B64735B6B1C2738C'
 'experiments/khc/sparse-depth-cts/codec.rs'='ED8E141086DD637277476C31D138603F64EF43E3E1553D5EC3D29FC27C74D7CA'
 'experiments/khc/sparse-depth-cts/scheduler.rs'='7246DDCF19668DF1D2E8BF41E765950C1591F929FF43B1EAAB41432362FA0DB4'
 'experiments/khc/sparse-depth-cts/bayes_model.rs'='881CFFC59A8DEEDB0F57563AAF195539E6C3626CBDC3246EE396AF32B5B5F15F'
 'experiments/khc/sparse-depth-cts/correspondence.json'='54EBFF315AD1CB985AFE653EB3B8A6F494F443B2D63444AC04DD0CCB0B158709'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/cts_model.rs'='ACEAA15363123470FA09481BF6408FF2BDFF95A15D65489D64A9998B8E26F6C7'
 'experiments/khc/adaptive-suffix-kt/cts_model.rs'='F6E6BABE00ECB2063117D554135E8ED6F13B3B458E4FBCFA7D4B0596C6CCBB32'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/exact_kt.rs'='4DC85F126E3813531337036A6A3C4B048B1B256645A3E58A60469170383A0B61'
 'experiments/khc/native32-quotient/exact_div.rs'='338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
 'experiments/khc/causal-bayes-log-table/bayes_model.rs'='E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'
 'experiments/khc/causal-bayes-sais/bwt.rs'='810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
 'experiments/khc/rejected-binary-mix/packed_alphabet.rs'='4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
 'experiments/khc/range.rs'='1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
 'build/khc-current-source-native-solid-20260923-group/all.group'='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
 'build/khc-suffix-class-entropy-20261001/report.json'='CB1FD14D1FD8E5BE169D2ECFBF7D4F7D419C2D3EA65FE3F122727D4A913B3BC4'
 'build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/codec-native.exe'='74704D097CC6D70E531086DE73A3311716E1C3F96CEB62F6A5794067331B99FE'
 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'='7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
 }
 $pins['experiments/khc/sparse-depth-cts/cts_model.rs']='2F568F743456E36DA50A30BD922E839BA9478A5E11FD77CD8BFC1B69988A8A30'
 $pins['experiments/khc/sparse-depth-cts/context_audit.rs']='78E2F8943E6260695DD7B4A80C48A6C9666A9A5C62A12CD2E00FDF5DAB178123'
 $pins['experiments/khc/causal-expert-scheduling/scheduler.rs']='7207E2467E7C0FCDA699D62DBB8D906770A4EB3AB6EED16EC6801DAB5918000D'
 $pins['experiments/khc/causal-expert-scheduling/verify.ps1']='99CB9966342207F8B4DFC8AE02B6D1F32459343C4216F02A4EA09BE179CAD4C0'
 $pins['build/khc-causal-expert-scheduling-20261001/report.json']='370534F32A979FE2768CD60C29DFBD8342CD7B358C15C4D510945B8F8DD35E7A'
 $pins['build/khc-causal-expert-scheduling-20261001/codec-native.exe']='0737E2FFD936ECD89EA2FD4F8907AC0CD6C0766072BCE56CBB65AABDA7C981EA'
 $pins['build/khc-causal-expert-scheduling-20261001/fixed-native.frame']='CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12'
 $pins['experiments/khc/sparse-depth-cts/verify.ps1']='25E20785438C89199271534855F2FB2321A9184062098C5743EC0A3BD42F466C'
 foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'source-dependency-contract-or-input' $pin.Value}
 $null=Hold $PSCommandPath 'verifier';$null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
 $mapping=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw | ConvertFrom-Json
 $old=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../causal-bayes-q32-kt-reciprocal/codec.rs')).Replace("`r`n","`n")
 foreach($change in $mapping.codec_changes){if($old.Split([string[]]@($change.from),[StringSplitOptions]::None).Length-1 -ne $change.count){throw 'Wrapper marker count differs'};$old=$old.Replace($change.from,$change.to)}
 $new=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'codec.rs')).Replace("`r`n","`n")
 if($old.TrimEnd([char]10) -cne $new.TrimEnd([char]10)){throw 'Wrapper full source correspondence differs'}
 $oldBayes=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../causal-bayes-log-table/bayes_model.rs')).Replace("`r`n","`n")
 $expectedBayes=$oldBayes.Replace('    pub(super) fn predict(&self, class: u32, primary: u16, cts: u16)',$mapping.bayes_insertion+'    pub(super) fn predict(&self, class: u32, primary: u16, cts: u16)')
 $actualBayes=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bayes_model.rs')).Replace("`r`n","`n")
 if($expectedBayes.TrimEnd([char]10) -cne $actualBayes.TrimEnd([char]10)){throw 'Bayes getter-only correspondence differs'}
 Check 'wrapper-and-bayes-full-source-correspondence'
 $oldHeavy=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../causal-bayes-q32-kt-reciprocal/cts_model.rs')).Replace("`r`n","`n")
 foreach($change in $mapping.heavy_changes){if($oldHeavy.Split([string[]]@($change.from),[StringSplitOptions]::None).Length-1 -ne $change.count){throw 'Heavy marker count differs'};$oldHeavy=$oldHeavy.Replace($change.from,$change.to)}
 $newHeavy=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'cts_model.rs')).Replace("`r`n","`n")
 if($oldHeavy.TrimEnd([char]10) -cne $newHeavy.TrimEnd([char]10)){throw 'Sparse heavy full source correspondence differs'};Check 'sparse-heavy-full-source-correspondence'
 $oldScheduler=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../causal-expert-scheduling/scheduler.rs')).Replace("`r`n","`n")
 $change=$mapping.scheduler_change
 if($oldScheduler.Split([string[]]@($change.from),[StringSplitOptions]::None).Length-1 -ne $change.count){throw 'Scheduler marker count differs'}
 $expectedScheduler=$oldScheduler.Replace($change.from,$change.to)
 $actualScheduler=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'scheduler.rs')).Replace("`r`n","`n")
 if($expectedScheduler.TrimEnd([char]10) -cne $actualScheduler.TrimEnd([char]10)){throw 'Scheduler routing/source correspondence differs'};Check 'scheduler-model-route-only-correspondence'
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Verifier syntax invalid'}
 $null=Invoke-Child $compiler @('--version','--verbose')
 $contextExe=Join-Path $work 'context-audit.exe';$contextRecords=Join-Path $work 'context-records.bin'
 $null=Invoke-Child $compiler @('--edition=2024','-C','panic=abort','-C','opt-level=3','--cfg','khc_sparse_context_audit',(Join-Path $PSScriptRoot 'context_audit.rs'),'-o',$contextExe)
 $owned.Add($contextExe);$null=Hold $contextExe 'compiled-context-audit'
 $contextRow=Invoke-Child $contextExe @($contextRecords);$context=$contextRow.stdout|ConvertFrom-Json
 if($context.histories -ne 65536 -or $context.records -ne 393216 -or $context.record_bytes -ne 12 -or $context.nodes -ne 65815 -or $context.levels -ne 6 -or $context.node_bytes -ne 16 -or $context.prediction_bytes -ne 192 -or $context.invalid_levels_rejected -ne 2 -or (Get-Item -LiteralPath $contextRecords).Length -ne 4718592){throw 'Sparse context mapping/layout evidence differs'}
 $owned.Add($contextRecords);$contextIdentity=Hold $contextRecords 'context-mapping-records';$report['context_mapping']=[ordered]@{summary=$context;records=Identity $contextRecords}
 Check 'all-16bit-histories-six-depth-context-mapping'
 $null=Invoke-Child $contextExe @($contextRecords) 1
 if((Identity $contextRecords).sha256 -cne $contextIdentity.sha256){throw 'Mapping no-clobber failed'};Check 'context-audit-create-new-no-clobber'
 $null=Invoke-Child $contextExe @() 1;Check 'context-audit-invalid-arguments'
 $executables=@()
 foreach($mode in @('native','portable','reference','small-reference')){
  $exe=Join-Path $work "codec-$mode.exe"
  $argv=@('--edition=2024','-C','panic=abort','-C','opt-level=3')
  if($mode -eq 'portable'){$argv+=@('--cfg','khc_force_portable')}
  if($mode -like '*reference'){$argv+=@('--cfg','khc_scheduler_reference')}
  if($mode -eq 'small-reference'){$argv+=@('--cfg','khc_scheduler_small_journal')}
  $argv+=@((Join-Path $PSScriptRoot 'codec.rs'),'-o',$exe)
  $null=Invoke-Child $compiler $argv;$owned.Add($exe);$null=Hold $exe 'compiled-codec'
  $executables+=@{path=$exe;mode=$mode;reference=($mode -like '*reference')}
 }
 $group=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
 if((Get-Item -LiteralPath $group).Length -ne 2811006){throw 'Fixed input length differs'}
 $fixtures=[ordered]@{empty=[byte[]]@();single=[byte[]]@(42);all_bytes=[byte[]](0..255);repeated=[byte[]]::new(8192);periodic=[byte[]]::new(16384);seeded_random=[byte[]]::new(8192)}
 [Array]::Fill($fixtures.repeated,[byte]65)
 for($i=0;$i -lt $fixtures.periodic.Length;$i++){$fixtures.periodic[$i]=[byte](@(0,1,2,255,3,3,7,8,0,13,27)[$i%11])}
 [Random]::new(20260930).NextBytes($fixtures.seeded_random)
 foreach($case in @($fixtures.Keys)+@('fixed')){
  $fixture=if($case -eq 'fixed'){$group}else{Join-Path $work "$case.input"}
  if($case -ne 'fixed'){Write-New $fixture $fixtures[$case];$null=Hold $fixture 'input'}
  $nativeFrame=$null;$nativeAudit=$null
  foreach($entry in $executables | Where-Object {$_.mode -ne 'small-reference'}){
   $frame=Join-Path $work "$case-$($entry.mode).frame";$restore=Join-Path $work "$case-$($entry.mode).restore"
   $row=Invoke-Child $entry.path @('encode',$fixture,$frame)
   $encoded=$row.stdout | ConvertFrom-Json;Audit-Check $encoded.scheduling $entry.reference 8388608
   $owned.Add($frame);$null=Hold $frame 'encoded-frame'
   $row=Invoke-Child $entry.path @('decode',$frame,$restore)
   $decoded=$row.stdout | ConvertFrom-Json;Audit-Check $decoded.scheduling $entry.reference 8388608
   $owned.Add($restore);$null=Hold $restore 'restored-input'
   Same-Bytes $fixture $restore
   if((Audit-Key $encoded.scheduling) -cne (Audit-Key $decoded.scheduling) -or ($encoded.scheduling.reference_checks | ConvertTo-Json -Compress) -cne ($decoded.scheduling.reference_checks | ConvertTo-Json -Compress)){throw 'Encode/decode schedule or reference differs'}
   Check "$case-$($entry.mode)-roundtrip-and-schedule"
   if($entry.mode -eq 'native'){
    $nativeFrame=$frame;$nativeAudit=Audit-Key $encoded.scheduling
    if($case -eq 'fixed'){$report.fixed_schedule=$encoded.scheduling;if(($encoded.scheduling.events | Measure-Object -Sum).Sum -ne 7622618){throw 'Fixed grammar bit total differs'}}
   }else{
    Same-Bytes $nativeFrame $frame
    if((Audit-Key $encoded.scheduling) -cne $nativeAudit){throw 'Native/portable/reference routing differs'}
    Check "$case-$($entry.mode)-native-frame-and-schedule"
   }
  }
 }
 $exe=$executables[0].path;$fixed=Join-Path $work 'fixed-native.frame'
 $repeat=Join-Path $work 'fixed-native-repeat.frame';$repeatRestore=Join-Path $work 'fixed-native-repeat.restore'
 $row=Invoke-Child $exe @('encode',$group,$repeat);$repeated=$row.stdout | ConvertFrom-Json;Audit-Check $repeated.scheduling $false 8388608
 $owned.Add($repeat);$null=Hold $repeat 'repeat-frame'
 $row=Invoke-Child $exe @('decode',$repeat,$repeatRestore);$repeatedDecode=$row.stdout | ConvertFrom-Json;Audit-Check $repeatedDecode.scheduling $false 8388608
 $owned.Add($repeatRestore);$null=Hold $repeatRestore 'repeat-restore'
 Same-Bytes $fixed $repeat;Same-Bytes $group $repeatRestore
 if((Audit-Key $report.fixed_schedule) -cne (Audit-Key $repeated.scheduling) -or (Audit-Key $repeated.scheduling) -cne (Audit-Key $repeatedDecode.scheduling)){throw 'Repeated schedule differs'}
 Check 'fixed-repeat-frame-restore-and-schedule'
 $small=$executables | Where-Object {$_.mode -eq 'small-reference'}
 $smallInput=Join-Path $work 'seeded_random.input';$smallFrame=Join-Path $work 'small-journal.frame';$smallRestore=Join-Path $work 'small-journal.restore'
 $row=Invoke-Child $small.path @('encode',$smallInput,$smallFrame);$smallEncode=$row.stdout | ConvertFrom-Json;Audit-Check $smallEncode.scheduling $true 64
 $owned.Add($smallFrame);$null=Hold $smallFrame 'small-journal-frame'
 $row=Invoke-Child $small.path @('decode',$smallFrame,$smallRestore);$smallDecode=$row.stdout | ConvertFrom-Json;Audit-Check $smallDecode.scheduling $true 64
 $owned.Add($smallRestore);$null=Hold $smallRestore 'small-journal-restore'
 Same-Bytes $smallInput $smallRestore
 if((Audit-Key $smallEncode.scheduling) -cne (Audit-Key $smallDecode.scheduling) -or ($smallEncode.scheduling.forced | Measure-Object -Sum).Sum -le 0 -or ($smallEncode.scheduling.reference_checks | Measure-Object -Sum).Sum -le 0){throw 'Forced catch-up unverified'}
 $report.small_journal_schedule=$smallEncode.scheduling;Check 'forced-small-journal-roundtrip-continuous-reference'
 foreach($cross in @(@{exe=$exe;frame=$smallFrame;label='small-by-normal'},@{exe=$small.path;frame=$fixed;label='normal-by-small'})){
  $out=Join-Path $work "$($cross.label).rejected";$row=Invoke-Child $cross.exe @('decode',$cross.frame,$out) 1
  if($row.stderr -notmatch 'magic' -or (Test-Path -LiteralPath $out)){throw 'Small journal magic rejection differs'};Check "$($cross.label)-magic-refusal"
 }
 $scheduledExe=Join-Path $root 'build/khc-causal-expert-scheduling-20261001/codec-native.exe'
 $scheduledFrame=Join-Path $root 'build/khc-causal-expert-scheduling-20261001/fixed-native.frame'
 foreach($cross in @(@{exe=$exe;frame=$scheduledFrame;label='scheduled-by-sparse'},@{exe=$scheduledExe;frame=$fixed;label='sparse-by-scheduled'})){
  $out=Join-Path $work "$($cross.label).rejected";$row=Invoke-Child $cross.exe @('decode',$cross.frame,$out) 1
  if($row.stderr -notmatch 'magic' -or (Test-Path -LiteralPath $out)){throw 'Scheduled/sparse magic refusal differs'};Check "$($cross.label)-format-refusal"
 }
 $raw=[IO.File]::ReadAllBytes($fixed);$bad=[ordered]@{}
 $bad.magic=$raw.Clone();$bad.magic[0]=$bad.magic[0] -bxor 1
 $bad.header_crc=$raw.Clone();$bad.header_crc[32]=$bad.header_crc[32] -bxor 1
 $bad.payload_crc=$raw.Clone();$bad.payload_crc[-1]=$bad.payload_crc[-1] -bxor 1
 $bad.truncated=$raw[0..($raw.Length-2)];$bad.trailing=[byte[]]($raw+@(0))
 foreach($name in $bad.Keys){$inputPath=Join-Path $work "$name.bad";$outputPath=Join-Path $work "$name.rejected";Write-New $inputPath $bad[$name];$null=Hold $inputPath 'malformed-frame';$null=Invoke-Child $exe @('decode',$inputPath,$outputPath) 1;if(Test-Path -LiteralPath $outputPath){throw 'Malformed frame published'};Check "$name-refused"}
 $oldExe=Join-Path $root 'build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/codec-native.exe'
 $oldFrame=Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'
 foreach($cross in @(@{exe=$exe;frame=$oldFrame;label='old-by-new'},@{exe=$oldExe;frame=$fixed;label='new-by-old'})){$out=Join-Path $work "$($cross.label).rejected";$row=Invoke-Child $cross.exe @('decode',$cross.frame,$out) 1;if($row.stderr -notmatch 'magic' -or (Test-Path -LiteralPath $out)){throw 'Old/new magic refusal differs'};Check "$($cross.label)-format-refusal"}
 foreach($operation in @('encode','decode')){
  $inputPath=if($operation -eq 'encode'){Join-Path $work 'single.input'}else{Join-Path $work 'single-native.frame'}
  $sentinel=Join-Path $work "$operation.existing";Write-New $sentinel ([byte[]]@(12,34,56))
  $null=Invoke-Child $exe @($operation,$inputPath,$sentinel) 1
  if([Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel)) -cne [Convert]::ToBase64String([byte[]]@(12,34,56))){throw 'Existing output changed'}
  $null=Hold $sentinel 'no-clobber-sentinel';Check "$operation-no-clobber"
 }
 $missingOutput=Join-Path $work 'missing.rejected';$null=Invoke-Child $exe @('encode',(Join-Path $work 'missing.input'),$missingOutput) 1;if(Test-Path -LiteralPath $missingOutput){throw 'Missing input published'};Check 'missing-input-refused'
 $report.size_result=[ordered]@{input=Identity $group;old=Identity $oldFrame;candidate=Identity $fixed;maximum_archive_bytes=483599;passed=([IO.FileInfo]$fixed).Length -le 483599;delta_vs_old_bytes=([IO.FileInfo]$fixed).Length-([IO.FileInfo]$oldFrame).Length;timing_used=$false}
 $report.status=if($report.size_result.passed){'correctness_and_size_passed_not_timed'}else{'correctness_passed_size_no_go_not_timed'}
}catch{$failure=$_;$report.error=$_.Exception.Message}
finally{
 foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $after.bytes -or $id.before_sha256 -cne $after.sha256){throw 'Held file changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join ';';if($null -eq $failure){$failure=$_}}}
 foreach($held in $locks){$held.Dispose()}
 $items=@(Get-ChildItem -LiteralPath $work -Force -Recurse);$report.inventory=@($items | Select-Object FullName,Length,Attributes)
 $report.owned_tmp_count=@($items | Where-Object {$_.Name -like '*.tmp'}).Count;$report.owned_reparse_count=@($items | Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}).Count
 if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join ';'}
 $report.completed_utc=[DateTime]::UtcNow.ToString('o')
 Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure};if($report.status -eq 'failed'){throw $report.error}
[pscustomobject]@{status=$report.status;checks=$checks.Count;cli_calls=$calls.Count;identities=$ids.Count;size=$report.size_result;fixed_schedule=$report.fixed_schedule;small_journal_schedule=$report.small_journal_schedule;tmp=$report.owned_tmp_count;reparse=$report.owned_reparse_count}|ConvertTo-Json -Depth 5
