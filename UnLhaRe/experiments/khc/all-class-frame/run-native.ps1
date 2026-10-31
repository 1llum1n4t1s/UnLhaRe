[CmdletBinding()]
param([switch]$PreflightOnly,[ValidateSet('initial','repair1')][string]$Attempt='initial')
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project $(if($Attempt -eq 'initial'){'build/khc-all-class-frame-20261005'}else{'build/khc-all-class-frame-20261005-repair1'})
$exe=Join-Path $work 'all-class-frame-o3.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$helper=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
$frozenSourceRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($helper))
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';attempt=$Attempt;children=@();started_utc=[DateTime]::UtcNow.ToString('o');compile_calls=0;total_native_calls=0;frozen_entrypoints_executed=$false;raw_traces=0;disk_frame_plain_input_copies=0;diagnostic_only=$true;product_integration_verified=$false}
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 64) -ceq ($b|ConvertTo-Json -Compress -Depth 64)}
Need (Get-FileHash -LiteralPath $helper).Hash 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85' 'Frozen helper SHA'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Helper AST'}
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Helper definition'
 $definition=$defs[0].Extent.Text
 if($name -eq 'Source'){$definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot');Need $definition.Replace('$frozenSourceRoot','$PSScriptRoot') $defs[0].Extent.Text 'Exact source root binding'}
 . ([scriptblock]::Create($definition))
}
function Pin([string]$p){$p=Safe-Path $p;if(@($pins|Where-Object path -eq $p).Count){return};$pins.Add((Identity $p));$locks.Add([IO.File]::Open($p,'Open','Read','Read'))}
function Validate-Frame($n){
 Need $n.status 'passed' 'Native status';Need $n.kind 'all_class_frame_roundtrip' 'Frame scope'
 foreach($v in @(@('fixed_input_bytes',2811006),@('fixed_encode_calls',3),@('fixed_decode_calls',3),@('fixed_BWT_calls',3),@('fixed_Fit_builds',1704),@('fixed_root_CDF_comparisons',2617344),@('frames_retained_at_once',1),@('teacher_models_executed',0),@('raw_files_saved',0))){Need $n.($v[0]) $v[1] "Fixed census $($v[0])"}
 foreach($f in @('fixed_byte_exact','OS_resource_gate_passed')){Need $n.$f $true "Positive gate $f"}
 foreach($f in @('CRC_is_authentication','seven_zip_superiority_verified','speed_superiority_verified','product_integration_verified')){Need $n.$f $false "Claim boundary $f"}
 Need @($n.fixed_blocks).Count 3 'Block count'
 $raw=0L;$frames=0L;$enc=0L;$dec=0L;$bwt=0;$walks=0;$fits=0;$cdfs=0;$stored=0;$compressed=0
 for($i=0;$i -lt 3;$i++){
  $b=$n.fixed_blocks[$i];Need $b.index $i 'Block index';Need $b.header_bytes 40 'Header size';Need $b.byte_exact $true 'Direct block byte comparison'
  Need $b.raw_bytes (@(1048576,1048576,713854)[$i]) 'Exact chunk boundary'
  Need $b.frame_bytes (40+$b.alphabet_bytes+$b.metadata_bytes+$b.payload_bytes) 'Complete frame expense'
  if($b.frame_bytes -gt $b.raw_bytes+40 -or $b.method -notin @(0,1)){throw 'Canonical stored/compressed size'}
  if($b.method -eq 0){Need $b.alphabet_bytes 0 'Stored alphabet';Need $b.metadata_bytes 0 'Stored metadata';Need $b.payload_bytes $b.raw_bytes 'Stored exact payload';$stored++}else{
   if($b.frame_bytes -ge $b.raw_bytes+40){throw 'Compressed strict benefit'}
   Need $b.encode_branches $b.decode_branches 'Actual range grammar branches'
   Need $b.Fit_builds 568 'Block Fit builds';Need $b.root_writes 852 'Block root writes';Need $b.root_CDF_comparisons 872448 'Block CDF direct equality';Need $b.grammar_walks 2 'Block train/encode walks';$compressed++
  }
  foreach($f in @('encode_capacity_bound_bytes','decode_capacity_bound_bytes')){if($b.$f -le 0 -or $b.$f -gt 67108864){throw "Block capacity $f"}}
  if($b.scratch_bound_bytes -le 0 -or $b.scratch_bound_bytes -gt 65536 -or $b.encode_ns -le 0 -or $b.decode_ns -le 0){throw 'Block scratch/timer'}
  $raw+=$b.raw_bytes;$frames+=$b.frame_bytes;$enc+=$b.encode_ns;$dec+=$b.decode_ns;$bwt+=$b.BWT_calls;$walks+=$b.grammar_walks;$fits+=$b.Fit_builds;$cdfs+=$b.root_CDF_comparisons
 }
 foreach($v in @(@('fixed_input_bytes',$raw),@('actual_frame_bytes_total',$frames),@('actual_encode_ns_total',$enc),@('actual_decode_ns_total',$dec),@('fixed_BWT_calls',$bwt),@('fixed_grammar_walks',$walks),@('fixed_Fit_builds',$fits),@('fixed_root_CDF_comparisons',$cdfs),@('fixed_stored_blocks',$stored),@('fixed_compressed_blocks',$compressed))){Need $n.($v[0]) $v[1] "Fixed aggregate $($v[0])"}
 if($n.fixed_input_read_calls -lt 4){throw 'Exact input and EOF read census'}
 Need @($n.finite_E2E.cases).Count 9 'Finite case count'
 foreach($v in @(@('input_bytes_total',3170561),@('input_budget_bytes',4194304),@('maximum_input_including_rejected',1048577),@('encode_calls',10),@('decode_calls',9),@('oversize_encode_rejections',1))){Need $n.finite_E2E.($v[0]) $v[1] "Finite census $($v[0])"}
 Need $n.finite_E2E.byte_exact $true 'Finite byte exact';Need $n.finite_E2E.RAM_only $true 'Finite RAM only'
 Need ($n.finite_E2E.stored_cases+$n.finite_E2E.compressed_cases) 9 'Finite paths total'
 if($n.finite_E2E.stored_cases -le 0 -or $n.finite_E2E.compressed_cases -le 0){throw 'Both codec methods required'}
 foreach($v in @(@('fault_cases',30),@('rejections',30),@('same_process_recoveries',30),@('decode_calls',61),@('BWT_calls',0),@('Fit_builds',0),@('input_reads',0))){Need $n.adversarial_E2E.($v[0]) $v[1] "Fault census $($v[0])"}
 Need @($n.adversarial_E2E.exact_reasons).Count 30 'Fault reasons'
 foreach($f in @('normal_witness_byte_exact','LF_cycle_rejection_observed','noncanonical_escape_rejection_observed','oversize_declaration_rejected_before_allocation','RAM_only')){Need $n.adversarial_E2E.$f $true "Fault gate $f"}
 Need $n.adversarial_E2E.OS_chaos_executed $false 'No OS chaos claim'
 foreach($part in @($n,$n.finite_E2E,$n.adversarial_E2E)){if($part.max_codec_capacity_bound_bytes -le 0 -or $part.max_codec_capacity_bound_bytes -gt 67108864){throw 'Finite/fixed codec capacity bound'}}
 foreach($part in @($n,$n.finite_E2E)){if($part.max_scratch_bound_bytes -le 0 -or $part.max_scratch_bound_bytes -gt 65536){throw 'Scratch bound'}}
 Need $n.memory.measured $true 'OS peak measurement'
 foreach($f in @('peak_working_set_bytes','peak_private_commit_bytes')){if($n.memory.$f -le 0 -or $n.memory.$f -gt 167772160){throw "OS memory $f"}}
}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'}
 $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 $pinFile=Join-Path $PSScriptRoot 'source-pins.json'
 $candidate=Get-Content -Raw -LiteralPath $pinFile|ConvertFrom-Json -DateKind String -Depth 8
 Need @($candidate).Count 5 'Candidate pins';$candidateBytes=0L
 foreach($x in $candidate){if($x.name -notin @('FAILURE_PLAN.md','probe.rs','codec.rs','finite.rs','adversarial.rs')){throw 'Candidate pin name'};$p=Join-Path $PSScriptRoot $x.name;$id=Identity $p;Need $id.sha256 $x.sha256 'Candidate source SHA';Need $id.bytes $x.bytes 'Candidate source bytes';$candidateBytes+=$id.bytes;Pin $p}
 if(@($candidate.name|Sort-Object -Unique).Count -ne 5 -or $candidateBytes -gt 65536){throw 'Candidate capacity/uniqueness'}
 Source (Join-Path $PSScriptRoot 'probe.rs')
 $report.sources_before=@($sources);$report.imports=@($graph);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 if($report.source_bytes -gt 358400){throw 'Source closure capacity'}
 foreach($s in $sources){if([IO.File]::ReadAllText($s.path) -match '#\[global_allocator\]'){throw 'Custom allocator'}}
 $priorPath=Join-Path $project 'build/khc-all-class-static-20261005/report.json'
 Need (Identity $priorPath).sha256 '4615DF9E1894AE0EC7F797E14C3A224AD092A4B7708CDDDE40ADA170CA98D0EF' 'Frozen static result'
 if($Attempt -eq 'repair1'){
  $failurePath=Join-Path $project 'build/khc-all-class-frame-20261005/report.json'
  Need (Identity $failurePath).sha256 '7BD3FCED6B13EE0461B90A9B835DCAC63BC1AC25C89460924F116910AD98EA20' 'Initial compile failure preserved'
  $failure=Get-Content -Raw -LiteralPath $failurePath|ConvertFrom-Json -Depth 64 -DateKind String
  Need $failure.status 'failed' 'Initial failure status';Need $failure.compile_calls 1 'Initial failed compile count';Need $failure.total_native_calls 0 'No initial native execution'
  foreach($p in @($failurePath,(Join-Path $PSScriptRoot 'verify-repair.ps1'),(Join-Path $PSScriptRoot '../ALL_CLASS_FRAME_REPAIR_20261005.md'))){Pin $p}
  $report.initial_failed_compile_calls=1;$report.initial_failed_native_calls=0
 }
 foreach($p in @($PSCommandPath,$pinFile,$helper,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$priorPath,(Join-Path $PSScriptRoot '../ALL_CLASS_FRAME_PLAN_20261005.md'),(Join-Path $PSScriptRoot '../all-class-static/RESULT_20261005.md'))){Pin $p}
 $report.identities_before=@($pins)
 Need (Identity $fixedInputPath).sha256 '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' 'Input SHA';Need (Identity $fixedInputPath).bytes 2811006 'Input bytes'
 Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler SHA'
 Need (Identity (Get-Process -Id $PID).Path).sha256 '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' 'PowerShell SHA'
 if(![OperatingSystem]::IsWindows() -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64'){throw 'Windows x64 required'}
 $report.environment=@{CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();child_cwd=$project}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 if($PreflightOnly){$report.status='preflight-passed'}else{
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
  $v=Child $compiler @('--version') 60;Need $v.stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
  $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE');$report.compile_limit_seconds=60;$report.native_limit_seconds=120;$report.compile_calls=1
  $compile=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60;$report.compiler_stderr_present=[bool]$compile.stderr
  $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE capacity'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
  $report.total_native_calls=1;$native=Child $exe @('screen',$fixedInputPath) 120
  if($native.stderr){throw 'Native stderr'};Need @($native.stdout -split "\n"|Where-Object {$_}).Count 1 'One raw JSON record'
  $n=$native.stdout|ConvertFrom-Json -Depth 64 -DateKind String;$report.screen=$n;Save-Report;Validate-Frame $n
  $report.executable_after=Identity $exe;Need (Same $report.executable_before $report.executable_after) $true 'EXE unchanged'
  $report.owned_exe_processes=@(Get-Process|Where-Object Path -eq $exe).Count;Need $report.owned_exe_processes 0 'Owned process remains'
  $entries=@(Get-ChildItem -LiteralPath $work -Force);Need $entries.Count 2 'Output count'
  if(@($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
  $report.status='diagnostic-passed'
 }
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;Need (Same $_ $now) $true 'Source changed';$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;Need (Same $_ $now) $true 'Pin changed';$now})
  $report.ended_utc=[DateTime]::UtcNow.ToString('o');$report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;Save-Report
  $finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.total_native_calls;actual_frame_bytes=$report.screen.actual_frame_bytes_total;disk=$finalGuard}|ConvertTo-Json -Depth 5
