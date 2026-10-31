[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-packed-inverse-20261004'
$exe=Join-Path $work 'packed-inverse-o3-thin.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$originalRunner=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
$originalRunnerSha='A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85'
$frozenSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../float-fresh-transaction'))
$frozenCodec=Join-Path $PSScriptRoot '../lookup-float-profile/codec.rs'
$causalReportPath=Join-Path $project 'build/khc-causal-direct-mix-20261004/corrected-native/report.json'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();compile_calls=0;native_calls=0;diagnostic_only=$true;CPU_quiet_verified=$false;setting_sweeps=0;old_entrypoints_executed=$false;frame_encodes=0;frame_decodes=0;disk_plain_input_frame_copies=0;raw_trace_copies=0;new_context_independent_audit=$false}
if((Get-FileHash -LiteralPath $originalRunner).Hash -cne $originalRunnerSha){throw 'Frozen AST runner SHA'}
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($originalRunner,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Frozen AST syntax'}
$report.function_bindings=@()
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($definitions.Count -ne 1){throw "Unique AST function: $name"}
 $definition=$definitions[0].Extent.Text;if($name -ceq 'Source'){$definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot')};. ([ScriptBlock]::Create($definition))
 $report.function_bindings+=@{name=$name;source=$originalRunner;sha256=$originalRunnerSha;source_root=$frozenSourceRoot}
}
function Same-PackedIdentity($A,$B){foreach($field in @('path','sha256','bytes','mtime_utc')){if($A.$field -cne $B.$field){return $false}};return $true}
function Pin-PackedFile([string]$Path){$p=Safe-Path $Path;if(@($pins|Where-Object path -ceq $p).Count){return};$locks.Add([IO.File]::Open($p,'Open','Read','Read'));$pins.Add((Identity $p))}
function Check-ReferenceExtraction {
 $ledger=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'reference-ledger.json')|ConvertFrom-Json -Depth 8 -DateKind String
 if((Identity $frozenCodec).sha256 -cne $ledger.frozen_codec_sha256 -or $ledger.definitions.Count -ne 2 -or $ledger.allowed_edit -cne "Insert ASCII 'pub ' at byte 0 of each extracted definition only"){throw 'Extraction ledger root'}
 $text=[IO.File]::ReadAllText($frozenCodec);$expected=$ledger.reference_prefix;$definitions=@()
 foreach($entry in $ledger.definitions){
  if($entry.name -notin @('filled','inverse_bwt') -or $entry.visibility_insert_utf8_byte -ne 0 -or $entry.visibility_insert -cne 'pub '){throw 'Extraction allowlist'}
  $pattern=if($entry.name -ceq 'filled'){'(?ms)^fn filled<T: Clone>\(.*?^\}'}else{'(?ms)^fn inverse_bwt\(.*?^\}'}
  $matches=[regex]::Matches($text,$pattern);if($matches.Count -ne 1){throw 'Unique frozen definition'};$m=$matches[0];$bytes=[Text.Encoding]::UTF8.GetBytes($m.Value)
  if([Text.Encoding]::UTF8.GetByteCount($text.Substring(0,$m.Index)) -ne $entry.start_utf8_byte -or $bytes.Length -ne $entry.original_bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $entry.original_sha256){throw 'Extracted original bytes/offset/SHA'}
  $definitions+=($entry.visibility_insert+$m.Value)
 }
 if(($ledger.definitions.name -join ',') -cne 'filled,inverse_bwt'){throw 'Exact definition order'}
 $expected+=($definitions -join $ledger.separator)+$ledger.suffix
 if($expected -cne [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'reference.rs'))){throw 'Whole reference allowlist equality'}
 [pscustomobject]@{whole_reference_allowlist_equal=$true;visibility_insertions=2;original_definition_bytes=@($ledger.definitions.original_bytes);original_definition_SHA=@($ledger.definitions.original_sha256);frozen_codec=Identity $frozenCodec;reference=Identity (Join-Path $PSScriptRoot 'reference.rs')}
}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Runner syntax'}
 $report.reference_extraction=Check-ReferenceExtraction
 Source (Join-Path $PSScriptRoot 'probe.rs');$report.imports=@($graph);$report.sources_before=@($sources)
 $report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum);if($sources.Count -ne 8 -or $report.source_bytes -gt 307200){throw 'Eight-source closure 300KiB'}
 $planPath=Join-Path $PSScriptRoot '../PACKED_INVERSE_PLAN_20261004.md'
 if((Identity $planPath).sha256 -cne '65E24089DC8F0C825029CE1B2CDB0BE7A1BBBBCBAA2829EFECFF64159514FF5D'){throw 'Final plan SHA'}
 if((Identity $frozenCodec).sha256 -cne 'AD21DA8FE3B2FB80BE3015E3BFD73EFBA52E2B01B5560BA04BBB8F3B6C531C3B'){throw 'Frozen codec SHA'}
 if((Identity $causalReportPath).sha256 -cne 'DB086C81EC77DD41EF3114C917081FC3FEC9495B879F1FE12BACEF9BC8B78AD3'){throw 'Frozen causal success report SHA'}
 $causalReport=Get-Content -Raw -LiteralPath $causalReportPath|ConvertFrom-Json -Depth 32 -DateKind String;if($causalReport.status -cne 'diagnostic-passed'){throw 'Frozen causal success status'}
 foreach($path in @($PSCommandPath,$originalRunner,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$planPath,$frozenCodec,$causalReportPath,(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),(Join-Path $PSScriptRoot 'reference-ledger.json'),(Join-Path $PSScriptRoot '../PACKED_INVERSE_MEMORY_API_NOTE_20261004.md'),(Join-Path $PSScriptRoot '../causal-direct-mix/RESULT_20261004.md'),(Join-Path $PSScriptRoot '../causal-direct-mix/verify-artifacts.ps1'),(Join-Path $project 'Cargo.toml'))){Pin-PackedFile $path}
 $report.identities_before=@($pins)
 $inputIdentity=Identity $fixedInputPath;if($inputIdentity.bytes -ne 2811006 -or $inputIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);CPU_quiet_verified=$false}
 if($report.environment.architecture -cne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.RAM_estimate_limit_bytes=167772160;$report.precomputed_boundary_worst_bytes=130023437;$report.BWT_phase_RAM_estimate_bytes=141598926
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1;$report.compile_limit_seconds=60;$report.native_limit_seconds=120
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE1MiB bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.native_calls=1;$record=Child $exe @('screen',$fixedInputPath) 120
 if($record.stderr){throw 'Native stderr'};$report.diagnostic=$record.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$d=$report.diagnostic
 if($d.status -cne 'passed' -or $d.kind -cne 'packed_inverse_private_layout_diagnostic' -or $d.small_plain_cases -ne 9 -or $d.internal_inverse_rejections -ne 11 -or $d.common_wrapper_rejections -ne 3 -or $d.alphabet_wrapper_rejections -ne 2 -or $d.length_wrapper_rejections -ne 1 -or $d.bit_roundtrip_checks -ne 8 -or $d.bit_rejections -ne 2 -or $d.fixed.input_reads -ne 1 -or $d.fixed.BWT_calls -ne 1 -or $d.fixed.pairs -ne 9 -or $d.fixed.timed_calls -ne 18 -or $d.fixed.warmups_each -ne 1 -or !$d.fixed.all_plain_direct_comparisons -or $d.boundaries.Count -ne 3 -or !$d.memory.ABI_checked -or $d.memory.API_calls -ne 1){throw 'Inverse bounded E2E contract'}
 $boundaryLengths=@(8388607,8388608,8388609);$boundaryRoutes=@('packed23','packed23','reference-fallback')
 for($i=0;$i -lt 3;$i++){$b=$d.boundaries[$i];$n=$boundaryLengths[$i];$scratch=if($i -lt 2){$n}else{0};if($b.n -ne $n -or $b.route -cne $boundaryRoutes[$i] -or !$b.all_plain_equal -or !$b.all_expected_zero -or $b.last_capacity -ne $n -or $b.reference_result_capacity -ne $n-1 -or $b.candidate_result_capacity -ne $n-1 -or $b.candidate_scratch_capacity_words -ne $scratch -or $b.reference_working_logical_bytes -ne 12*$n-1 -or $b.same_phase_RAM_estimate_bytes -ne 15*$n-2+4MB -or $b.same_phase_RAM_estimate_bytes -gt 160MB){throw 'Boundary route/plain/capacity contract'}}
 if($d.fixed.n -ne 2811007 -or $d.fixed.primary -ne 1762795 -or $d.fixed.last_capacity -ne 2811007 -or $d.fixed.reference_result_capacity -ne 2811006 -or $d.fixed.packed_result_capacity -ne 2811006 -or $d.fixed.packed_scratch_capacity_words -ne 2811007 -or $d.fixed.reference_working_logical_bytes -ne 33732083 -or $d.fixed.packed_working_capacity_bytes -ne 14055034 -or $d.fixed.same_phase_RAM_estimate_bytes -gt 49170413 -or $d.fixed.CPU_quiet_verified -or $d.fixed.result_comparison_and_caller_drop_timed -or !$d.fixed.scratch_allocate_initialize_guard_walk_free_timed -or $d.fixed.samples.Count -ne 9){throw 'Fixed timing/capacity contract'}
 $report.status=if($d.memory.measured -and !$d.memory.peak_gate_passed){'diagnostic-resource-unmet'}else{'diagnostic-passed'}
 $report.interpretation='Same-EXE inverse layout diagnostic only; CPU quiet unverified, caller result drop and all comparisons outside timing; no full decode/codec/7-Zip/portable-native claim.'
 $report.executable_after=Identity $exe;if(!(Same-PackedIdentity $report.executable_before $report.executable_after)){throw 'EXE changed'}
 $report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($report.owned_exe_processes){throw 'Owned EXE process remains'}
 $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output ownership/shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same-PackedIdentity $_ $now)){throw "Source changed: $($_.path)"};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same-PackedIdentity $_ $now)){throw "Pin changed: $($_.path)"};$now})
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;report=Identity (Join-Path $work 'report.json');executable=$report.executable_after;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.native_calls;final_guard_after_report_save=$finalGuard}|ConvertTo-Json -Depth 6
