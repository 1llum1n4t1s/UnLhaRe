[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 64) -ceq ($b|ConvertTo-Json -Compress -Depth 64)}
function Hash-Text([string]$s){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($s)))}
function Replace-One([string]$s,[string]$a,[string]$b){Need ([regex]::Matches($s,[regex]::Escape($a))).Count 1 'Restoration count';$s.Replace($a,$b)}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-temporal-node-information-heap-20261004'
$rp=Join-Path $work 'report.json'
Need (Get-FileHash -LiteralPath $rp).Hash 'E8A89FEE46CC6BB39697C416FD8150CB83B2406D9297A1C4397E6D9956C052A8' 'Report SHA'
$r=Get-Content -LiteralPath $rp -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Need $r.status 'diagnostic-passed' 'Status';Need $r.compile_calls 1 'Compile';Need $r.total_native_calls 1 'Native';Need $r.source_count 12 'Sources';Need @($r.imports).Count 11 'Edges';Need $r.source_bytes 64920 'Bytes'
$pairs=0
foreach($kind in @('sources','identities')){
 $a=@($r.($kind+'_before'));$b=@($r.($kind+'_after'));Need $a.Count $b.Count 'Pairs'
 for($i=0;$i -lt $a.Count;$i++){
  if(!(Same $a[$i] $b[$i])){throw 'Before/after'};$f=Get-Item -LiteralPath $a[$i].path -Force
  if($f.PSIsContainer -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Regular file'}
  Need $f.Length $a[$i].bytes 'Bytes';Need (Get-FileHash -LiteralPath $f.FullName).Hash $a[$i].sha256 'SHA';Need $f.LastWriteTimeUtc.Ticks ([DateTimeOffset]::Parse($a[$i].mtime_utc).UtcTicks) 'mtime';$pairs++
 }
}
Need @($r.identities_before).Count 43 'Pins'
$exe=$r.executable_before;if(!(Same $exe $r.executable_after)){throw 'EXE before/after'}
Need (Get-FileHash -LiteralPath $exe.path).Hash '91B8502A408C4F02F6439E27516DD41B1539658079C1DDA040D3E4CD57E0D3C8' 'EXE SHA';Need (Get-Item -LiteralPath $exe.path).Length 270848 'EXE bytes';$pairs++
Need @($r.children).Count 3 'Children';foreach($c in $r.children){Need $c.exit_code 0 'Exit';Need $c.stderr '' 'stderr';if($c.failure){throw 'Child failure'}}
$native=$r.children[-1];Need $native.file $exe.path 'Native EXE';Need $native.arguments[0] 'screen' 'Native operation'
$raw=$native.stdout|ConvertFrom-Json -Depth 64 -DateKind String;if(!(Same $raw $r.screen)){throw 'Whole raw record projection'}
$runner=Join-Path $PSScriptRoot 'run-native.ps1';Need (Get-FileHash -LiteralPath $runner).Hash '767EBF40B6C4FE1B6165237497518028166C92E2E68B7D9E5727E27ABBDB01C8' 'Runner SHA'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
# 検証関数だけを抽出し実行。runner entrypoint/compile/nativeは実行しない。
foreach($name in @('Near','Validate-Screen')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Validator definition';. ([scriptblock]::Create($defs[0].Extent.Text))
}
$old=Get-Content -LiteralPath (Join-Path $project 'build/khc-node-history-information-20261004/report.json') -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Validate-Screen $raw $old
$tiles=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tiles.rs'))
$tiles=Replace-One $tiles 'pub tiles: Vec<Summary>' 'pub tiles: [Summary; TILES]'
$from="        let mut tiles=Vec::new();`n        tiles.try_reserve_exact(TILES).map_err(|_|`"tile summary allocation`")?;`n        tiles.resize_with(TILES,Summary::default);`n        Ok(Self { dense: counts::Dense::new()?, tiles,"
$tiles=Replace-One $tiles $from '        Ok(Self { dense: counts::Dense::new()?, tiles: [Summary::default(); TILES],'
$tiles=Replace-One $tiles "`n            + self.tiles.capacity()*std::mem::size_of::<Summary>()" ''
Need (Hash-Text $tiles) 'EA4692623D74DC23A0ECBFF8FD77228418AE1685EB9F36B003F575100A15D72F' 'Heap fix tiles original restoration'
$probe=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'probe.rs'))
$from="    let bounded_summary_bytes=a.capacity_bytes()-dense_bytes;`n    if a.tiles.len()!=tiles::TILES || a.tiles.capacity()!=tiles::TILES{return Err(`"fixed tile summary capacity`".into());}`n    let tile_summaries=std::mem::take(&mut a.tiles); let whole=a.whole; let coded=a.coded; let implicit=a.implicit;"
$probe=Replace-One $probe $from '    let tile_summaries=a.tiles; let whole=a.whole; let coded=a.coded; let implicit=a.implicit;'
$probe=Replace-One $probe '        bounded_summary_bytes);' '        std::mem::size_of::<tiles::Accumulator>()-std::mem::size_of::<counts::Dense>());'
Need (Hash-Text $probe) '71FE4052BEA2CA9C8B2819CD60B73A7EDFDDDCD836CBCD3ADAC701ADCB84E2CC' 'Heap fix probe original restoration'
$failed=Get-Content -LiteralPath $r.previous_terminal_failure.report.path -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Need $failed.status 'failed' 'Old failure status';Need $failed.compile_calls 1 'Old compile';Need $failed.total_native_calls 1 'Old native';Need $failed.children[-1].exit_code -1073741571 'Old stack overflow'
Need @(Get-Process|Where-Object Path -eq $exe.path).Count 0 'Owned process'
$files=@(Get-ChildItem -LiteralPath $work -Force);Need $files.Count 2 'Output count';if(@($files|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe.path,$rp) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
$disk=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';identity_pairs=$pairs;raw_native_records=1;heap_fix_restored_sites=5;optimistic_Q_screen_bytes=$raw.optimistic_Q_screen_bytes;additional_compile_calls=0;additional_native_calls=0;disk=$disk}|ConvertTo-Json -Depth 5
