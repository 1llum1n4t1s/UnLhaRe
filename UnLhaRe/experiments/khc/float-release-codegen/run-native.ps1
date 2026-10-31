[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$frozenSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../float-fresh-transaction'))
$originalRunner=Join-Path $frozenSourceRoot 'run-native.ps1'
$originalRunnerSha='A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85'
$oldReportPath=Join-Path $project 'build/khc-float-fresh-transaction-20261004/report.json'
$work=Join-Path $project 'build/khc-float-release-codegen-20261004'
$exe=Join-Path $work 'float-release-codegen-o3-thin-cgu1-unwind.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();diagnostic_only=$true;compile_calls=0;native_calls=0;source_numerical_changes=0;Rust_source_copies=0;disk_frame_plain_input_copies=0;raw_traces=0;old_entrypoints_executed=$false;setting_sweeps=0}
# 固定hashの関数ASTだけを読む。元runnerのentry pointは実行しない。
if((Get-FileHash -LiteralPath $originalRunner).Hash -cne $originalRunnerSha){throw 'Frozen runner pin'}
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($originalRunner,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Frozen runner syntax'}
$report.function_bindings=@()
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($definitions.Count -ne 1){throw "Frozen function binding: $name"}
 $definition=$definitions[0].Extent.Text
 # ScriptBlock.CreateはPSScriptRootを持たないので、源泉rootへ明示束縛する。
 if($name -ceq 'Source'){
  if(!$definition.Contains('$PSScriptRoot')){throw 'Source root binding absent'}
  $definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot')
 }
 . ([ScriptBlock]::Create($definition))
 $report.function_bindings+=@{name=$name;source_path=$originalRunner;source_sha256=$originalRunnerSha;source_root_binding=($name -ceq 'Source');source_root=$frozenSourceRoot}
}
function Pin-ReleaseCodegenFile([string]$Path){$null=Safe-Path $Path;$locks.Add([IO.File]::Open($Path,'Open','Read','Read'));$pins.Add((Identity $Path))}
function Same-ReleaseCodegenIdentity($A,$B){($A|ConvertTo-Json -Compress) -ceq ($B|ConvertTo-Json -Compress)}
function Invoke-ReleaseCodegenNative([string]$Operation){
 $arguments=if($Operation -in @('screen','abba')){@($Operation,$fixedInputPath)}else{@($Operation)}
 $report.native_calls++
 $record=Child $exe $arguments 120
 if($record.stderr){throw 'Unexpected native stderr'}
 $parsed=$record.stdout|ConvertFrom-Json -Depth 32 -DateKind String
 if($parsed.status -cne 'passed'){throw 'Native contract status'};return $parsed
}
function Same-ReleaseCodegenProof($A,$B){
 $names=@('runs','primary','alphabet','payload','plain_crc','payload_crc','rank','length','escape','grammar','base_pool','branches','classes','cdf_bits')
 if(@($A.PSObject.Properties).Count -ne 14 -or @($B.PSObject.Properties).Count -ne 14){throw 'Saved Proof14 field count'}
 foreach($name in $names){
  if(!$A.PSObject.Properties[$name] -or !$B.PSObject.Properties[$name]){throw 'Saved Proof14 field names'}
  $x=@($A.$name);$y=@($B.$name);if($x.Count -ne $y.Count){return $false}
  for($j=0;$j -lt $x.Count;$j++){if($x[$j] -ne $y[$j]){return $false}}
 }return $true
}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Runner syntax'}
 if((Get-FileHash -LiteralPath $oldReportPath).Hash -cne 'D21A852CCDE81624DBB3138838E722A1CF547E33AC0419B81CB618B884BD0507'){throw 'FT1 report pin'}
 $oldReport=Get-Content -Raw -LiteralPath $oldReportPath|ConvertFrom-Json -Depth 32 -DateKind String
 Source (Join-Path $frozenSourceRoot 'probe.rs');$report.imports=@($graph);$report.sources_before=@($sources)
 if($sources.Count -ne 19 -or $graph.Count -ne 18){throw 'Same nineteen-source eighteen-edge closure required'}
 $sourceBytes=[long](($sources|Measure-Object bytes -Sum).Sum);if($sourceBytes -gt 307200 -or $sourceBytes -ne 160965){throw 'Frozen source closure bound/pin'}
 $report.source_bytes=$sourceBytes;$report.source_count=$sources.Count
 foreach($entry in $sources){
  $oldEntries=@($oldReport.sources_before|Where-Object path -ceq $entry.path)
  if($oldEntries.Count -ne 1 -or !(Same-ReleaseCodegenIdentity $entry $oldEntries[0])){throw "FT1 frozen source changed: $($entry.path)"}
 }
 foreach($path in @($PSCommandPath,$originalRunner,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,(Join-Path $project 'Cargo.toml'),(Join-Path $PSScriptRoot '../FLOAT_RELEASE_CODEGEN_PLAN_20261004.md'),(Join-Path $PSScriptRoot '../FLOAT_FRESH_TRANSACTION_PLAN_20261004.md'),(Join-Path $PSScriptRoot '../FLOAT_TRANSACTION_SCOPE_20261004.md'),$oldReportPath,(Join-Path $project 'build/khc-float-fresh-transaction-20261004/float-fresh-o2-yes.exe'),(Join-Path $frozenSourceRoot 'RESULT_20261004.md'),(Join-Path $frozenSourceRoot 'verify-artifacts.ps1'))){Pin-ReleaseCodegenFile $path}
 $report.identities_before=@($pins)
 $inputIdentity=Identity $fixedInputPath;if($inputIdentity.bytes -ne 2811006 -or $inputIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Frozen input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $cargoText=[IO.File]::ReadAllText((Join-Path $project 'Cargo.toml'))
 if($cargoText -notmatch '(?s)\[profile\.release\]\s+lto = "thin"\s+codegen-units = 1\s+panic = "unwind"'){throw 'Cargo Release codegen basis changed'}
 $report.release_basis=@{path=(Join-Path $project 'Cargo.toml');lines=@(47,48,49,50);lto='thin';codegen_units=1;panic='unwind'}
 $report.codegen_settings_scope='Release-derived standalone codegen; overflowyes and diagnostic cfg differ from product Release; old opt2 timing comparison is descriptive only'
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;source_root=$frozenSourceRoot;CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();PowerShell=$PSVersionTable.PSVersion.ToString()}
 if($report.environment.process_architecture -ne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $frozenSourceRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE 1MiB bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.selfcheck=Invoke-ReleaseCodegenNative 'selfcheck';Save-Report
 if($report.selfcheck.fresh_rejections.fresh_named_rejections -ne 20 -or $report.selfcheck.fresh_rejections.rejected_callback_calls -ne 14 -or $report.selfcheck.standalone.normal_cases -ne 14 -or $report.selfcheck.standalone.malformed_cases -ne 33 -or $report.selfcheck.standalone.model_rejection_assertions -ne 26){throw 'Frozen E2E counts'}
 $report.screen=Invoke-ReleaseCodegenNative 'screen';Save-Report
 if($report.screen.cases -ne 5 -or !$report.screen.size_gate_passed -or $report.screen.fixed_frame_bytes -ne 478750){throw 'Size/equivalence gate'}
 $report.old_opt2_saved_Proof14_comparisons=0
 for($i=0;$i -lt 5;$i++){
  if(!(Same-ReleaseCodegenProof $report.screen.records[$i].proof $oldReport.screen.records[$i].proof)){throw 'Saved opt2 full typed Proof14 differs'}
  if(($report.screen.records[$i].stats|ConvertTo-Json -Compress) -cne ($oldReport.screen.records[$i].stats|ConvertTo-Json -Compress)){throw 'Saved opt2 all stats differ'}
  $report.old_opt2_saved_Proof14_comparisons++
 }
 $report.old_opt2_frame_comparison='No old opt2 frame held; only saved typed Proof14/stat values compared across compile. New EXE itself directly compared full reference/fresh frames and plain.'
 $report.ABBA=Invoke-ReleaseCodegenNative 'abba'
 $report.same_binary_both_directions_shorter=[bool]$report.ABBA.both_directions_shorter
 $report.old_opt2_descriptive_times=@{source_report=$oldReportPath;different_compile_and_timestamp=$true;formal_effect_rate_claimed=$false;records=$oldReport.ABBA.records|Select-Object index,method,encode_ns,decode_ns}
 $report.status='diagnostic-passed'
 $report.executable_after=Identity $exe;if(!(Same-ReleaseCodegenIdentity $report.executable_before $report.executable_after)){throw 'EXE changed'}
 $report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($report.owned_exe_processes){throw 'Owned EXE remains'}
 $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output ownership/shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same-ReleaseCodegenIdentity $_ $now)){throw "Source changed: $($_.path)"};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same-ReleaseCodegenIdentity $_ $now)){throw "Tool/input/frozen/Cargo identity changed: $($_.path)"};$now})
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;same_binary_both_directions_shorter=$report.same_binary_both_directions_shorter;report=Identity (Join-Path $work 'report.json');final_guard_after_report_save=$finalGuard;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.native_calls}|ConvertTo-Json -Depth 6
