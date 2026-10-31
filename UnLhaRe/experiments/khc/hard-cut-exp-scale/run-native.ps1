[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-hard-cut-exp-scale-20261004'
$exe=Join-Path $work 'exp-scale-o3.exe'
$assembly=Join-Path $work 'exp-scale-o3.s'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$helper=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
$sourceRoot=$PSScriptRoot
$created=$false;$locks=[Collections.Generic.List[IO.FileStream]]::new();$sources=[Collections.Generic.List[object]]::new();$graph=[Collections.Generic.List[object]]::new();$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();compile_calls=0;total_native_calls=0;diagnostic_only=$true;speed_claimed=$false;adoption=$false;disk_input_copies=0;raw_cases=0}
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){(ConvertTo-Json -InputObject $a -Depth 32 -Compress) -ceq (ConvertTo-Json -InputObject $b -Depth 32 -Compress)}
function LF([string]$p){[IO.File]::ReadAllText($p).Replace("`r`n","`n").TrimEnd()+"`n"}
Need (Get-FileHash $helper).Hash 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85' 'Frozen helper'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Helper AST'}
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Helper definition extent';$definition=$defs[0].Extent.Text
 if($name -ceq 'Source'){Need ([regex]::Matches($definition,[regex]::Escape('$PSScriptRoot'))).Count 1 'Source root binding count';$adapted=$definition.Replace('$PSScriptRoot','$sourceRoot');Need ($adapted.Replace('$sourceRoot','$PSScriptRoot')) $definition 'Helper fulltext root restoration';$definition=$adapted;$report.source_helper_root_replacements=1}
 . ([scriptblock]::Create($definition))
}
function Pin([string]$p){$p=Safe-Path $p;if(@($pins|Where-Object path -ceq $p).Count){return};$pins.Add((Identity $p));$locks.Add([IO.File]::Open($p,'Open','Read','Read'))}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'}
 $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 Source (Join-Path $PSScriptRoot 'probe.rs');Need $sources.Count 4 'Source count';Need $graph.Count 3 'Source edges';$report.sources_before=@($sources);$report.imports=@($graph);$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 $old=Join-Path $PSScriptRoot '../lookup-float-cts/float_math.rs';$fixed=Join-Path $PSScriptRoot '../quaternary-cts-integer-pool/fixed_math.rs'
 Need (Identity $old).sha256 '9349A09F011C051CBD3EB7927DAE509035EE86F2993991194536B7166C52F7F3' 'Old Math SHA';Need (Identity $fixed).sha256 'A599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACD' 'Canonical Math SHA'
 $oldText=LF $old;$newText=LF (Join-Path $PSScriptRoot 'scaled_math.rs');$oldSite='let result=interpolation/(1u64<<exponent) as f64;';$newSite='let result=interpolation*f64::from_bits((1023u64-u64::from(exponent))<<52);'
 Need ([regex]::Matches($oldText,[regex]::Escape($oldSite))).Count 1 'Old site count';Need ([regex]::Matches($newText,[regex]::Escape($newSite))).Count 1 'Candidate site count';Need ($newText.Replace($newSite,$oldSite)) $oldText 'Fulltext one-site restoration';$report.math_ledger=@{allowed_replacements=1;extra_residual=0;guard_cutoff_grid_order_allocation_unchanged=$true}
 $plan=Join-Path $PSScriptRoot '../HARD_CUT_EXP_SCALE_PLAN_20261004.md';Need (Identity $plan).sha256 '0F001B32AE8B7763BB656BC1F0D6F19D5A02EDB04E6EFFFA3F4F0CACB3B8464A' 'PLAN SHA'
 foreach($p in @($PSCommandPath,$helper,$guard,$compiler,(Get-Process -Id $PID).Path,$plan,(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'))){Pin $p};$report.identities_before=@($pins)
 if($report.source_bytes+(Identity $plan).bytes+(Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).bytes -gt 65536){throw 'Source and plan budget'}
 Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler SHA'
 $report.environment=@{cwd=$project;OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();PowerShell=$PSVersionTable.PSVersion.ToString()};if(![OperatingSystem]::IsWindows() -or $report.environment.architecture -cne 'X64'){throw 'Windows x64'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8;$null=New-Item -ItemType Directory -Path $work;$created=$true;Save-Report
 $version=Child $compiler @('--version') 60;Need $version.stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
 $report.compile_settings=@('--edition=2024','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','--emit',"link=$exe,asm=$assembly")
 $report.compile_calls=1;$null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings) 60
 $report.executable_before=Identity $exe;$report.assembly_before=Identity $assembly;if($report.executable_before.bytes -gt 1048576 -or $report.assembly_before.bytes -gt 2097152){throw 'Binary/asm budget'}
 $locks.Add([IO.File]::Open($exe,'Open','Read','Read'));$locks.Add([IO.File]::Open($assembly,'Open','Read','Read'))
 $report.total_native_calls=1;$native=Child $exe @() 60;if($native.stderr){throw 'Finite stderr'};$n=$native.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$report.finite=$n;Save-Report
 foreach($pair in @(@('status','passed'),@('operation','exp-scale-finite'),@('grid_cases',393312),@('random_cases',65536),@('boundary_cases',30),@('total_cases',458878),@('mismatches',0),@('reference_constructor_calls',1),@('candidate_constructor_calls',1),@('cases_Vec',0),@('speed_claimed',$false),@('adoption',$false),@('streamed_cases',$true))){Need $n.($pair[0]) $pair[1] 'Finite census'}
 Need $n.total_cases ($n.grid_cases+$n.random_cases+$n.boundary_cases) 'Group sum';Need $n.exact_result_comparisons $n.total_cases 'Every result compared';Need ($n.ok_cases+$n.error_cases) $n.total_cases 'Outcome count';if($n.total_cases -gt 500000 -or $n.boundary_cases -le 0 -or $n.results_digest -cnotmatch '^[0-9a-f]{16}$'){throw 'Finite bounds/digest'}
 $asmText=Get-Content -LiteralPath $assembly -Raw;$metrics=[ordered]@{}
 foreach($name in @('reference_exp','candidate_exp')){
  $bodies=[regex]::Matches($asmText,'(?ms)^'+$name+':\r?\n(.*?^\s*\.seh_endproc)');$body=if($bodies.Count -eq 1){$bodies[0].Groups[1].Value}else{''}
  $metrics[$name]=@{body_found=($bodies.Count -eq 1);body_count=$bodies.Count;scalar_divides=[regex]::Matches($body,'\bv?divsd\b').Count;scalar_multiplies=[regex]::Matches($body,'\bv?mulsd\b').Count;calls=[regex]::Matches($body,'\bcallq?\b').Count;source_scope='finite wrapper only; not ordinary codec CPU share'}
 }
 $report.assembly_metrics=$metrics;$report.generated_instruction_reduction_verified=($metrics.reference_exp.body_found -and $metrics.candidate_exp.body_found -and $metrics.reference_exp.scalar_divides -gt $metrics.candidate_exp.scalar_divides)
 $report.executable_after=Identity $exe;$report.assembly_after=Identity $assembly;if(!(Same $report.executable_before $report.executable_after) -or !(Same $report.assembly_before $report.assembly_after)){throw 'Generated file changed'}
 $report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($report.owned_exe_processes){throw 'Owned process remains'}
 $files=@(Get-ChildItem -LiteralPath $work -Force);if($files.Count -ne 3 -or @($files|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,$assembly,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
 $report.status='finite-passed';$report.interpretation='Exact finite Result bit/message comparison, no f64-global proof, no codec frame/Proof/normal speed/native4/7-Zip claim. Assembly scope finite wrappers only; unresolved or no division reduction is not a speed success.'
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{$report.sources_after=@($sources|ForEach-Object {$v=Identity $_.path;if(!(Same $_ $v)){throw 'Source changed'};$v});$report.identities_after=@($pins|ForEach-Object {$v=Identity $_.path;if(!(Same $_ $v)){throw 'Pin changed'};$v});$report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report;$finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8}finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));compile_calls=$report.compile_calls;native_calls=$report.total_native_calls;finite_cases=$report.finite.total_cases;instruction_reduction=$report.generated_instruction_reduction_verified;disk=$finalGuard}|ConvertTo-Json -Depth 6
