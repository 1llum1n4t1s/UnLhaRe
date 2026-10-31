[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-causal-direct-mix-20261004'
$path=Join-Path $work 'report.json'
function Identity([string]$Path){$resolved=[IO.Path]::GetFullPath($Path);$ancestor=$resolved;while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse path'}};$ancestor=[IO.Path]::GetDirectoryName($ancestor)};$item=Get-Item -LiteralPath $resolved -Force;if($item.PSIsContainer){throw 'Expected file'};[pscustomobject]@{path=$resolved;sha256=(Get-FileHash -LiteralPath $resolved).Hash;bytes=$item.Length;mtime_utc=$item.LastWriteTimeUtc.ToString('o')}}
function Same($A,$B){foreach($field in @('path','sha256','bytes','mtime_utc')){if($A.$field -cne $B.$field){return $false}};return $true}
if((Identity $path).sha256 -cne '193939C7A911AA00F309AC79DA371E386FF5BF16623A530179B00676C5CAFB95'){throw 'Failure report SHA'}
$report=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json -Depth 32 -DateKind String
if($report.status -cne 'failed' -or $report.compile_calls -ne 1 -or $report.native_calls -ne 0 -or $report.error -notmatch 'unexpected closing delimiter' -or $report.source_count -ne 8 -or $report.source_bytes -ne 43498 -or $report.frozen_static_source_checks -ne 19 -or $report.frozen_feature_source_checks -ne 7 -or $report.mix_phase_worst_bytes -ne 67108864){throw 'Failure scope'}
$pairs=0
foreach($set in @(@($report.sources_before,$report.sources_after),@($report.identities_before,$report.identities_after))){$before=@($set[0]);$after=@($set[1]);if($before.Count -ne $after.Count){throw 'Pin extent'};foreach($entry in $before){$matching=@($after|Where-Object path -ceq $entry.path);if($matching.Count -ne 1 -or !(Same $entry $matching[0]) -or !(Same $entry (Identity $entry.path))){throw "Pin/live mismatch: $($entry.path)"};$pairs++}}
if($report.children.Count -ne 2 -or $report.children[0].exit_code -ne 0 -or $report.children[1].exit_code -ne 1 -or $report.children[1].elapsed_ms -gt 60000){throw 'Failed compile child scope'}
foreach($child in $report.children){if([Text.Encoding]::UTF8.GetByteCount($child.stdout) -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($child.stderr) -gt 16384){throw 'Stream bound'}}
$files=@(Get-ChildItem -LiteralPath $work -Force);if($files.Count -ne 1 -or $files[0].FullName -cne $path -or $files[0].Length -gt 262144){throw 'Failure output shape/bound'}
$exe=Join-Path $work 'causal-direct-mix-o3-thin.exe';if(Test-Path -LiteralPath $exe){throw 'Unexpected EXE'}
$processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($processes){throw 'Owned process remains'}
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='failed-evidence-readonly-verified';before_after_live_pin_pairs=$pairs;compile_calls=1;native_calls=0;source_count=8;source_bytes=43498;EXE_created=$false;E2E_executed=$false;loss_measured=$false;output=Identity $path;owned_exe_processes=$processes;final_guard_after_report_save=$guard}|ConvertTo-Json -Depth 8
