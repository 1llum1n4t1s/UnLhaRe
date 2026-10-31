[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 64) -ceq ($b|ConvertTo-Json -Compress -Depth 64)}
function Identity([string]$path){$p=[IO.Path]::GetFullPath($path);$i=Get-Item -LiteralPath $p -Force;if($i.PSIsContainer -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Identity link'};[pscustomobject]@{path=$p;sha256=(Get-FileHash -LiteralPath $p).Hash;bytes=$i.Length;mtime_utc=$i.LastWriteTimeUtc.ToString('o')}}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-temporal-short-leaf-20261004'
$reportPath=Join-Path $work 'report.json'
Need (Get-FileHash -LiteralPath $reportPath).Hash '4124800010B921906E48EA1E185AE94B9BEF1974F1EE9B0DD0840FECCC1453DE' 'Report SHA'
$r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Need $r.status 'diagnostic-passed' 'Status';Need $r.compile_calls 1 'Compile';Need $r.total_native_calls 1 'Native';Need $r.source_count 15 'Sources';Need @($r.imports).Count 14 'Edges';Need $r.source_bytes 104117 'Source bytes'
$runner=Join-Path $PSScriptRoot 'run-native.ps1'
Need (Get-FileHash -LiteralPath $runner).Hash 'C733E7AAC8E85BCC59532AC4EDA814A4B7490C6713E117939C27020AE0A87738' 'Runner SHA'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors);Need $errors.Count 0 'Runner AST'
foreach($name in @('Near','Validate-Screen','Validate-Paid')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Validator definition'
 . ([scriptblock]::Create($defs[0].Extent.Text))
}
$pairs=0
foreach($kind in @('sources','identities')){
 $a=@($r.($kind+'_before'));$b=@($r.($kind+'_after'));Need $a.Count $b.Count 'Pair count'
 for($i=0;$i -lt $a.Count;$i++){Need (Same $a[$i] $b[$i]) $true 'Before/after';Need (Same $a[$i] (Identity $a[$i].path)) $true 'Live identity';$pairs++}
}
Need (Same $r.executable_before $r.executable_after) $true 'EXE before/after';Need (Same $r.executable_before (Identity $r.executable_before.path)) $true 'EXE live';$pairs++
Need $r.executable_before.sha256 '28D026B1751CCF5A8AFBCE079EF6178839E1C8DEB6C846E77A288BEBAABF17DE' 'EXE SHA'
Need @($r.children).Count 3 'Children';foreach($c in $r.children){Need $c.exit_code 0 'Child exit';Need $c.stderr '' 'Child stderr';Need $c.failure $null 'Child bound'}
$raw=$r.children[2].stdout|ConvertFrom-Json -Depth 64 -DateKind String;Need (Same $raw $r.screen) $true 'Native raw/screen equality'
$priorPath=Join-Path $project 'build/khc-temporal-node-information-heap-20261004/report.json'
$prior=Get-Content -Raw -LiteralPath $priorPath|ConvertFrom-Json -Depth 64 -DateKind String
$old=Get-Content -Raw -LiteralPath (Join-Path $project 'build/khc-node-history-information-20261004/report.json')|ConvertFrom-Json -Depth 64 -DateKind String
Validate-Screen $raw $old;Validate-Paid $raw $prior
Need $raw.concatenated_root_bits_directly_compared $raw.paid_DP_internal_bits 'All explicit root bits compared'
$modes=[long[]]::new(3)
foreach($t in $raw.paid_tiles){$modes[0]+=$t.selected_uniform_leaves;$modes[1]+=$t.selected_pure_leaves;$modes[2]+=$t.selected_raw_leaves}
Need $modes[0] $raw.paid_selected_uniform_leaves 'Uniform leaves';Need $modes[1] $raw.paid_selected_pure_leaves 'Pure leaves';Need $modes[2] $raw.paid_selected_raw_leaves 'Raw leaves'
$oldAccumulator=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../temporal-paid-root/tile_accumulator.rs')).Replace("`r`n","`n")
$newAccumulator=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tile_accumulator.rs')).Replace("`r`n","`n");Need $newAccumulator $oldAccumulator 'Accumulator raw unchanged'
$a=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../temporal-paid-root/packet.rs')).Replace("`r`n","`n")
$b=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'packet.rs')).Replace("`r`n","`n")
$start=$a.IndexOf('pub fn ingest');$oldIngest=$a.Substring($start,$a.IndexOf('fn row_loss')-$start)
$start=$b.IndexOf('pub fn ingest');$newIngest=$b.Substring($start,$b.IndexOf('fn row_loss')-$start);Need $newIngest $oldIngest 'Weighted ingest unchanged'
$files=@(Get-ChildItem -LiteralPath $work -Force);Need $files.Count 2 'Output count';if(@($files|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.FullName -notin @($r.executable_before.path,$reportPath)}).Count){throw 'Output shape'}
Need @(Get-Process|Where-Object Path -eq $r.executable_before.path).Count 0 'Owned EXE processes'
$disk=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';identity_pairs=$pairs;raw_native_records=1;paid_screen_bytes=$raw.paid_screen_bytes;paid_header_bytes=$raw.paid_header_bytes;DP_actual_bits_verified=$true;source_ledger_checks=2;paid_size_condition_passed=$raw.paid_size_condition_passed;additional_compile_calls=0;additional_native_calls=0;disk=$disk}|ConvertTo-Json -Depth 5
