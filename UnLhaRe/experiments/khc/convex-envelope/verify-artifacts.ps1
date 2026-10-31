[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-convex-envelope-20261004'
$path=Join-Path $work 'report.json'
if((Get-FileHash -LiteralPath $path).Hash -cne 'EFD1E20A8FB50B4B6F37B03B2ADA2218E7CA6D573F30D01D863BA19843B371D9'){throw 'Report identity'}
$r=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 32 -DateKind String
if($r.status -cne 'diagnostic-passed' -or $r.compile_calls -ne 1 -or $r.native_calls -ne 1 -or $r.owned_processes -ne 0){throw 'Execution contract'}
$count=0
foreach($prefix in @('sources','identities')){
 $before=@($r.($prefix+'_before'));$after=@($r.($prefix+'_after'));if($before.Count -ne $after.Count){throw 'Pin counts'}
 foreach($id in $before){
  $saved=@($after|Where-Object path -ceq $id.path);$item=Get-Item -LiteralPath $id.path
  if($saved.Count -ne 1 -or $saved[0].sha256 -cne $id.sha256 -or $saved[0].bytes -ne $id.bytes -or $saved[0].mtime_utc -cne $id.mtime_utc -or (Get-FileHash -LiteralPath $id.path).Hash -cne $id.sha256 -or $item.Length -ne $id.bytes -or $item.LastWriteTimeUtc.Ticks -ne [datetime]::Parse($id.mtime_utc).ToUniversalTime().Ticks){throw 'Before/after/live pin'}
  $count++
 }
}
if($count -ne 33 -or @($r.imports).Count -ne 10){throw 'Closure identities'}
$e=$r.executable_before;$item=Get-Item -LiteralPath $e.path
if($e.sha256 -cne 'D20CF4CD7838D3F3D9D0C4D55DBDB19241634E42420FCC22591D21921CC8B439' -or $e.bytes -ne 235520 -or (Get-FileHash -LiteralPath $e.path).Hash -cne $e.sha256 -or $item.Length -ne $e.bytes -or $r.executable_after.sha256 -cne $e.sha256){throw 'Executable identity'}
if(@($r.children).Count -ne 3){throw 'Child count'}
foreach($c in $r.children){if($c.exit_code -ne 0 -or $c.failure -or $c.stderr){throw 'Child failure'}}
$raw=$r.children[2].stdout|ConvertFrom-Json -Depth 32 -DateKind String
if(($raw|ConvertTo-Json -Compress -Depth 32) -cne ($r.screen|ConvertTo-Json -Compress -Depth 32)){throw 'Stdout projection'}
$n=$r.screen
if($n.events -ne 1778454 -or $n.fixtures_normal -ne 5 -or $n.fixtures_rejected -ne 6 -or $n.terminal_nodes -ne 29483040 -or !$n.oracle_not_codec -or $n.extra_free_frequency_units -ne 2 -or [math]::Abs($n.baseline_Q_bits-4510058.854214707) -gt 0.000001){throw 'Oracle basis'}
if([math]::Abs(($n.optimistic_component_bits[0]+$n.optimistic_component_bits[1])-$n.optimistic_Q_bits) -gt 0.000001 -or [math]::Ceiling($n.optimistic_Q_bits/8)+3079 -ne 511576 -or $n.optimistic_screen_bytes -ne 511576 -or $n.necessary_size_condition_has_room -or [math]::Ceiling($n.ideal_best_expert_bits/8)+3079 -ne 509919){throw 'Envelope arithmetic'}
if(!$n.memory.measured -or !$n.peak_resource_gate_passed -or $n.memory.peak_working_set_bytes -gt 167772160 -or $n.memory.peak_private_commit_bytes -gt 167772160 -or $n.RAM_estimate_bytes -gt 141613654){throw 'RAM'}
if(@(Get-Process|Where-Object Path -eq $e.path).Count){throw 'Owned process remains'}
$items=@(Get-ChildItem -LiteralPath $work -Force);if($items.Count -ne 2 -or ($items|Measure-Object Length -Sum).Sum -ne 261719){throw 'Output shape/capacity'}
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='verified-readonly';pin_pairs=$count;executable_verified=$true;ideal_screen_bytes=509919;optimistic_screen_bytes=511576;size_gate_has_room=$false;guard=$guard;native_rerun=$false}|ConvertTo-Json -Depth 5
