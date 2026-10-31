#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-adaptive-suffix-kt-20261001'
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
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;size_result=$null;inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;limitations=@('Finite Windows x64 native/forcedportable CLI E2E only; no independent numeric oracle or full Model history verification.','This is a new probability model/research magic, not old CTS-compatible optimization.','No speed, peak-memory, holdout, ARM64/macOS or product adoption evidence.','Research path checks/publication do not prove product parent-handle race safety.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"adaptive-suffix-kt","retain":"source/binary/input/frame/restore/terminal report for one fixed size experiment"}'))
try{
 $pins=[ordered]@{
 'experiments/khc/ADAPTIVE_SUFFIX_KT_CONTRACT_20261001.md'='9A05CFE348AC3C2CB63EA3D30E3ACA26B037E83A30AED3568B665850FD053CFC'
 'experiments/khc/adaptive-suffix-kt/codec.rs'='B45F257D723478DA4C2D3FF0A8467BB8FB6A20CF18047CFF9575FAD3A110E78C'
 'experiments/khc/adaptive-suffix-kt/cts_model.rs'='F6E6BABE00ECB2063117D554135E8ED6F13B3B458E4FBCFA7D4B0596C6CCBB32'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/exact_kt.rs'='4DC85F126E3813531337036A6A3C4B048B1B256645A3E58A60469170383A0B61'
 'experiments/khc/native32-quotient/exact_div.rs'='338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
 'experiments/khc/causal-bayes-log-table/bayes_model.rs'='E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'
 'experiments/khc/causal-bayes-sais/bwt.rs'='810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
 'experiments/khc/rejected-binary-mix/packed_alphabet.rs'='4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
 'experiments/khc/range.rs'='1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
 'build/khc-current-source-native-solid-20260923-group/all.group'='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
 'build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/codec-native.exe'='74704D097CC6D70E531086DE73A3311716E1C3F96CEB62F6A5794067331B99FE'
 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'='7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
 }
 $frozenFrame=Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'
 foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'source-dependency-contract-or-input' $pin.Value}
 $null=Hold $PSCommandPath 'verifier'
 $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
 $old=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../causal-bayes-q32-kt-reciprocal/codec.rs')).Replace("`r`n","`n").TrimEnd([char]10)
 $new=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'codec.rs')).Replace("`r`n","`n").TrimEnd([char]10)
 $expected=$old.Replace('//! 凍結primary/BWT/grammarとD16/Q32 CTS、因果的Bayesの全frame研究codec。','//! 凍結primary/BWT/grammarと適応suffix KT、因果的Bayesの別形式研究codec。').Replace('//! KHBAYQ32 /','//! KHBADP01 /').Replace('const MAGIC: &[u8; 8] = b"KHBAYQ32";','const MAGIC: &[u8; 8] = b"KHBADP01";')
 if($expected -cne $new){throw 'Wrapper correspondence mismatch'}
 Check 'wrapper-correspondence-comments-and-magic-only'
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Verifier syntax invalid'}
 $null=Invoke-Child $compiler @('--version','--verbose')
 $executables=@()
 foreach($portable in @($false,$true)){
  $mode=if($portable){'portable'}else{'native'}
  $exe=Join-Path $work "codec-$mode.exe"
  $argv=@('--edition=2024','-C','panic=abort','-C','opt-level=3')
  if($portable){$argv+=@('--cfg','khc_force_portable')}
  $argv+=@((Join-Path $PSScriptRoot 'codec.rs'),'-o',$exe)
  $null=Invoke-Child $compiler $argv
  $owned.Add($exe);$null=Hold $exe 'compiled-codec';$executables+=@{path=$exe;mode=$mode}
 }
 $group=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
 if((Get-Item -LiteralPath $group).Length -ne 2811006){throw 'Group length mismatch'}
 $fixtures=[ordered]@{empty=[byte[]]@();single=[byte[]]@(42);all_bytes=[byte[]](0..255);repeated=[byte[]]::new(8192);periodic=[byte[]]::new(16384);seeded_random=[byte[]]::new(8192)}
 [Array]::Fill($fixtures.repeated,[byte]65)
 for($i=0;$i -lt $fixtures.periodic.Length;$i++){$fixtures.periodic[$i]=[byte](@(0,1,2,255,3,3,7,8,0,13,27)[$i%11])}
 [Random]::new(20260930).NextBytes($fixtures.seeded_random)
 foreach($case in @($fixtures.Keys)+@('fixed')){
  $fixture=if($case -eq 'fixed'){$group}else{Join-Path $work "$case.input"}
  if($case -ne 'fixed'){Write-New $fixture $fixtures[$case];$null=Hold $fixture 'input'}
  $nativeFrame=$null
  foreach($entry in $executables){
   $frame=Join-Path $work "$case-$($entry.mode).frame";$restored=Join-Path $work "$case-$($entry.mode).restore"
   $null=Invoke-Child $entry.path @('encode',$fixture,$frame);$owned.Add($frame);$null=Hold $frame 'encoded-frame'
   $null=Invoke-Child $entry.path @('decode',$frame,$restored);$owned.Add($restored);$null=Hold $restored 'restored-input'
   Same-Bytes $fixture $restored;Check "$case-$($entry.mode)-roundtrip"
   if($entry.mode -eq 'native'){$nativeFrame=$frame}else{Same-Bytes $nativeFrame $frame;Check "$case-native-portable-frame"}
  }
 }
 $exe=$executables[0].path;$fixed=Join-Path $work 'fixed-native.frame'
 $repeat=Join-Path $work 'fixed-native-repeat.frame';$repeatRestore=Join-Path $work 'fixed-native-repeat.restore'
 $null=Invoke-Child $exe @('encode',$group,$repeat);$owned.Add($repeat);$null=Hold $repeat 'repeat-frame'
 $null=Invoke-Child $exe @('decode',$repeat,$repeatRestore);$owned.Add($repeatRestore);$null=Hold $repeatRestore 'repeat-restore'
 Same-Bytes $fixed $repeat;Same-Bytes $group $repeatRestore;Check 'fixed-repeat-determinism'
 $raw=[IO.File]::ReadAllBytes($fixed)
 $bad=[ordered]@{}
 $bad.magic=$raw.Clone();$bad.magic[0]=$bad.magic[0] -bxor 1
 $bad.header_crc=$raw.Clone();$bad.header_crc[32]=$bad.header_crc[32] -bxor 1
 $bad.payload_crc=$raw.Clone();$bad.payload_crc[-1]=$bad.payload_crc[-1] -bxor 1
 $bad.truncated=$raw[0..($raw.Length-2)]
 $bad.trailing=[byte[]]($raw+@(0))
 foreach($name in $bad.Keys){
  $inputPath=Join-Path $work "$name.bad";$outputPath=Join-Path $work "$name.rejected"
  Write-New $inputPath $bad[$name];$null=Hold $inputPath 'malformed-frame'
  $null=Invoke-Child $exe @('decode',$inputPath,$outputPath) 1
  if(Test-Path -LiteralPath $outputPath){throw 'Malformed frame published'}
  Check "$name-rejected-before-publication"
 }
 $oldExe=Join-Path $root 'build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/codec-native.exe'
 foreach($cross in @(@{exe=$exe;frame=$frozenFrame;label='old-by-new'},@{exe=$oldExe;frame=$fixed;label='new-by-old'})){
  $outputPath=Join-Path $work "$($cross.label).rejected"
  $row=Invoke-Child $cross.exe @('decode',$cross.frame,$outputPath) 1
  if($row.stderr -notmatch 'magic' -or (Test-Path -LiteralPath $outputPath)){throw 'Cross-format rejection failed'}
  Check "$($cross.label)-format-rejection"
 }
 foreach($operation in @('encode','decode')){
  $inputPath=if($operation -eq 'encode'){Join-Path $work 'single.input'}else{Join-Path $work 'single-native.frame'}
  $sentinel=Join-Path $work "$operation.existing";Write-New $sentinel ([byte[]]@(12,34,56))
  $null=Invoke-Child $exe @($operation,$inputPath,$sentinel) 1
  if([Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel)) -cne [Convert]::ToBase64String([byte[]]@(12,34,56))){throw 'Existing output changed'}
  $null=Hold $sentinel 'no-clobber-sentinel';Check "$operation-no-clobber"
 }
 $missingOutput=Join-Path $work 'missing.rejected'
 $null=Invoke-Child $exe @('encode',(Join-Path $work 'missing.input'),$missingOutput) 1
 if(Test-Path -LiteralPath $missingOutput){throw 'Missing input published'}
 Check 'missing-input-refused'
 $cap=Join-Path $work 'over-cap.input'
 No-Reparse $cap;$capStream=[IO.File]::Open($cap,'CreateNew','Write','None')
 try{$capStream.SetLength(8*1024*1024+1);$capStream.Flush($true)}finally{$capStream.Dispose()}
 $owned.Add($cap);$null=Hold $cap 'regenerable-over-cap-input'
 $capOutput=Join-Path $work 'over-cap.rejected'
 $row=Invoke-Child $exe @('encode',$cap,$capOutput) 1
 if($row.stderr -notmatch 'within limit' -or (Test-Path -LiteralPath $capOutput)){throw 'Input cap refused incorrectly'}
 Check 'input-cap-before-publication'
 $report.size_result=[ordered]@{input=Identity $group;old=Identity $frozenFrame;candidate=Identity $fixed;maximum_archive_bytes=483599;passed=([IO.FileInfo]$fixed).Length -le 483599;delta_vs_old_bytes=([IO.FileInfo]$fixed).Length-([IO.FileInfo]$frozenFrame).Length;timing_used=$false;declared_context_storage_bytes=7339976;declared_kt_table_storage_bytes=524296}
 $report.status=if($report.size_result.passed){'correctness_and_size_passed_not_timed'}else{'correctness_passed_size_no_go_not_timed'}
}catch{$failure=$_;$report.error=$_.Exception.Message}
finally{
 foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $after.bytes -or $id.before_sha256 -cne $after.sha256){throw 'Held file changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join ';';if($null -eq $failure){$failure=$_}}}
 foreach($held in $locks){$held.Dispose()}
 $items=@(Get-ChildItem -LiteralPath $work -Force -Recurse)
 $report.inventory=@($items | Select-Object FullName,Length,Attributes)
 $report.owned_tmp_count=@($items | Where-Object {$_.Name -like '*.tmp'}).Count
 $report.owned_reparse_count=@($items | Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}).Count
 if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join ';'}
 $report.completed_utc=[DateTime]::UtcNow.ToString('o')
 Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
if($report.status -eq 'failed'){throw $report.error}
[pscustomobject]@{status=$report.status;checks=$checks.Count;cli_calls=$calls.Count;identities=$ids.Count;size=$report.size_result;tmp=$report.owned_tmp_count;reparse=$report.owned_reparse_count}|ConvertTo-Json -Depth 4

