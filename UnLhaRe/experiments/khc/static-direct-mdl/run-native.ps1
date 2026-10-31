[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$frozenSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../float-fresh-transaction'))
$originalRunner=Join-Path $frozenSourceRoot 'run-native.ps1'
$originalRunnerSha='A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85'
$ownedRoot=Join-Path $project 'build/khc-static-direct-mdl-20261004'
$work=Join-Path $ownedRoot 'corrected-native'
$failureReport=Join-Path $ownedRoot 'report.json'
$exe=Join-Path $work 'static-direct-mdl-o3-thin.exe'
$header=Join-Path $work 'model-header.bin'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();diagnostic_only=$true;compile_calls=0;native_calls=0;disk_frame_plain_input_copies=0;raw_traces=0;frozen_entrypoints_executed=$false;setting_sweeps=0;independent_new_context_audit=$false;actual_coder_implemented=$false;performance_claimed=$false}
if((Get-FileHash -LiteralPath $originalRunner).Hash -cne $originalRunnerSha){throw 'Frozen runner pin'}
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($originalRunner,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Frozen runner syntax'}
$report.function_bindings=@()
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($definitions.Count -ne 1){throw "Function binding: $name"}
 $definition=$definitions[0].Extent.Text
 if($name -ceq 'Source'){$definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot')}
 . ([ScriptBlock]::Create($definition))
 $report.function_bindings+=@{name=$name;source=$originalRunner;sha256=$originalRunnerSha;source_root=$frozenSourceRoot}
}
function Pin-StaticFile([string]$Path){$null=Safe-Path $Path;$locks.Add([IO.File]::Open($Path,'Open','Read','Read'));$pins.Add((Identity $Path))}
function Same-StaticIdentity($A,$B){($A|ConvertTo-Json -Compress) -ceq ($B|ConvertTo-Json -Compress)}
function Check-StaticLedger{
 $ledger=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'observer-ledger.json')|ConvertFrom-Json -Depth 8 -DateKind String
 $text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $ledger.source)).Replace("`r`n","`n").TrimEnd("`n")+"`n"
 foreach($op in $ledger.operations){if(([regex]::Matches($text,[regex]::Escape($op.from))).Count -ne $op.count){throw 'Ledger match count'};$text=$text.Replace($op.from,$op.to)}
 $actual=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $ledger.destination)).Replace("`r`n","`n").TrimEnd("`n")+"`n"
 if($actual -cne $text -or $ledger.numerical_changes -ne 0){throw 'Whole observer source differs from exact ledger'}
 $report.observer_transform=@{operations=@($ledger.operations).Count;whole_source_equal=$true;numerical_changes=0;normalization=$ledger.normalization}
}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $failed=Get-Content -Raw -LiteralPath $failureReport|ConvertFrom-Json -Depth 32 -DateKind String
 if($failed.status -cne 'failed' -or $failed.compile_calls -ne 1 -or $failed.native_calls -ne 0 -or $failed.error -notmatch 'E0061'){throw 'Repair predecessor mismatch'}
 $report.repair=@{predecessor=$failureReport;compile_calls_total=2;native_calls_total=1;reason='Remove surplus run_restore wrapper arguments at two call sites; native never ran in failed compile; unchanged numerical model, observer, setting and input';changed_prior_pin_paths=@((Join-Path $PSScriptRoot 'probe.rs'),$PSCommandPath);failed_pins_are_historical_not_live_equal=$true}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Runner syntax'}
 Source (Join-Path $PSScriptRoot 'probe.rs');$report.imports=@($graph);$report.sources_before=@($sources)
 $report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum);$report.source_count=$sources.Count;if($report.source_bytes -gt 307200){throw 'Source closure bound'}
 foreach($path in @($PSCommandPath,$originalRunner,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,(Join-Path $PSScriptRoot '../STATIC_DIRECT_MDL_PLAN_20261004.md'),(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),(Join-Path $PSScriptRoot 'FORMAT_CONTRACT.md'),(Join-Path $PSScriptRoot 'observer-ledger.json'),(Join-Path $PSScriptRoot '../LOOKUP_FLOAT_CTS_RESULT_20261004.md'),(Join-Path $project 'build/khc-lookup-float-cts-20261004/report.json'),(Join-Path $project 'Cargo.toml'),$failureReport)){Pin-StaticFile $path}
 $report.identities_before=@($pins);Check-StaticLedger
 $fixedIdentity=Identity $fixedInputPath;if($fixedIdentity.bytes -ne 2811006 -or $fixedIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)}
 if($report.environment.architecture -cne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.disk_before=& $guard -WorkDirectory $ownedRoot -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1;$report.compile_limit_seconds=60;$report.native_limit_seconds=120
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 if(Test-Path -LiteralPath $header){throw 'Header create_new precondition'};$report.maximum_metadata_bytes=1048576
 $report.native_calls=1;$record=Child $exe @('screen',$fixedInputPath,$header) 120
 if($record.stderr){throw 'Unexpected native stderr'};$report.screen=$record.stdout|ConvertFrom-Json -Depth 32 -DateKind String
 if($report.screen.status -cne 'passed' -or $report.screen.cases -ne 6 -or $report.screen.header_rejections -ne 16){throw 'E2E screen counts'}
 $fixed=$report.screen.records[5];if($fixed.name -cne 'fixed' -or $fixed.reference_frame_bytes -ne 478750 -or $fixed.direct_tokens -ne 1778454 -or $fixed.old_branches -ne 3825340){throw 'Frozen reference totals'}
 $report.header_before=Identity $header;if($report.header_before.bytes -gt 1048576 -or $report.header_before.bytes -ne $fixed.model_bytes){throw 'Header artifact bound'};$locks.Add([IO.File]::Open($header,'Open','Read','Read'))
 $report.budget_candidate_qualified=[bool]$fixed.budget_gate_passed
 $report.status='diagnostic-passed';$report.conclusion=if($report.budget_candidate_qualified){'private metadata/loss candidate only; actual coder/roundtrip/size/speed unimplemented'}else{'one candidate rejected: serialized metadata plus estimated token loss exceeds 483599B; no sweep'}
 $report.executable_after=Identity $exe;$report.header_after=Identity $header
 if(!(Same-StaticIdentity $report.executable_before $report.executable_after) -or !(Same-StaticIdentity $report.header_before $report.header_after)){throw 'Output identity changed'}
 $report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($report.owned_exe_processes){throw 'Owned EXE remains'}
 $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 3 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,$header,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
 $report.output_file_count=$entries.Count;$report.output_files=@($entries|Select-Object FullName,Length)
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same-StaticIdentity $_ $now)){throw "Source changed: $($_.path)"};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same-StaticIdentity $_ $now)){throw "Pin changed: $($_.path)"};$now})
  $report.disk_after=& $guard -WorkDirectory $ownedRoot -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $finalGuard=& $guard -WorkDirectory $ownedRoot -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;budget_candidate_qualified=$report.budget_candidate_qualified;report=Identity (Join-Path $work 'report.json');header=$report.header_after;final_guard_after_report_save=$finalGuard;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.native_calls}|ConvertTo-Json -Depth 6
