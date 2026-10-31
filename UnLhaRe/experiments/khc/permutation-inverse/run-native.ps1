[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-permutation-inverse-20261004'
$exe=Join-Path $work 'permutation-inverse-o3-thin.exe'
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
 $report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum);if($sources.Count -ne 9 -or $report.source_bytes -gt 307200){throw 'Nine-source closure 300KiB'}
 $planPath=Join-Path $PSScriptRoot '../PERMUTATION_INVERSE_PLAN_20261004.md';$questionPath=Join-Path $PSScriptRoot '../PERMUTATION_INVERSE_QUESTION_20261004.md'
 if((Identity $planPath).sha256 -cne '87CEA1CAD262E31A0D163E9EDB53C996A62EC8D4E83EA29112FF97A014E4519C' -or (Identity $questionPath).sha256 -cne '06C7A91A04E20EA49CCE966DBB7BBBE21BECC38862C2A1731344E43137797FF1'){throw 'Parent plan/question SHA'}
 if((Identity $packedReportPath).sha256 -cne '68487A979DE0E9FEFD05A50368016F8DD0A734E3ED2B6C730FB943B80146ABBA'){throw 'Frozen packed23 report SHA'}
 $old=Get-Content -Raw -LiteralPath $packedReportPath|ConvertFrom-Json -Depth 32 -DateKind String;if($old.status -cne 'diagnostic-passed'){throw 'Frozen packed23 success status'}
 $report.frozen_packed_source_checks=0
 foreach($entry in $old.sources_before){$after=@($old.sources_after|Where-Object path -ceq $entry.path);if($after.Count -ne 1 -or !(Same-PermutationIdentity $entry $after[0]) -or !(Same-PermutationIdentity $entry (Identity $entry.path))){throw 'Frozen packed23 source drift'};Pin-PermutationFile $entry.path;$report.frozen_packed_source_checks++}
 if($report.frozen_packed_source_checks -ne 8){throw 'Frozen packed23 source extent'}
 foreach($path in @($PSCommandPath,$originalRunner,$packedRunner,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$planPath,$questionPath,$frozenCodec,$packedReportPath,(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),(Join-Path $frozenPackedRoot 'reference-ledger.json'),(Join-Path $frozenPackedRoot 'RESULT_20261004.md'),(Join-Path $frozenPackedRoot 'verify-artifacts.ps1'),(Join-Path $frozenPackedRoot 'FAILURE_PLAN.md'),(Join-Path $PSScriptRoot '../PACKED_INVERSE_MEMORY_API_NOTE_20261004.md'),(Join-Path $project 'Cargo.toml'))){Pin-PermutationFile $path}
 $report.identities_before=@($pins)
 $fixedIdentity=Identity $fixedInputPath;if($fixedIdentity.bytes -ne 2811006 -or $fixedIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);CPU_quiet_verified=$false}
 if($report.environment.architecture -cne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.RAM_estimate_limit_bytes=167772160;$report.precomputed_fixed_worst_bytes=51981419;$report.precomputed_boundary_worst_bytes=130023437;$report.BWT_phase_RAM_estimate_bytes=141598926
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1;$report.compile_limit_seconds=60;$report.native_limit_seconds=120
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE1MiB bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.native_calls=1;$record=Child $exe @('screen',$fixedInputPath) 120;if($record.stderr){throw 'Native stderr'}
 $report.diagnostic=$record.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$d=$report.diagnostic;$e=$d.rejections;$f=$d.fixed
 if($d.status -cne 'passed' -or $d.kind -cne 'permutation_inverse_private_layout_diagnostic' -or $d.small_plain_cases -ne 9 -or $e.internal_rejections -ne 11 -or $e.divisor_cycle3_rejections -ne 1 -or $e.common_wrapper_rejections -ne 3 -or $e.alphabet_wrapper_rejections -ne 2 -or $e.length_wrapper_rejections -ne 1 -or $e.bit_roundtrip_checks -ne 4 -or $e.bit_rejections -ne 1 -or $e.enumeration_cases -ne 1793 -or $e.enumeration_accepted -ne 255 -or $e.enumeration_rejected -ne 1538 -or !$e.three_way_acceptance_and_all_plain_equal){throw 'Permutation E2E category contract'}
 if($f.input_reads -ne 1 -or $f.BWT_calls -ne 1 -or $f.n -ne 2811007 -or $f.primary -ne 1762795 -or $f.warmups_each -ne 1 -or $f.rounds -ne 9 -or $f.timed_calls -ne 27 -or $f.samples.Count -ne 9 -or $f.rotations.Count -ne 3 -or !$f.all_plain_direct_comparisons -or $f.packed23_scratch_capacity_words -ne 2811007 -or $f.packed24_scratch_capacity_words -ne 2811007 -or $f.packed_result_capacity_each -ne 2811006 -or $f.same_phase_RAM_estimate_bytes -ne 51981419 -or $f.CPU_quiet_verified -or $f.result_comparison_and_caller_drop_timed -or !$f.scratch_allocate_initialize_guard_walk_free_timed){throw 'Fixed three-way timing/capacity contract'}
 $lengths=@(8388607,8388608,8388609);if($d.boundaries.Count -ne 3){throw 'Boundary extent'}
 for($i=0;$i -lt 3;$i++){$b=$d.boundaries[$i];$n=$lengths[$i];if($b.n -ne $n -or $b.candidate_route -cne 'packed24' -or !$b.three_way_all_plain_equal -or !$b.all_expected_zero -or $b.last_capacity -ne $n -or $b.reference_result_capacity -ne $n-1 -or $b.candidate_result_capacity -ne $n-1 -or $b.candidate_scratch_capacity_words -ne $n -or $b.same_phase_RAM_estimate_bytes -ne 15*$n-2+4MB -or $b.same_phase_RAM_estimate_bytes -gt 160MB){throw 'Boundary three-way plain/route/RAM'}}
 if(!$d.memory.ABI_checked -or $d.memory.API_calls -ne 1 -or $d.memory.ABI_size -ne 80 -or $d.memory.ABI_cb -ne 80){throw 'Frozen WinAPI helper contract'}
 $report.status=if($d.memory.measured -and !$d.memory.peak_gate_passed){'diagnostic-resource-unmet'}else{'diagnostic-passed'}
 $report.interpretation='Single-setting read-only LF permutation inverse, same-EXE original/23/24 only; CPU quiet unverified, no whole decode/codec/7-Zip/wire/adoption claim.'
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
