[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$frozenSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../float-fresh-transaction'))
$originalRunner=Join-Path $frozenSourceRoot 'run-native.ps1'
$originalRunnerSha='A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85'
$work=Join-Path $project 'build/khc-direct-feature-opportunity-20261004'
$exe=Join-Path $work 'direct-feature-opportunity-o3-thin.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$staticReportPath=Join-Path $project 'build/khc-static-direct-mdl-20261004/corrected-native/report.json'
$staticHeaderPath=Join-Path $project 'build/khc-static-direct-mdl-20261004/corrected-native/model-header.bin'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();compile_calls=0;native_calls=0;diagnostic_only=$true;old_entrypoints_executed=$false;setting_sweeps=0;raw_traces=0;disk_frame_plain_input_copies=0;actual_model_serialized=$false;frame_encodes=0;frame_decodes=0;new_context_independent_audit=$false}
if((Get-FileHash -LiteralPath $originalRunner).Hash -cne $originalRunnerSha){throw 'Frozen runner pin'}
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($originalRunner,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Frozen runner syntax'}
$report.function_bindings=@()
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($definitions.Count -ne 1){throw "Function binding: $name"}
 $definition=$definitions[0].Extent.Text;if($name -ceq 'Source'){$definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot')};. ([ScriptBlock]::Create($definition))
 $report.function_bindings+=@{name=$name;source=$originalRunner;sha256=$originalRunnerSha;source_root=$frozenSourceRoot}
}
function Pin-FeatureFile([string]$Path){$resolved=Safe-Path $Path;if(@($pins|Where-Object path -ceq $resolved).Count){return};$locks.Add([IO.File]::Open($resolved,'Open','Read','Read'));$pins.Add((Identity $resolved))}
function Same-FeatureIdentity($A,$B){foreach($field in @('path','sha256','bytes','mtime_utc')){if($A.$field -cne $B.$field){return $false}};return $true}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Runner syntax'}
 if((Identity $staticReportPath).sha256 -cne 'DCFBB1001CBC1BD43956B2F92255210BCFAE79B831C4D08FB140D1B871628C5F' -or (Identity $staticHeaderPath).sha256 -cne '5AF91F901A45AAA66DC30ABD737C21E5E5C41483AB03E814A7BFE45F9DEA8F7D'){throw 'Frozen static report/header SHA'}
 $staticReport=Get-Content -Raw -LiteralPath $staticReportPath|ConvertFrom-Json -Depth 32 -DateKind String
 if($staticReport.status -cne 'diagnostic-passed' -or $staticReport.screen.records[5].truncated_loss_bits -ne 5000107.114226128){throw 'Frozen static success contract'}
 $report.frozen_static_source_checks=0
 foreach($entry in $staticReport.sources_before){$after=@($staticReport.sources_after|Where-Object path -ceq $entry.path);if($after.Count -ne 1 -or !(Same-FeatureIdentity $entry $after[0]) -or !(Same-FeatureIdentity $entry (Identity $entry.path))){throw 'Frozen static source drift'};Pin-FeatureFile $entry.path;$report.frozen_static_source_checks++}
 if($report.frozen_static_source_checks -ne 19){throw 'Frozen static source count'}
 Source (Join-Path $PSScriptRoot 'probe.rs');$report.imports=@($graph);$report.sources_before=@($sources)
 $report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum);$report.source_count=$sources.Count;if($sources.Count -ne 7 -or $report.source_bytes -gt 307200){throw 'Seven-source closure/bound'}
 foreach($path in @($PSCommandPath,$originalRunner,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$staticReportPath,$staticHeaderPath,(Join-Path $PSScriptRoot '../DIRECT_FEATURE_OPPORTUNITY_PLAN_20261004.md'),(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),(Join-Path $PSScriptRoot '../static-direct-mdl/RESULT_20261004.md'),(Join-Path $PSScriptRoot '../static-direct-mdl/observer-ledger.json'),(Join-Path $PSScriptRoot '../static-direct-mdl/verify-artifacts.ps1'),(Join-Path $project 'Cargo.toml'))){Pin-FeatureFile $path}
 $report.identities_before=@($pins)
 $fixedIdentity=Identity $fixedInputPath;if($fixedIdentity.bytes -ne 2811006 -or $fixedIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)}
 if($report.environment.architecture -cne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1;$report.compile_limit_seconds=60;$report.native_limit_seconds=120
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.native_calls=1;$record=Child $exe @('diagnose',$fixedInputPath,$staticHeaderPath) 120
 if($record.stderr){throw 'Unexpected native stderr'};$report.diagnostic=$record.stdout|ConvertFrom-Json -Depth 32 -DateKind String
 if($report.diagnostic.status -cne 'passed' -or $report.diagnostic.family_count -ne 4 -or $report.diagnostic.input_reads -ne 1 -or $report.diagnostic.BWT_calls -ne 1 -or $report.diagnostic.history_hand_checks -ne 90 -or $report.diagnostic.aggregate_hand_checks -ne 8 -or $report.diagnostic.baseline_absolute_difference_bits -gt 1e-6){throw 'Diagnostic E2E/baseline contract'}
 $report.status='diagnostic-passed';$report.interpretation='Four fixed training-only direct-feature opportunity diagnostics; no old expert/node/hash reproduction, no actual model serialization, codec, holdout, speed or product adoption.'
 $report.executable_after=Identity $exe;if(!(Same-FeatureIdentity $report.executable_before $report.executable_after)){throw 'EXE changed'}
 $report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($report.owned_exe_processes){throw 'Owned EXE remains'}
 $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same-FeatureIdentity $_ $now)){throw "Source changed: $($_.path)"};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same-FeatureIdentity $_ $now)){throw "Pin changed: $($_.path)"};$now})
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;report=Identity (Join-Path $work 'report.json');executable=$report.executable_after;final_guard_after_report_save=$finalGuard;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.native_calls}|ConvertTo-Json -Depth 6
