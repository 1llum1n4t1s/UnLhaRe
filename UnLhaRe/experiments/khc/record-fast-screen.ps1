#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string[]]$InputFiles,
    [ValidateRange(3,100)][int]$Rounds=3,
    [switch]$IncludeBuiltinSynthetic
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop
$work=Assert-KhcStorageTaskWorkDirectory $WorkDirectory
Assert-KhcStorageContext -WorkDirectory $work
$taskPaths=Get-KhcStorageTaskPaths
$benchmark=Join-Path $taskPaths.CargoTargetRoot 'debug/examples/khc_record_fast_bench.exe'
if(-not (Test-Path -LiteralPath $benchmark -PathType Leaf)){throw 'Build khc_record_fast_bench with run-serial-cargo.ps1 first.'}
if($InputFiles.Count -lt 1 -or $InputFiles.Count -gt 16){throw 'InputFiles must contain 1..16 files.'}
$inputDirectory=Join-Path $work 'inputs'
[IO.Directory]::CreateDirectory($inputDirectory) | Out-Null
$cases=[Collections.Generic.List[object]]::new()
$leafNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($path in $InputFiles){
    $source=Get-Item -LiteralPath $path -ErrorAction Stop
    if($source.PSIsContainer -or $source.Length -gt 1MB){throw "Input must be a file no larger than 1 MiB: $path"}
    $leaf=[IO.Path]::GetFileName($source.FullName)
    if(-not $leafNames.Add($leaf)){throw "Duplicate input filename: $leaf"}
    $sourceHash=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $copyPath=Join-Path $inputDirectory $leaf
    [IO.File]::Copy($source.FullName,$copyPath,$false)
    $copyHash=(Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($sourceHash -ne $copyHash){throw "Input copy SHA-256 mismatch: $leaf"}
    $cases.Add([pscustomobject]@{
        name=$leaf;input_path=$copyPath;input_source='verified-copy';input_bytes=$source.Length;input_sha256=$sourceHash
    })
}
if($IncludeBuiltinSynthetic){
    $cases.Add([pscustomobject]@{
        name='synthetic-switching-pair-v1';input_path='--synthetic-switching-pair-v1';input_source='built-in-deterministic';input_bytes=1048576;input_sha256=$null
    })
}

function Invoke-Benchmark([string]$Strategy,[string]$InputPath){
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$benchmark
    $info.WorkingDirectory=$repoRoot
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $info.ArgumentList.Add($Strategy)
    $info.ArgumentList.Add($InputPath)
    $info.ArgumentList.Add($Rounds.ToString([Globalization.CultureInfo]::InvariantCulture))
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$info
    if(-not $process.Start()){throw "Could not start benchmark strategy $Strategy."}
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(600000)){
        try{$process.Kill($true)}catch{}
        $process.WaitForExit()
        throw "Benchmark timeout: $Strategy / $InputPath"
    }
    $process.WaitForExit()
    $outText=$stdout.GetAwaiter().GetResult()
    $errText=$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0){throw "Benchmark failed ($Strategy): $($errText.Trim())"}
    $report=$outText | ConvertFrom-Json -ErrorAction Stop
    if($report.strategy -ne $Strategy -or $report.rounds -ne $Rounds){throw 'Benchmark report identity mismatch.'}
    return $report
}

$results=[Collections.Generic.List[object]]::new()
foreach($case in $cases){
    $baseline=Invoke-Benchmark 'binary-adaptive' $case.input_path
    $candidate=Invoke-Benchmark 'record-fast-trial' $case.input_path
    if($baseline.input_bytes -ne $case.input_bytes -or $candidate.input_bytes -ne $case.input_bytes -or
       $baseline.input_crc32 -ne $candidate.input_crc32){throw "Input identity mismatch in benchmark reports: $($case.name)"}
    $selected=$candidate.frame_format -eq 'KRS2' -and $candidate.coded_method -eq 1 -and $candidate.schedule_bytes -gt 0
    if($selected){
        if($candidate.frame_bytes -ge $baseline.frame_bytes){throw "KRS2 selection is not strictly smaller than BinaryAdaptive: $($case.name)"}
    }elseif($candidate.frame_format -ne 'KHC1' -or $candidate.frame_bytes -ne $baseline.frame_bytes -or $candidate.frame_crc32 -ne $baseline.frame_crc32){
        throw "RecordFast fallback differs from BinaryAdaptive: $($case.name)"
    }
    $results.Add([pscustomobject]@{
        input=$case
        baseline=$baseline
        candidate=$candidate
        krs2_selected=$selected
        size_delta_bytes=($candidate.frame_bytes-$baseline.frame_bytes)
    })
}
$selectedCount=@($results | Where-Object krs2_selected).Count
$report=[ordered]@{
    schema=1
    status='complete'
    benchmark='khc_record_fast_bench'
    comparison='record-fast-trial vs binary-adaptive'
    rounds=$Rounds
    krs2_selected_count=$selectedCount
    input_count=$results.Count
    results=@($results)
}
$json=ConvertTo-Json -InputObject $report -Depth 12
$reportPath=Join-Path $work 'record-fast-screen.json'
[IO.File]::WriteAllText($reportPath,$json,[Text.UTF8Encoding]::new($false))
Write-Output $json
