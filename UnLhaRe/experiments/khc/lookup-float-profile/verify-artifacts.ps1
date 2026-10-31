[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$outputRoot=Join-Path $project 'build/khc-lookup-float-profile-20261004'
$reportPath=Join-Path $outputRoot 'corrected-native/report.json'
$report=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 32 -DateKind String
if($report.status -cne 'diagnostic-passed' -or $report.native.cases -ne 5){throw 'Saved native contract failed'}
$identityPairs=0
foreach($category in @('sources','identities')){
 $before=@($report.($category+'_before'));$after=@($report.($category+'_after'))
 if($before.Count -ne $after.Count){throw 'Identity pair count'}
 for($i=0;$i -lt $before.Count;$i++){
  $a=$before[$i];$b=$after[$i];$file=Get-Item -LiteralPath $a.path -Force
  if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Identity shape/link'}
  if($a.path -cne $b.path -or $a.bytes -ne $b.bytes -or $a.sha256 -cne $b.sha256 -or $a.mtime_utc -cne $b.mtime_utc -or $file.Length -ne $a.bytes -or (Get-FileHash -LiteralPath $a.path).Hash -cne $a.sha256 -or $file.LastWriteTimeUtc.ToString('o') -cne $a.mtime_utc){throw "Identity changed: $($a.path)"};$identityPairs++
 }
}
$ledger=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'source-transform.json')|ConvertFrom-Json
$transforms=@()
foreach($module in $ledger.modules){
 $expected=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $module.reference)).Replace("`r`n","`n")
 foreach($edit in $module.replacements){
  if(([regex]::Matches($expected,[regex]::Escape($edit.before))).Count -ne 1){throw 'Source transform occurrence'}
  $expected=$expected.Replace($edit.before,$edit.after)
 }
 $actual=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $module.profile)).Replace("`r`n","`n")
 if($actual.TrimEnd() -cne $expected.TrimEnd()){throw "Unlisted source edit: $($module.profile)"}
 $transforms+=@{module=$module.profile;listed_edits=$module.replacements.Count;unlisted_text_identical=$true}
}
$exe=$report.executable_before;$exeFile=Get-Item -LiteralPath $exe.path
if($exeFile.Length -ne $exe.bytes -or (Get-FileHash -LiteralPath $exe.path).Hash -cne $exe.sha256){throw 'EXE changed'}
$owned=@(Get-Process|Where-Object {$_.Path -eq $exe.path});if($owned.Count){throw 'Owned EXE still active'}
$fixed=$report.native.records[-1];$samples=0;$population=0
for($k=0;$k -lt 8;$k++){
 $en=$fixed.encode.strata[$k];$de=$fixed.decode.strata[$k]
 $expectedSamples=if($en.total -lt 128){0}else{1+[Math]::Floor(($en.total-128)/256)}
 if($en.component -ne [Math]::Floor($k/4) -or $en.prefix -ne $k%4+1 -or $en.total -ne $de.total -or $en.samples -ne $de.samples -or $en.samples -ne $expectedSamples -or $en.completed_samples -ne $en.samples -or $de.completed_samples -ne $de.samples){throw 'Strata sample count'}
 foreach($row in @($en,$de)){
  if($row.stages.Count -ne 7 -or @($row.stages|Where-Object samples -ne $row.samples).Count){throw 'Stage sample count'}
  if($row.predict_residual_sampled_ns -ne $row.stages[0].sampled_ns-$row.stages[1].sampled_ns-$row.stages[2].sampled_ns -or $row.observe_residual_sampled_ns -ne $row.stages[3].sampled_ns-$row.stages[4].sampled_ns-$row.stages[5].sampled_ns){throw 'Parent child residual'}
 }
 $samples+=$en.samples;$population+=$en.total
}
if($population -ne 3825340 -or $samples -ne 14942 -or $fixed.frame_bytes -ne 478750){throw 'Fixed totals'}
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $outputRoot -MaxRunMiB 8
[pscustomobject]@{status='verified-readonly';identity_pairs=$identityPairs;source_transform=$transforms;population_each_direction=$population;samples_each_direction=$samples;owned_exe_processes=$owned.Count;generated_files=@(Get-ChildItem -LiteralPath $outputRoot -File -Recurse|ForEach-Object{[pscustomobject]@{path=$_.FullName;bytes=$_.Length}});report_sha256=(Get-FileHash -LiteralPath $reportPath).Hash;guard_after_final_report_save=$guard}|ConvertTo-Json -Depth 6
