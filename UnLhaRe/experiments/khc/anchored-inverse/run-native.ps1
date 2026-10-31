[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-anchored-inverse-20261004'
$exe=Join-Path $work 'anchored-inverse-o3-thin.exe'
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
 $planPath=Join-Path $PSScriptRoot '../ANCHORED_INVERSE_PLAN_20261004.md';if((Identity $planPath).sha256 -cne '5974FC25B160262D91D0AC47D8BFCA28A0CF68A99AE70558C91FC93279D9E52D'){throw 'Parent PLAN SHA'}
 $oldRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../permutation-inverse'));$oldPacked=Join-Path $oldRoot 'packed.rs';$oldRunner=Join-Path $oldRoot 'run-native.ps1';$oldPath=Join-Path $project 'build/khc-permutation-inverse-20261004/report.json'
 if((Identity $oldRunner).sha256 -cne '606EABFEE55F67F95270D33ABA5E4C45C825F96801BFEA74A1E34E9BAD6E90AF'){throw 'Frozen runner SHA'};$ours=[IO.File]::ReadAllText($PSCommandPath).Replace("`r`n","`n");$previous=[IO.File]::ReadAllText($oldRunner).Replace("`r`n","`n");$ours=$ours.Substring(0,$ours.IndexOf("try{`n",[StringComparison]::Ordinal));$previous=$previous.Substring(0,$previous.IndexOf("try{`n",[StringComparison]::Ordinal));$ours=$ours.Replace('khc-anchored-inverse-20261004','khc-permutation-inverse-20261004').Replace('anchored-inverse-o3-thin.exe','permutation-inverse-o3-thin.exe');if($ours -cne $previous){throw 'Frozen helper runner prefix full restoration'};$report.runner_prefix_ledger=@{output_binding_replacements=2;helper_definition_changes=0;extra_residual=0}
 if((Identity $oldPath).sha256 -cne '6D8CE7424756C440E286D8F9318FF80C544683F7ECDCC752D3A56B6FD55ACCDA'){throw 'Frozen permutation report SHA'};$old=Get-Content -Raw -LiteralPath $oldPath|ConvertFrom-Json -Depth 32 -DateKind String;if($old.status -cne 'diagnostic-passed' -or $old.executable_before.sha256 -cne '2FEB3C881C90D4CA40F099B42AAC8237E74633F790FF26BB8CF9E3575A1A20B6'){throw 'Frozen permutation status/EXE'}
 foreach($kind in @('sources','identities')){$before=@($old.($kind+'_before'));$after=@($old.($kind+'_after'));if($before.Count -ne $after.Count){throw 'Frozen identity pairs'};for($i=0;$i -lt $before.Count;$i++){if(!(Same-PermutationIdentity $before[$i] $after[$i]) -or !(Same-PermutationIdentity $before[$i] (Identity $before[$i].path))){throw 'Frozen before-after-live drift'};Pin-PermutationFile $before[$i].path}}
 if(!(Same-PermutationIdentity $old.executable_before $old.executable_after) -or !(Same-PermutationIdentity $old.executable_before (Identity $old.executable_before.path))){throw 'Frozen EXE drift'};Pin-PermutationFile $old.executable_before.path
 # 旧validate～LF構築～read-only化までを全文一致。walk/metadataは新方式の別契約。
 $oldText=[IO.File]::ReadAllText($oldPacked).Replace("`r`n","`n");$newText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'anchored.rs')).Replace("`r`n","`n");$start='    validate(last,alphabet)?;';$end='    let words=words;'
 $oa=$oldText.IndexOf($start,[StringComparison]::Ordinal);$ob=$oldText.IndexOf($end,$oa,[StringComparison]::Ordinal)+$end.Length;$na=$newText.IndexOf($start,[StringComparison]::Ordinal);$nb=$newText.IndexOf($end,$na,[StringComparison]::Ordinal)+$end.Length
 if($oa -lt 0 -or $na -lt 0 -or $oldText.Substring($oa,$ob-$oa) -cne $newText.Substring($na,$nb-$na)){throw 'Guard/build fulltext ledger'}
 $report.guard_build_ledger=@{same_validate_counts_alphabet_prefix_rank_LF_pack_bytes=$true;original_pack_direct_reference=$true;guard_build_extra_residual=0;new_metadata_and_interleave_walker_separate=$true;early_primary_before_each_lane_load_write=$true}
 foreach($path in @($PSCommandPath,$originalRunner,$packedRunner,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$planPath,$frozenCodec,$oldPath,$oldRunner,$oldPacked,(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),(Join-Path $oldRoot 'RESULT_20261004.md'),(Join-Path $oldRoot 'verify-artifacts.ps1'))){Pin-PermutationFile $path}
 $report.identities_before=@($pins);if($report.source_bytes+(Identity $planPath).bytes+(Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).bytes -gt 307200){throw 'Sources/plan 300KiB'}
 $fixedIdentity=Identity $fixedInputPath;if($fixedIdentity.bytes -ne 2811006 -or $fixedIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);CPU_quiet_verified=$false}
 if($report.environment.architecture -cne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.RAM_estimate_limit_bytes=167772160;$report.precomputed_fixed_worst_bytes=26682390;$report.precomputed_boundary_worst_bytes=130023437;$report.boundary_candidate_worst_bytes=71303206;$report.BWT_phase_RAM_estimate_bytes=141598926
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1;$report.compile_limit_seconds=60;$report.native_limit_seconds=120
 $report.compile_settings=@('--edition=2024','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE1MiB bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.native_calls=1;$record=Child $exe @('screen',$fixedInputPath) 120;if($record.stderr){throw 'Native stderr'}
 $report.diagnostic=$record.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$d=$report.diagnostic;$e=$d.rejections;$f=$d.fixed;$s=$d.small
 if($d.status -cne 'passed' -or $d.kind -cne 'anchored_inverse_private_diagnostic'){throw 'Diagnostic status'}
 foreach($pair in @(@('plain_cases',92),@('BWT_calls',92),@('independent_suffix_sort_cases',92),@('SA_anchor_comparisons',512),@('fallback_cases',28),@('anchored_cases',64),@('remainder_categories',8))){if($s.($pair[0]) -ne $pair[1]){throw 'Tiny finite census'}};if(!$s.all_three_way_plain_equal){throw 'Tiny fullplain'}
 foreach($pair in @(@('generator_input_rejections',17),@('decoder_input_rejections',17),@('metadata_rejections',9),@('fallback_metadata_rejections',1),@('recovery_cases',10),@('counterexample72_endpoint_checks',8),@('counterexample72_primary_first_return',8),@('bit_roundtrip_checks',4),@('bit_rejections',1),@('enumeration_cases',1793),@('enumeration_accepted',255),@('enumeration_generator_rejections',1538),@('enumeration_decoder_rejections',1538))){if($e.($pair[0]) -ne $pair[1]){throw 'Adversarial finite census'}};if(!$e.all_plain_directly_compared){throw 'Enumeration fullplain'}
 if($f.input_reads -ne 1 -or $f.BWT_calls -ne 1 -or $f.n -ne 2811007 -or $f.primary -ne 1762795 -or $f.warmups_each -ne 1 -or $f.rounds -ne 9 -or $f.timed_calls -ne 18 -or $f.samples.Count -ne 9 -or $f.metadata_generation_calls -ne 1 -or $f.metadata_generation_ns -le 0 -or $f.metadata_bytes -ne 32 -or $f.metadata_capacity -ne 32 -or $f.metadata_hex -cnotmatch '^[0-9a-f]{64}$' -or $f.anchors.Count -ne 8 -or $f.anchors[0] -ne $f.primary -or !$f.all_plain_direct_comparisons -or !$f.metadata_generation_scratch_dropped_before_restore -or $f.CPU_quiet_verified -or $f.comparison_and_caller_drop_timed -or !$f.scratch_allocate_init_guard_walk_free_timed -or !$f.candidate_metadata_parse_timed -or $f.encoder_metadata_cost_free){throw 'Fixed timing/metadata contract'}
 for($i=0;$i -lt 8;$i++){$word=[Convert]::ToUInt32(($f.metadata_hex.Substring(8*$i+6,2)+$f.metadata_hex.Substring(8*$i+4,2)+$f.metadata_hex.Substring(8*$i+2,2)+$f.metadata_hex.Substring(8*$i,2)),16);if($word -ne $f.anchors[$i]){throw '32 byte LE anchors'}}
 $times=@(@(),@());$orders=@(@(@(),@()),@(@(),@()));for($round=0;$round -lt 9;$round++){$v=$f.samples[$round];$order=$round%2;if($v.round -ne $round -or $v.order -cne @('AB','BA')[$order] -or $v.old24_ns -le 0 -or $v.candidate_ns -le 0){throw 'Raw fixed rotation'};$times[0]+=$v.old24_ns;$times[1]+=$v.candidate_ns;$orders[$order][0]+=$v.old24_ns;$orders[$order][1]+=$v.candidate_ns}
 function Median-Anchored($values){$v=@($values|Sort-Object);$m=[int][math]::Floor($v.Count/2);if($v.Count%2){return [double]$v[$m]};([double]$v[$m-1]+[double]$v[$m])/2}
 if($f.old24_median_ns -ne (Median-Anchored $times[0]) -or $f.candidate_median_ns -ne (Median-Anchored $times[1]) -or $f.AB_rounds -ne 5 -or $f.BA_rounds -ne 4 -or $f.AB_old24_median_ns -ne (Median-Anchored $orders[0][0]) -or $f.AB_candidate_median_ns -ne (Median-Anchored $orders[0][1]) -or $f.BA_old24_median_ns -ne (Median-Anchored $orders[1][0]) -or $f.BA_candidate_median_ns -ne (Median-Anchored $orders[1][1])){throw 'Raw/order medians'}
 if($f.input_capacity -ne 2811006 -or $f.last_capacity -ne 2811007 -or $f.generation_scratch_capacity_words -ne 2811007 -or $f.scratch_capacity_words_each -ne 2811007 -or $f.result_capacity_each -ne 2811006 -or $f.same_phase_RAM_estimate_bytes -ne 26682390 -or $f.generation_phase_RAM_estimate_bytes -ne 23871384){throw 'Fixed capacity/phase'}
 $lengths=@(8388607,8388608,8388609);if($d.boundaries.Count -ne 3){throw 'Boundary extent'}
 for($i=0;$i -lt 3;$i++){$b=$d.boundaries[$i];$n=$lengths[$i];if($b.n -ne $n -or $b.route -cne 'anchored8' -or !$b.three_way_all_plain_equal -or !$b.all_expected_zero -or $b.metadata_bytes -ne 32 -or $b.metadata_capacity -ne 32 -or $b.last_capacity -ne $n -or $b.reference_result_capacity -ne $n-1 -or $b.candidate_result_capacity -ne $n-1 -or $b.candidate_scratch_capacity_words -ne $n -or $b.generation_scratch_capacity_words -ne $n -or $b.reference_phase_RAM_estimate_bytes -ne 15*$n-2+4MB -or $b.candidate_phase_RAM_estimate_bytes -ne 8*$n-2+32+4MB -or $b.reference_phase_RAM_estimate_bytes -gt 160MB -or $b.candidate_phase_RAM_estimate_bytes -gt 160MB){throw 'Boundary fullplain/route/capacity/RAM'}}
 foreach($flag in @('metadata_CRC_protected','completed_archive_wire','formal_performance_claim','four_native_verified','adoption')){if($d.$flag){throw 'Nonclaim'}}
 if(!$d.memory.ABI_checked -or $d.memory.API_calls -ne 1 -or $d.memory.ABI_size -ne 80 -or $d.memory.ABI_cb -ne 80){throw 'WinAPI ABI'}
 if(!$d.memory.measured){$report.status='diagnostic-resource-unmeasured'}else{if($null -ne $d.memory.last_OS_error -or $null -eq $d.memory.peak_working_set_bytes -or $null -eq $d.memory.peak_private_commit_bytes -or $d.memory.peak_working_set_bytes -le 0 -or $d.memory.peak_private_commit_bytes -le 0){throw 'Measured WinAPI positive values/error'};$report.status=if($d.memory.peak_working_set_bytes -gt 160MB -or $d.memory.peak_private_commit_bytes -gt 160MB){'diagnostic-resource-unmet'}else{'diagnostic-passed'}}
 $report.interpretation='8-anchor LF same-thread interleave plus separately timed encoder metadata generation; old24/new fullplain same EXE. CPU quiet unverified; metadata 32bytes not CRC-protected completed archive. No whole codec/7-Zip/formal speed/adoption claim.'
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
