[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-convex-envelope-20261004'
$exe=Join-Path $work 'convex-envelope.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$frozenSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../float-fresh-transaction'))
$helper=Join-Path $frozenSourceRoot 'run-native.ps1'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';children=@();compile_calls=0;native_calls=0;started_utc=[DateTime]::UtcNow.ToString('o');oracle_not_codec=$true}
if((Get-FileHash -LiteralPath $helper).Hash -cne 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85'){throw 'Frozen helper identity'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Helper syntax'}
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $definitions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($definitions.Count -ne 1){throw 'Helper binding'}
 $body=$definitions[0].Extent.Text;if($name -ceq 'Source'){$body=$body.Replace('$PSScriptRoot','$frozenSourceRoot')};. ([scriptblock]::Create($body))
}
function Pin([string]$Path){$p=Safe-Path $Path;if(@($pins|Where-Object path -eq $p).Count){return};$locks.Add([IO.File]::Open($p,'Open','Read','Read'));$pins.Add((Identity $p))}
function Same($a,$b){($a|ConvertTo-Json -Compress) -ceq ($b|ConvertTo-Json -Compress)}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner syntax'}
 Source (Join-Path $PSScriptRoot 'probe.rs');if($sources.Count -ne 11 -or $graph.Count -ne 10 -or ($sources|Measure-Object bytes -Sum).Sum -gt 307200){throw 'Source closure'}
 $report.sources_before=@($sources);$report.imports=@($graph)
 $oldPath=Join-Path $project 'build/khc-direct-exact-context-20261004/report.json';if((Identity $oldPath).sha256 -cne '395911C6D71079AF4E739E4C1CF8482F0089BDA02EDD88E51E274199A0C9A305'){throw 'Exact frozen report'}
 $old=Get-Content -LiteralPath $oldPath -Raw|ConvertFrom-Json -Depth 32 -DateKind String
 foreach($id in $old.sources_before){if(!(Same $id (Identity $id.path))){throw 'Frozen exact source changed'};Pin $id.path}
 foreach($path in @($PSCommandPath,$guard,$helper,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$oldPath,(Join-Path $PSScriptRoot '../DIRECT_CONVEX_ENVELOPE_PLAN_20261004.md'))){Pin $path}
 $report.identities_before=@($pins)
 $id=Identity $fixedInputPath;if($id.bytes -ne 2811006 -or $id.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler SHA'}
 if(![OperatingSystem]::IsWindows() -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64'){throw 'Windows x64 required'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $report.compile_calls=1;$null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.native_calls=1;$native=Child $exe @($fixedInputPath) 120;if($native.stderr){throw 'Native stderr'};$n=$native.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$report.screen=$n
 if($n.status -cne 'passed' -or !$n.oracle_not_codec -or $n.events -ne 1778454 -or $n.fixtures_normal -ne 5 -or $n.fixtures_rejected -ne 6 -or $n.terminal_nodes -ne 29483040 -or $n.extra_free_frequency_units -ne 2){throw 'Native contract'}
 if([math]::Abs($n.baseline_Q_bits-4510058.854214707) -gt 0.000001 -or [math]::Abs(($n.optimistic_component_bits[0]+$n.optimistic_component_bits[1])-$n.optimistic_Q_bits) -gt 0.000001 -or $n.optimistic_screen_bytes -ne [math]::Ceiling($n.optimistic_Q_bits/8)+3079 -or $n.necessary_size_condition_has_room -ne ($n.optimistic_screen_bytes -le 483599)){throw 'Envelope arithmetic'}
 $report.status=if($n.peak_resource_gate_passed -eq $false){'resource-unmet'}else{'diagnostic-passed'}
 $report.executable_after=Identity $exe;if(!(Same $report.executable_before $report.executable_after)){throw 'EXE changed'}
 $report.owned_processes=@(Get-Process|Where-Object Path -eq $exe).Count;if($report.owned_processes){throw 'Owned process remains'}
 $items=@(Get-ChildItem -LiteralPath $work -Force);if($items.Count -ne 2 -or @($items|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json'))}).Count){throw 'Output shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same $_ $now)){throw 'Source changed'};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same $_ $now)){throw 'Pin changed'};$now})
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $final=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($s in $locks){$s.Dispose()}}
}
[pscustomobject]@{status=$report.status;screen=$report.screen;report=Identity (Join-Path $work 'report.json');final_guard=$final;compile_calls=$report.compile_calls;native_calls=$report.native_calls}|ConvertTo-Json -Depth 7
