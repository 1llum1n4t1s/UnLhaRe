[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-anchored-sa-generation-20261004'
$exe=Join-Path $work 'anchored-sa-generation-o3-thin.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$originalRunner=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
$originalRunnerSha='A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85'
$frozenSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../float-fresh-transaction'))
$frozenPackedRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../packed-inverse'))
$packedRunner=Join-Path $frozenPackedRoot 'run-native.ps1'
$packedRunnerSha='4872305FF29E8E3CF4C82FBFEEF83D1923EECA995A532AA67B66DF4115A7E692'
$frozenCodec=Join-Path $PSScriptRoot '../lookup-float-profile/codec.rs'
$packedReportPath=Join-Path $project 'build/khc-packed-inverse-20261004/report.json'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();compile_calls=0;native_calls=0;diagnostic_only=$true;CPU_quiet_verified=$false;setting_sweeps=0;old_entrypoints_executed=$false;frame_encodes=0;frame_decodes=0;disk_plain_input_frame_copies=0;raw_trace_copies=0;new_context_independent_audit=$false}
$report.function_bindings=@()
foreach($binding in @(@{path=$originalRunner;SHA=$originalRunnerSha;names=@('Identity','Safe-Path','Source','Save-Report','Child');root=$frozenSourceRoot},@{path=$packedRunner;SHA=$packedRunnerSha;names=@('Check-ReferenceExtraction');root=$frozenPackedRoot})){
 if((Get-FileHash -LiteralPath $binding.path).Hash -cne $binding.SHA){throw 'Frozen AST runner SHA'}
 $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($binding.path,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Frozen AST syntax'}
 foreach($name in $binding.names){$definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($definitions.Count -ne 1){throw "Unique AST function: $name"};$definition=$definitions[0].Extent.Text;if($name -ceq 'Source'){$definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot')};if($name -ceq 'Check-ReferenceExtraction'){$definition=$definition.Replace('$PSScriptRoot','$frozenPackedRoot')};. ([ScriptBlock]::Create($definition));$report.function_bindings+=@{name=$name;source=$binding.path;sha256=$binding.SHA;source_root=$binding.root}}
}
function Same-PermutationIdentity($A,$B){foreach($field in @('path','sha256','bytes','mtime_utc')){if($A.$field -cne $B.$field){return $false}};return $true}
function Pin-PermutationFile([string]$Path){$p=Safe-Path $Path;if(@($pins|Where-Object path -ceq $p).Count){return};$locks.Add([IO.File]::Open($p,'Open','Read','Read'));$pins.Add((Identity $p))}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Runner syntax'}
 $report.reference_extraction=Check-ReferenceExtraction
 Source (Join-Path $PSScriptRoot 'probe.rs');$report.imports=@($graph);$report.sources_before=@($sources)
 $report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum);if($sources.Count -ne 9 -or $graph.Count -ne 8){throw 'Nine-source/eight-edge closure'}
 $planPath=Join-Path $PSScriptRoot '../ANCHORED_SA_GENERATION_PLAN_20261004.md';if((Identity $planPath).sha256 -cne '6E28E22BC2DFE1414315D55D7A8AC30D86D35FEAEAA31F3898758483867E68FF'){throw 'Parent PLAN SHA'}
 $oldRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../anchored-inverse'));$oldBWT=Join-Path $PSScriptRoot '../causal-bayes-sais/bwt.rs';$oldRunner=Join-Path $oldRoot 'run-native.ps1';$oldPath=Join-Path $project 'build/khc-anchored-inverse-20261004/report.json'
 if((Identity $oldRunner).sha256 -cne 'CA684842B8553BB713F30F6C07EB5EAE15103D857B530A20AC652F13DFE5EDF6'){throw 'Frozen runner SHA'};$ours=[IO.File]::ReadAllText($PSCommandPath).Replace("`r`n","`n");$previous=[IO.File]::ReadAllText($oldRunner).Replace("`r`n","`n");$ours=$ours.Substring(0,$ours.IndexOf("try{`n",[StringComparison]::Ordinal));$previous=$previous.Substring(0,$previous.IndexOf("try{`n",[StringComparison]::Ordinal));$ours=$ours.Replace('khc-anchored-sa-generation-20261004','khc-anchored-inverse-20261004').Replace('anchored-sa-generation-o3-thin.exe','anchored-inverse-o3-thin.exe');if($ours -cne $previous){throw 'Frozen helper runner prefix full restoration'};$report.runner_prefix_ledger=@{output_binding_replacements=2;helper_definition_changes=0;extra_residual=0}
 if((Identity $oldPath).sha256 -cne '3DDDA5809D5615E50017F012FCD22BD3AFEF424FF4A06B099F7ACEB34B40EEA9'){throw 'Frozen permutation report SHA'};$old=Get-Content -Raw -LiteralPath $oldPath|ConvertFrom-Json -Depth 32 -DateKind String;if($old.status -cne 'diagnostic-passed' -or $old.executable_before.sha256 -cne 'EDE58C62051203D85C52794F2EF91B3C5E1489644E0F523FBC2163FF9CA38B0E'){throw 'Frozen permutation status/EXE'}
 foreach($kind in @('sources','identities')){$before=@($old.($kind+'_before'));$after=@($old.($kind+'_after'));if($before.Count -ne $after.Count){throw 'Frozen identity pairs'};for($i=0;$i -lt $before.Count;$i++){if(!(Same-PermutationIdentity $before[$i] $after[$i]) -or !(Same-PermutationIdentity $before[$i] (Identity $before[$i].path))){throw 'Frozen before-after-live drift'};Pin-PermutationFile $before[$i].path}}
 if(!(Same-PermutationIdentity $old.executable_before $old.executable_after) -or !(Same-PermutationIdentity $old.executable_before (Identity $old.executable_before.path))){throw 'Frozen EXE drift'};Pin-PermutationFile $old.executable_before.path
 $addendum=Join-Path $PSScriptRoot '../ANCHORED_SA_GENERATION_PREP_ADDENDUM_20261004.md';if((Identity $addendum).sha256 -cne '287A4F21A6EEC6DDDF99AC4350C45575168993DD4AA4CE496E59724266CB3D74'){throw 'Prepared alphabet addendum SHA'}
 if((Identity $oldBWT).sha256 -cne '810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'){throw 'Original BWT SHA'}
 $oldText=[IO.File]::ReadAllText($oldBWT).Replace("`r`n","`n").TrimEnd()+"`n";$newText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bwt.rs')).Replace("`r`n","`n")
 $marker='pub fn bwt(input:';$oa=$oldText.IndexOf($marker,[StringComparison]::Ordinal);$na=$newText.IndexOf($marker,[StringComparison]::Ordinal);if($oa -lt 0 -or $na -lt 0 -or $oldText.Substring(0,$oa) -cne $newText.Substring(0,$na)){throw 'BWT original SA-IS prefix fulltext'}
 $helperMarker="`npub(crate) fn select";if([regex]::Matches($newText,[regex]::Escape($helperMarker)).Count -ne 1){throw 'Helper suffix boundary'};$hi=$newText.IndexOf($helperMarker,[StringComparison]::Ordinal);$suffix=$newText.Substring($hi);$suffixHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($suffix)));if($suffixHash -cne 'EEC765603E805E856FE7EB935AE5999AE3C58E51D42FDD02BD9E6D78E7131EEB'){throw 'Fixed selector helper suffix'}
 $restored=$newText.Substring(0,$hi).TrimEnd()+"`n"
 $after=@'
    let metadata=finish(anchors,n,primary)?;
    Ok((last, primary, metadata))
'@;$before=@'
    Ok((last, primary))
'@;$after=$after.Replace("`r`n","`n");$before=$before.Replace("`r`n","`n");if([regex]::Matches($restored,[regex]::Escape($after)).Count -ne 1){throw 'BWT restoration count'};$restored=$restored.Replace($after,$before)
 $after=@'
        select(&mut anchors,n,row,p)?;
        last[row] = text[if p == 0 { n - 1 } else { p - 1 }] as u16;
'@;$before=@'
        last[row] = text[if p == 0 { n - 1 } else { p - 1 }] as u16;
'@;$after=$after.Replace("`r`n","`n");$before=$before.Replace("`r`n","`n");if([regex]::Matches($restored,[regex]::Escape($after)).Count -ne 1){throw 'BWT restoration count'};$restored=$restored.Replace($after,$before)
 $after=@'
    let mut primary = None;
    let mut anchors=[None;8];
    for (row, &position) in sa.iter().enumerate() {
'@;$before=@'
    let mut primary = None;
    for (row, &position) in sa.iter().enumerate() {
'@;$after=$after.Replace("`r`n","`n");$before=$before.Replace("`r`n","`n");if([regex]::Matches($restored,[regex]::Escape($after)).Count -ne 1){throw 'BWT restoration count'};$restored=$restored.Replace($after,$before)
 $after=@'
pub fn bwt(input: &[u8]) -> Result<(Vec<u16>, usize, Vec<u8>)> {
'@;$before=@'
pub fn bwt(input: &[u8]) -> Result<(Vec<u16>, usize)> {
'@;$after=$after.Replace("`r`n","`n");$before=$before.Replace("`r`n","`n");if([regex]::Matches($restored,[regex]::Escape($after)).Count -ne 1){throw 'BWT restoration count'};$restored=$restored.Replace($after,$before)
 if($restored -cne $oldText){throw 'BWT body full restoration'}
 $report.BWT_ledger=@{SA_IS_prefix_unchanged=$true;metadata_replacements=4;fixed_selector_helper_suffix=1;selector_suffix_sha256=$suffixHash;extra_residual=0;original_allocation_order_preserved=$true;new_LF_scratch_or_walk=$false;new_separate_SA_scan=$false}
 foreach($path in @($PSCommandPath,$originalRunner,$packedRunner,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$planPath,$addendum,$frozenCodec,$oldPath,$oldRunner,$oldBWT,(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),(Join-Path $oldRoot 'verify-artifacts.ps1'),(Join-Path $PSScriptRoot '../ANCHORED_INVERSE_RESULT_20261004.md'))){Pin-PermutationFile $path}
 $report.identities_before=@($pins);if($report.source_bytes+(Identity $planPath).bytes+(Identity $addendum).bytes+(Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).bytes -gt 307200){throw 'Sources/plan 300KiB'}
 $fixedIdentity=Identity $fixedInputPath;if($fixedIdentity.bytes -ne 2811006 -or $fixedIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 if((Identity (Get-Process -Id $PID).Path).sha256 -cne '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'){throw 'PowerShell pin'}
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);CPU_quiet_verified=$false}
 if($report.environment.architecture -cne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.RAM_estimate_limit_bytes=167772160;$report.precomputed_fixed_worst_bytes=147225100;$report.BWT_phase_RAM_estimate_bytes=141598926
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1;$report.compile_limit_seconds=60;$report.native_limit_seconds=120
 $report.compile_settings=@('--edition=2024','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE1MiB bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.native_calls=1;$record=Child $exe @('screen',$fixedInputPath) 120;if($record.stderr){throw 'Native stderr'}
 $report.diagnostic=$record.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$d=$report.diagnostic;$s=$d.small;$e=$d.selector;$f=$d.fixed
 if($d.status -cne 'passed' -or $d.kind -cne 'anchored_SA_generation_private_diagnostic'){throw 'Diagnostic status'}
 foreach($pair in @(@('plain_cases',92),@('independent_suffix_sort_cases',92),@('SA_anchor_comparisons',512),@('fallback_cases',28),@('anchored_cases',64),@('remainder_categories',8))){if($s.($pair[0]) -ne $pair[1]){throw 'Tiny finite census'}};if(!$s.all_BWT_primary_metadata_bytes_equal -or !$s.all_three_way_plain_equal){throw 'Tiny direct comparison'}
 foreach($pair in @(@('q0_safe_select_calls',28),@('target_select_calls',152),@('synthetic_anchor_comparisons',152),@('target_roundtrip_cases',19),@('wrong_suffix_nonselection_cases',1),@('selector_rejections',8),@('unchanged_stack_rejections',5),@('oversized_BWT_rejections',2),@('recovery_cases',1),@('maximum_selector_n',8388609),@('large_forward_BWT_calls',0))){if($e.($pair[0]) -ne $pair[1]){throw 'Selector finite census'}};if($e.OS_OOM_injected){throw 'OSOOM nonclaim'}
 foreach($pair in @(@('input_reads',1),@('input_length',2811006),@('input_capacity',2811006),@('last_capacity_each',2811007),@('metadata_capacity_each',32),@('metadata_bytes',32),@('n',2811007),@('primary',1762795),@('warmups_each',1),@('rounds',9),@('timed_calls',18),@('timed_old_BWT_calls',9),@('timed_old_LF_generation_calls',9),@('timed_new_BWT_calls',9),@('new_LF_generation_calls',0),@('new_separate_SA_scans',0),@('all_plain_bytes_compared',2811006),@('candidate_scratch_capacity_words',2811007),@('candidate_result_capacity',2811006),@('new_BWT_source_phase_bytes',147225100),@('alphabet_prep_calls',1),@('alphabet_validation_calls',1),@('restore_alphabet_scan_calls',1))){if($f.($pair[0]) -ne $pair[1]){throw 'Fixed pipeline census'}}
 foreach($flag in @('all18_pipeline_last_primary_metadata_comparisons','old_plain_dropped_before_candidate_restore','alphabet_prep_outside_pipeline_timers','prepared_alphabet_all_values_equal','both_BWT_phases_bound','function_SA_text_scratch_drop_timed')){if(!$f.$flag){throw 'Fixed direct/lifetime check'}};if($f.CPU_quiet_verified -or $f.comparison_and_caller_drop_timed -or $f.alphabet_prep_ns -le 0){throw 'Timer scope'}
 if($f.old_LF_source_phase_bytes -ne 2811006+8*2811007+64+4096+4MB -or $f.restore_source_phase_bytes -ne 2811006+7*2811007-1+32+4MB){throw 'Other capacity/source phases'}
 $times=@(@(),@(),@(),@());$ordered=@(@(@(),@()),@(@(),@()));if($f.samples.Count -ne 9){throw 'Raw samples'}
 for($round=0;$round -lt 9;$round++){$v=$f.samples[$round];$order=$round%2;if($v.round -ne $round -or $v.order -cne @('AB','BA')[$order] -or $v.old_BWT_ns -le 0 -or $v.old_LF_generation_ns -le 0 -or $v.old_total_ns -le 0 -or $v.new_total_ns -le 0 -or $v.old_total_minus_BWT_LF_ns -ne $v.old_total_ns-$v.old_BWT_ns-$v.old_LF_generation_ns -or $v.old_total_minus_BWT_LF_ns -lt 0){throw 'Raw pipeline timing/rotation'};$times[0]+=$v.old_BWT_ns;$times[1]+=$v.old_LF_generation_ns;$times[2]+=$v.old_total_ns;$times[3]+=$v.new_total_ns;$ordered[$order][0]+=$v.old_total_ns;$ordered[$order][1]+=$v.new_total_ns}
 function Median-SA($values){$v=@($values|Sort-Object);$m=[int][math]::Floor($v.Count/2);if($v.Count%2){return [double]$v[$m]};([double]$v[$m-1]+[double]$v[$m])/2}
 foreach($i in 0..3){$field=@('old_BWT_median_ns','old_LF_generation_median_ns','old_total_median_ns','new_total_median_ns')[$i];if($f.$field -ne (Median-SA $times[$i])){throw 'Whole raw median'}}
 if($f.AB_rounds -ne 5 -or $f.BA_rounds -ne 4 -or $f.AB_old_total_median_ns -ne (Median-SA $ordered[0][0]) -or $f.AB_new_total_median_ns -ne (Median-SA $ordered[0][1]) -or $f.BA_old_total_median_ns -ne (Median-SA $ordered[1][0]) -or $f.BA_new_total_median_ns -ne (Median-SA $ordered[1][1])){throw 'Order medians'}
 foreach($flag in @('metadata_CRC_protected','completed_archive_wire','formal_performance_claim','four_native_verified','adoption')){if($d.$flag){throw 'Nonclaim'}}
 if(!$d.memory.ABI_checked -or $d.memory.API_calls -ne 1 -or $d.memory.ABI_size -ne 80 -or $d.memory.ABI_cb -ne 80){throw 'WinAPI ABI'}
 if(!$d.memory.measured){$report.status='diagnostic-resource-unmeasured'}else{if($null -ne $d.memory.last_OS_error -or $null -eq $d.memory.peak_working_set_bytes -or $null -eq $d.memory.peak_private_commit_bytes -or $d.memory.peak_working_set_bytes -le 0 -or $d.memory.peak_private_commit_bytes -le 0){throw 'Measured WinAPI positive values/error'};$report.status=if($d.memory.peak_working_set_bytes -gt 160MB -or $d.memory.peak_private_commit_bytes -gt 160MB){'diagnostic-resource-unmet'}else{'diagnostic-passed'}}
 $report.interpretation='Original SA-IS prefix/body restored by four metadata additions only; common alphabet preparation measured separately/outside each pipeline and full values checked once. Full old/new last/primary/metadata every pair; exact plain restored. Old LF generation is not free. CPU quiet unverified, no full codec/7-Zip/formal/CRC-protected archive/adoption claim.'
 $report.executable_after=Identity $exe;if(!(Same-PermutationIdentity $report.executable_before $report.executable_after)){throw 'EXE changed'}
 $report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($report.owned_exe_processes){throw 'Owned EXE remains'}
 $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output ownership/shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same-PermutationIdentity $_ $now)){throw "Source changed: $($_.path)"};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same-PermutationIdentity $_ $now)){throw "Pin changed: $($_.path)"};$now})
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;report=Identity (Join-Path $work 'report.json');executable=$report.executable_after;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.native_calls;final_guard_after_report_save=$finalGuard}|ConvertTo-Json -Depth 6
