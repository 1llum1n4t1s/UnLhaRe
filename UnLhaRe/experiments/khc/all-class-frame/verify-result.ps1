[CmdletBinding()]
param([ValidateSet('initial','repair1')][string]$Attempt='repair1')
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project $(if($Attempt -eq 'initial'){'build/khc-all-class-frame-20261005'}else{'build/khc-all-class-frame-20261005-repair1'})
$reportPath=Join-Path $work 'report.json';$runner=Join-Path $PSScriptRoot 'run-native.ps1'
$r=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -DateKind String -Depth 64
if($r.status -cne 'diagnostic-passed'){throw 'Successful native report required'}
$runnerPins=@($r.identities_before|Where-Object path -eq ([IO.Path]::GetFullPath($runner)))
if($runnerPins.Count -ne 1 -or (Get-FileHash -LiteralPath $runner).Hash -cne $runnerPins[0].sha256){throw 'Recorded runner identity'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Runner AST'}
foreach($name in @('Need','Same','Validate-Frame')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($defs.Count -ne 1){throw 'Validator definition'}
 . ([scriptblock]::Create($defs[0].Extent.Text))
}
$helper=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
Need (Get-FileHash -LiteralPath $helper).Hash 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85' 'Helper identity'
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Helper AST'}
foreach($name in @('Identity','Safe-Path')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Identity definition'
 . ([scriptblock]::Create($defs[0].Extent.Text))
}
$pairs=0
foreach($kind in @('sources','identities')){
 $a=@($r.($kind+'_before'));$b=@($r.($kind+'_after'));Need $a.Count $b.Count 'Identity pair count'
 for($i=0;$i -lt $a.Count;$i++){Need (Same $a[$i] $b[$i]) $true 'Recorded before/after';$null=Safe-Path $a[$i].path;Need (Same $a[$i] (Identity $a[$i].path)) $true 'Live identity';$pairs++}
}
Need (Same $r.executable_before $r.executable_after) $true 'Recorded executable pair'
Need (Same $r.executable_before (Identity $r.executable_before.path)) $true 'Live executable';$pairs++
Need $r.compile_calls 1 'Compile census';Need $r.total_native_calls 1 'Native census';Need @($r.children).Count 3 'Child census'
foreach($child in $r.children){Need $child.exit_code 0 'Child exit';if($child.failure -or $child.elapsed_ms -le 0){throw 'Child failure/timer'}}
Need $r.children[0].stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
Need $r.children[1].file $r.children[0].file 'Compiler identity';Need $r.children[2].file $r.executable_before.path 'Native identity'
Need (Same $r.children[2].arguments @('screen',(Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'))) $true 'Native arguments'
if($r.children[0].elapsed_ms -gt 60000 -or $r.children[1].elapsed_ms -gt 60000 -or $r.children[2].elapsed_ms -gt 120000){throw 'Deadline'}
Need $r.children[2].stderr '' 'Native stderr';Need @($r.children[2].stdout -split "\n"|Where-Object {$_}).Count 1 'One raw record'
$raw=$r.children[2].stdout|ConvertFrom-Json -Depth 64 -DateKind String;Need (Same $raw $r.screen) $true 'Raw record equality'
Validate-Frame $raw
Need $r.frozen_entrypoints_executed $false 'No baseline native rerun';Need $r.product_integration_verified $false 'Not yet integrated'
Need @((Get-Process|Where-Object Path -eq $r.executable_before.path)).Count 0 'No owned native process'
$entries=@(Get-ChildItem -LiteralPath $work -Force);Need $entries.Count 2 'Output count'
if(@($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($reportPath,$r.executable_before.path) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
$disk=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';before_after_live_pairs=$pairs;raw_records=1;compile_calls=0;native_calls=0;writes=0;actual_frame_bytes=$raw.actual_frame_bytes_total;fixed_byte_exact=$raw.fixed_byte_exact;finite_roundtrips=$raw.finite_E2E.decode_calls;fault_rejections=$raw.adversarial_E2E.rejections;product_integration_verified=$false;disk=$disk}|ConvertTo-Json -Depth 5
