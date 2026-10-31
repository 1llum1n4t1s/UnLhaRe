[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-hard-cut-exp-scale-20261004'
$exe=Join-Path $work 'exp-scale-o3.exe';$assembly=Join-Path $work 'exp-scale-o3.s'
$original=Join-Path $work 'report.json';$cleanup=Join-Path $work 'cleanup-unused-asm.json'
$output=Join-Path $work 'recovery.json';$helper=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1';$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$report=[ordered]@{status='preflight';children=@();compile_calls=0;total_native_calls=0;original_compile_calls=1;original_native_calls=0;speed_claimed=$false;adoption=$false}
$locks=[Collections.Generic.List[IO.FileStream]]::new();$pairs=0
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){(ConvertTo-Json -InputObject $a -Depth 32 -Compress) -ceq (ConvertTo-Json -InputObject $b -Depth 32 -Compress)}
function Save-Report{$j=$report|ConvertTo-Json -Depth 16;if([Text.Encoding]::UTF8.GetByteCount($j) -gt 262144){throw 'Recovery report capacity'};[IO.File]::WriteAllText($output,$j,[Text.UTF8Encoding]::new($false))}
Need (Test-Path -LiteralPath $output) $false 'Unused recovery output'
Need (Get-FileHash $original).Hash 'E25B175D89D6BFC799D03F635F7342BA5646CA02E55E334979233CC20F165F05' 'Original report SHA'
Need (Get-FileHash $helper).Hash 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85' 'Helper SHA'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Helper AST'}
foreach($name in @('Identity','Safe-Path','Child')){$defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Definition count';. ([scriptblock]::Create($defs[0].Extent.Text))}
$prior=Get-Content -LiteralPath $original -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Need $prior.status 'failed' 'Original failed status';Need $prior.compile_calls 1 'Compile completed';Need $prior.total_native_calls 0 'Native not started';if($prior.error -notlike '*exp-scale-o3.s*does not exist*'){throw 'Unexpected prior failure'}
foreach($kind in @('sources','identities')){
 $a=@($prior.($kind+'_before'));$b=@($prior.($kind+'_after'));Need $a.Count $b.Count 'Prior extent'
 for($i=0;$i -lt $a.Count;$i++){if(!(Same $a[$i] $b[$i]) -or !(Same $a[$i] (Identity (Safe-Path $a[$i].path)))){throw 'Prior before-after-live'};$locks.Add([IO.File]::Open($a[$i].path,'Open','Read','Read'));$pairs++}
}
Need (Identity $exe).sha256 '0285731721E89EABA6F66ED471F6D48134C7EC97B3BD9574BC369E2168209C87' 'Completed EXE SHA';Need (Identity $assembly).sha256 'B8506061CF20B9ED5F3ED473D87D10667EC6BF0E800BCA9E3124D50404C44FEB' 'Retained compiler assembly SHA'
if(!(Same $prior.executable_before (Identity $exe))){throw 'Original EXE identity'}
$ledger=Get-Content -LiteralPath $cleanup -Raw|ConvertFrom-Json -Depth 32 -DateKind String
Need $ledger.state 'complete' 'Cleanup complete';Need @($ledger.items).Count 13 'Unused asm count';foreach($item in $ledger.items){Need $item.sourceAbsent $true 'Source absent';Need $item.recycleAbsent $true 'Recycle absent';Need $item.metadataAbsent $true 'Metadata absent'}
$report.source_identity_pairs=$pairs;$report.sources_before=@($prior.sources_before);$report.identities_before=@($prior.identities_before);$report.original_report=Identity $original;$report.cleanup_ledger=Identity $cleanup;$report.executable_before=Identity $exe;$report.assembly_before=Identity $assembly
foreach($p in @($exe,$assembly,$original,$cleanup,$PSCommandPath)){$null=Safe-Path $p;$locks.Add([IO.File]::Open($p,'Open','Read','Read'))}
try{
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.total_native_calls=1;$child=Child $exe @() 60;if($child.stderr){throw 'Finite stderr'};$n=$child.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$report.finite=$n
 foreach($pair in @(@('status','passed'),@('operation','exp-scale-finite'),@('grid_cases',393312),@('random_cases',65536),@('boundary_cases',30),@('total_cases',458878),@('exact_result_comparisons',458878),@('mismatches',0),@('reference_constructor_calls',1),@('candidate_constructor_calls',1),@('cases_Vec',0),@('streamed_cases',$true),@('speed_claimed',$false),@('adoption',$false),@('Ok_bits_directly_compared',$true),@('Err_strings_and_class_directly_compared',$true))){Need $n.($pair[0]) $pair[1] 'Finite checks'}
 Need ($n.ok_cases+$n.error_cases) 458878 'Outcome census';if($n.results_digest -cnotmatch '^[0-9a-f]{16}$'){throw 'Digest shape'}
 $text=Get-Content -LiteralPath $assembly -Raw;$metrics=[ordered]@{}
 foreach($name in @('reference_exp','candidate_exp')){$m=[regex]::Matches($text,'(?ms)^'+$name+':\r?\n(.*?^\s*\.seh_endproc)');Need $m.Count 1 'Wrapper assembly body';$body=$m[0].Groups[1].Value;$metrics[$name]=@{scalar_divides=[regex]::Matches($body,'\bv?divsd\b').Count;scalar_multiplies=[regex]::Matches($body,'\bv?mulsd\b').Count;calls=[regex]::Matches($body,'\bcallq?\b').Count}}
 $report.assembly_metrics=$metrics;$report.generated_instruction_reduction_verified=$metrics.reference_exp.scalar_divides -gt $metrics.candidate_exp.scalar_divides;$report.status='finite-passed';$report.interpretation='Recovered missing named-assembly path from thin-LTO multi-output without extra compile. Original report preserved failed; 13 unused std ASM recycled/purged, local wrapper ASM retained. One finite native only. No full-codec/normal-speed/f64-global/native4/7-Zip adoption claim.'
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{$report.executable_after=Identity $exe;$report.assembly_after=Identity $assembly;if(!(Same $report.executable_before $report.executable_after) -or !(Same $report.assembly_before $report.assembly_after)){throw 'Generated identities changed'};$report.sources_after=@($report.sources_before|ForEach-Object {$v=Identity $_.path;if(!(Same $_ $v)){throw 'Source changed'};$v});$report.identities_after=@($report.identities_before|ForEach-Object {$v=Identity $_.path;if(!(Same $_ $v)){throw 'Pin changed'};$v});$report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;Need $report.owned_exe_processes 0 'Owned processes';$report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;Save-Report;$finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8}finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;recovery_report=Identity $output;additional_compile_calls=0;total_finite_native_calls=$report.total_native_calls;finite=$report.finite;assembly=$report.assembly_metrics;instruction_reduction=$report.generated_instruction_reduction_verified;disk=$finalGuard}|ConvertTo-Json -Depth 6
