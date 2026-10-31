#requires -Version 7.2
# 正式比較を一度だけ実行し、preflight失敗も記録する。自動再試行はしない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$taskProject=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$taskCandidate=Join-Path $taskProject 'build/khc-light-compact-codec-20261002/codec-native.exe'
$taskControl=Join-Path $taskProject 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/candidate.exe'
$taskSevenZip=Join-Path $taskProject 'build/khc-baseline-20260918/x64/7za.exe'
$taskInput=Join-Path $taskProject 'build/khc-current-source-native-solid-20260923-group/all.group'
$taskParent=Join-Path $taskProject 'build/khc-light-compact-codec-20261002'
$taskWork=Join-Path $taskParent 'performance'
$taskAttemptPath=Join-Path $taskParent 'performance-attempt.json'
$taskComparer=Join-Path $PSScriptRoot 'compare.ps1'
$taskFailure=$null
$taskBegan=[DateTime]::UtcNow.ToString('o')
if((Test-Path -LiteralPath $taskWork) -or (Test-Path -LiteralPath $taskAttemptPath)){throw 'Existing attempt; no retry or overwrite'}
$taskAncestor=$taskParent
while($taskAncestor){if((Get-Item -LiteralPath $taskAncestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse attempt parent'};$taskAncestor=[IO.Path]::GetDirectoryName($taskAncestor)}
try {
    # dot-sourceは同じ計測入口を使い、preflightの観測を失敗時にも取得するため。
    . $taskComparer -BinaryPath $taskCandidate -SevenZipPath $taskSevenZip -ControlBinary $taskControl -GroupPath $taskInput -WorkDirectory $taskWork
} catch {$taskFailure=$_.Exception.Message}
finally {
    $taskReportPath=Join-Path $taskWork 'report.json'
    $taskReportExists=Test-Path -LiteralPath $taskReportPath
    $taskAttempt=[ordered]@{
        began_utc=$taskBegan;ended_utc=[DateTime]::UtcNow.ToString('o');failure=$taskFailure
        script=$taskComparer;script_sha256=(Get-FileHash -LiteralPath $taskComparer).Hash
        runtime_path=(Get-Process -Id $PID).Path;runtime_version=$PSVersionTable.PSVersion.ToString()
        cwd=[IO.Path]::GetFullPath((Get-Location).Path);work_created=(Test-Path -LiteralPath $taskWork)
        report_exists=$taskReportExists;report_sha256=$(if($taskReportExists){(Get-FileHash -LiteralPath $taskReportPath).Hash}else{$null})
        host_observations=$report.host_load_observations
        preflight_state=$report.status
        source_guard_repairs=$(if($report.Contains('historical_budget_guard_repairs')){$report.historical_budget_guard_repairs}else{@()})
    }
    $taskJson=$taskAttempt|ConvertTo-Json -Depth 8
    $taskStream=[IO.File]::Open($taskAttemptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$taskBytes=[Text.Encoding]::UTF8.GetBytes($taskJson);$taskStream.Write($taskBytes);$taskStream.Flush($true)}finally{$taskStream.Dispose()}
    Write-Output ([pscustomobject]@{failure=$taskFailure;report=$taskReportPath;report_exists=$taskReportExists;attempt=$taskAttemptPath}|ConvertTo-Json)
}
if($taskFailure){Write-Error $taskFailure -ErrorAction Continue;exit 1}
