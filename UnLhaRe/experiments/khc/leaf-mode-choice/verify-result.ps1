[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$reportPath=Join-Path $project 'build/khc-leaf-mode-choice-20261005/report.json'
if((Get-FileHash -LiteralPath $reportPath).Hash -cne 'PENDING_REPORT_SHA'){throw 'Report SHA'}
$r=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 64 -DateKind String
$runner=Join-Path $PSScriptRoot 'run-native.ps1'
if((Get-FileHash -LiteralPath $runner).Hash -cne 'PENDING_RUNNER_SHA'){throw 'Runner SHA'}
$tokens=$null;$errors=$null
$validationRoot=$PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Runner AST'}
foreach($name in @('Need','Same','Near','NearSigned','Validate-Global','Validate-Paid','Validate-LeafChoice')){
 $d=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($d.Count -ne 1){throw 'Validator definition'}
 $definition=$d[0].Extent.Text
 if($name -in @('Validate-Paid','Validate-LeafChoice')){
  $definition=$definition.Replace('$PSScriptRoot','$validationRoot')
  Need $definition.Replace('$validationRoot','$PSScriptRoot') $d[0].Extent.Text 'Validator exact root binding'
 }
 . ([scriptblock]::Create($definition))
}
function Identity([string]$p){$f=Get-Item -LiteralPath $p;if($f.PSIsContainer -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Identity shape'};[pscustomobject]@{path=$f.FullName;sha256=(Get-FileHash -LiteralPath $f.FullName).Hash;bytes=$f.Length;mtime_utc=$f.LastWriteTimeUtc.ToString('o')}}
$pairs=0
foreach($kind in @('sources','identities')){
 $a=@($r.($kind+'_before'));$b=@($r.($kind+'_after'));Need $a.Count $b.Count 'Pair count'
 for($i=0;$i -lt $a.Count;$i++){Need (Same $a[$i] $b[$i]) $true 'Before/after';Need (Same $a[$i] (Identity $a[$i].path)) $true 'Live';$pairs++}
}
Need (Same $r.executable_before $r.executable_after) $true 'EXE pair';Need (Same $r.executable_before (Identity $r.executable_before.path)) $true 'EXE live';$pairs++
Need $r.status 'diagnostic-passed' 'Report status';Need $r.compile_calls 1 'Compile census';Need $r.total_native_calls 1 'Native census'
Need @($r.children).Count 3 'Version/compile/native children'
foreach($child in $r.children){Need $child.exit_code 0 'Child exit';Need $child.failure $null 'Child failure'}
foreach($child in $r.children){Need $child.stderr '' 'Child stderr'}
$raw=$r.children[2].stdout|ConvertFrom-Json -Depth 64 -DateKind String
Need (Same $raw $r.screen) $true 'Raw record'
$prior=Get-Content -Raw (Join-Path $project 'build/khc-paid-code-tree-20261005/report.json')|ConvertFrom-Json -Depth 64 -DateKind String
Validate-Global $raw $prior
Validate-Paid $raw $prior
Validate-LeafChoice $raw $prior
Need $raw.node_columns.Count 8 'Schema'
for($c=0;$c -lt 2;$c++){
 $original=0.0;$delta=0.0;foreach($row in $raw.nodes[$c]){$original+=$row[6];$delta+=$row[7]}
 Near $original $raw.same_selected_tree_original_Q_component_loss_bits[$c]
 NearSigned $delta $raw.approx_component_loss_delta_bits[$c]
}
foreach($f in @('Dense_instances_simultaneous','Forest_instances_simultaneous','packet_instances_simultaneous','node_scratch_instances_simultaneous')){Need $raw.$f 1 'Instance bound'}
Need $raw.packet_files_saved 0 'No packet files';Need $raw.peak_resource_gate_passed $true 'OS peak gate'
Need $raw.model_RAM_limit_bytes 33554432 'Model limit';Need $raw.fixed_phase_RAM_limit_bytes 67108864 'Phase limit';Need $raw.RAM_limit_bytes 167772160 'Peak limit'
$dir=Split-Path $reportPath;$files=@(Get-ChildItem -LiteralPath $dir -Force);Need $files.Count 2 'Output files'
$bytes=[long](($files|Measure-Object Length -Sum).Sum)
if($bytes -gt 8388608 -or $files.Where({$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output capacity/shape'}
Need @(Get-Process|Where-Object Path -eq $r.executable_before.path).Count 0 'Native process ended'
[pscustomobject]@{status='readonly-passed';before_after_live_pairs=$pairs;raw_records=1;compile_calls=0;native_calls=0;writes=0;compiler_style_warnings=0;screen_bytes=$raw.screen_bytes;gate_gap_bytes=$raw.screen_bytes-483599;actual_metadata_bytes=$raw.bundle_bytes;token_bytes=$raw.Q_token_bytes_ceil;objective_delta_bits=$raw.objective_delta_bits_from_repriced_baseline;output_bytes=$bytes;free_bytes=(Get-PSDrive C).Free}|ConvertTo-Json

