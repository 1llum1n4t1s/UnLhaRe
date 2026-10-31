#requires -Version 7.2
param([Parameter(Mandatory)][string]$ReportPath)
# 現在sourceのread lock証拠。過去capture/reportのhistoryを上書きしない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=Join-Path $root 'build'
$output=[IO.Path]::GetFullPath($ReportPath)
if(-not $output.StartsWith($build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)){ throw 'Fresh snapshot below build required.' }
function No-Reparse([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){ throw 'Reparse rejected.' }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
No-Reparse $output
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$rows=[Collections.Generic.List[object]]::new()
$targets=@(
    'experiments/khc/CAUSAL_BAYES_CPU_CONTRACT_20260930.md',
    'experiments/khc/CAUSAL_BAYES_FAST_BWT_CONTRACT_20260930.md',
    'experiments/khc/causal-bayes-packed/snapshot-state.ps1',
    'experiments/khc/causal-bayes-packed/sample-cpu.ps1',
    'experiments/khc/causal-bayes-packed/analyze-cpu.ps1',
    'experiments/khc/causal-bayes-packed/verify-cpu.ps1',
    'experiments/khc/causal-bayes-packed/capture-proof.ps1',
    'experiments/khc/causal-bayes-packed/inspect-code-map.ps1',
    'experiments/khc/causal-bayes-packed/codec.rs',
    'experiments/khc/causal-bayes-packed/cts_model.rs',
    'experiments/khc/causal-bayes-packed/bayes_model.rs',
    'experiments/khc/causal-bayes-fast-bwt/codec.rs',
    'experiments/khc/causal-bayes-fast-bwt/bwt.rs',
    'experiments/khc/causal-bayes-fast-bwt/audit_cli.rs',
    'experiments/khc/causal-bayes-fast-bwt/verify.ps1',
    'experiments/khc/causal-bayes-fast-bwt/verify-bwt.ps1',
    'experiments/khc/causal-bayes-fast-bwt/compare.ps1',
    'build/khc-bwt-causal-bayes-symbol-map-20260930/code-map.json',
    'build/khc-bwt-causal-bayes-symbol-map-20260930/capture/report.json',
    'build/khc-bwt-causal-bayes-symbol-map-20260930/analysis-v2/report.json',
    'build/khc-bwt-causal-bayes-symbol-map-20260930/analysis-e2e-v2/report.json',
    'build/khc-bwt-causal-bayes-symbol-map-20260930/full-e2e/report.json',
    'build/khc-bwt-causal-bayes-symbol-map-20260930/map.exe',
    'build/khc-bwt-causal-bayes-symbol-map-20260930/map.pdb',
    'build/khc-bwt-causal-bayes-fast-bwt-20260930/full-e2e/report.json',
    'build/khc-bwt-causal-bayes-fast-bwt-20260930/bwt-e2e/report.json',
    'build/khc-bwt-causal-bayes-fast-bwt-20260930/performance/report.json',
    'build/khc-bwt-causal-bayes-fast-bwt-20260930/candidate.exe',
    'build/khc-bwt-causal-bayes-fast-bwt-20260930/candidate.pdb',
    'build/khc-bwt-causal-bayes-fast-bwt-20260930/audit.exe'
)
try{
    foreach($relative in $targets){
        $path=Join-Path $root $relative; No-Reparse $path
        $item=Get-Item -LiteralPath $path; if($item -isnot [IO.FileInfo]){ throw 'File required.' }
        $locks.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        $rows.Add([pscustomobject]@{ path=$path; bytes=$item.Length; before_sha256=(Get-FileHash -LiteralPath $path).Hash; after_sha256=$null; lock='FileShare.Read' })
    }
    foreach($row in $rows){ $row.after_sha256=(Get-FileHash -LiteralPath $row.path).Hash; if($row.before_sha256 -cne $row.after_sha256){ throw 'Current state changed.' } }
    $record=[ordered]@{ status='current_state_locked'; identities=$rows.ToArray(); observed_utc=[DateTime]::UtcNow.ToString('o'); historical_capture_source_rewritten=$false; future_capture_path_executed_after_last_harness_fix=$false; meaning='Current source/read-lock identities only; no additional recording, performance run or lifetime-branch negative proof.' }
    $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
    try{ $writer.Write(($record|ConvertTo-Json -Depth 8)) }finally{ $writer.Dispose() }
}finally{ foreach($held in $locks){ $held.Dispose() } }
"Current state snapshot PASS: $($rows.Count) locked identities."
