#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$InputRecoveryZip,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$InputRecoveryZipSha256,
    [ValidateRange(3,3)][int]$Rounds=3
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop

$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$work=Assert-KhcStorageTaskWorkDirectory $WorkDirectory
Assert-KhcStorageContext -WorkDirectory $work

function Assert-PlainPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    for($part=$full;$part;$part=[IO.Path]::GetDirectoryName($part)){
        if((Test-Path -LiteralPath $part) -and
            (((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
            throw "Reparse point is not permitted: $part"
        }
    }
    return $full
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Write-Report([object]$Value) {
    $path=Join-Path $work 'record-adaptive-screen.json'
    $json=ConvertTo-Json -InputObject $Value -Depth 16
    # CPUゲートの不合格記録はinput/frames作成前に書くため、先に作業rootを確保する。
    [IO.Directory]::CreateDirectory((Assert-PlainPath $work)) | Out-Null
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    Write-Output $json
}
function Get-Median([long[]]$Values) {
    if($Values.Length -ne 9){throw 'Expected exactly nine paired samples per strategy.'}
    $sorted=[long[]]$Values.Clone()
    [Array]::Sort($sorted)
    return $sorted[4]
}

# Guard again inside the registered child; the parent must also take this sample before run registration.
$cpu=[Collections.Generic.List[double]]::new()
$cpuCapture=Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5
foreach($sample in $cpuCapture.CounterSamples){$cpu.Add([math]::Round($sample.CookedValue,1))}
if($cpu.Count -ne 5){throw 'CPU quiet-gate sample count mismatch.'}
if(@($cpu | Where-Object {$_ -gt 15}).Count -ne 0){
    Write-Report ([ordered]@{
        schema=1;status='skipped-cpu-gate';timestamp_local=(Get-Date).ToString('o')
        cpu_threshold_percent=15;cpu_samples_percent=@($cpu);measurements_started=$false
    })
    return
}

$zipPath=Assert-PlainPath $InputRecoveryZip
if(-not (Test-Path -LiteralPath $zipPath -PathType Leaf)){throw 'Pinned development recovery ZIP is missing.'}
$zipHash=Get-Sha256 $zipPath
if($zipHash -ne $InputRecoveryZipSha256.ToLowerInvariant() -or
   $zipHash -ne '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'){
    throw 'Pinned development recovery ZIP SHA-256 mismatch.'
}

$inputDirectory=Join-Path $work 'input'
$frameDirectory=Join-Path $work 'frames'
foreach($directory in @($inputDirectory,$frameDirectory)){
    if(Test-Path -LiteralPath $directory){throw "Output directory already exists: $directory"}
    [IO.Directory]::CreateDirectory((Assert-PlainPath $directory)) | Out-Null
}
$inputPath=Join-Path $inputDirectory 'ptt5'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
try{
    $entry=$archive.GetEntry('input/ptt5')
    if($null -eq $entry -or $entry.Length -ne 513216){throw 'Pinned ptt5 member name/length mismatch.'}
    $source=$entry.Open()
    $destination=[IO.File]::Open($inputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $digest=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try{
        $buffer=[byte[]]::new(65536)
        while(($read=$source.Read($buffer,0,$buffer.Length)) -gt 0){
            $destination.Write($buffer,0,$read)
            $digest.AppendData($buffer,0,$read)
        }
        $destination.Flush($true)
        $inputHash=[Convert]::ToHexString($digest.GetHashAndReset()).ToLowerInvariant()
    } finally { $digest.Dispose(); $destination.Dispose(); $source.Dispose() }
} finally { $archive.Dispose() }
if($inputHash -ne '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650' -or
   (Get-Sha256 $inputPath) -ne $inputHash){throw 'Pinned ptt5 byte identity mismatch.'}

$taskPaths=Get-KhcStorageTaskPaths
$benchmark=Assert-PlainPath (Join-Path $taskPaths.CargoTargetRoot 'release/examples/khc_record_fast_bench.exe')
if(-not (Test-Path -LiteralPath $benchmark -PathType Leaf)){throw 'Build the Release khc_record_fast_bench example through run-serial-cargo.ps1 first.'}
$benchmarkHash=Get-Sha256 $benchmark
if($benchmarkHash -ne 'abcf5cbd839f059a8f633634eb1bc2c0cc49fdef2bd6b3f39e5168a6be019bbb'){
    throw 'Pinned Release khc_record_fast_bench SHA-256 mismatch.'
}
$batchReports=@{ 'record-fast-trial'=[Collections.Generic.List[object]]::new(); 'record-adaptive-trial'=[Collections.Generic.List[object]]::new() }
function Invoke-Benchmark([string]$Strategy,[int]$Batch) {
    $framePath=Join-Path $frameDirectory (('{0}-{1}.frame' -f $Strategy,$Batch))
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$benchmark
    $info.WorkingDirectory=$repoRoot
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    foreach($argument in @($Strategy,$inputPath,$Rounds.ToString([Globalization.CultureInfo]::InvariantCulture),$framePath)){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$info
    if(-not $process.Start()){throw "Could not start $Strategy batch $Batch."}
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(120000)){
        try{$process.Kill($true)}catch{}
        $process.WaitForExit()
        throw "Benchmark process timed out: $Strategy batch $Batch."
    }
    $process.WaitForExit()
    $process.Refresh()
    $peakWorkingSet=[long]$process.PeakWorkingSet64
    $outText=$stdout.GetAwaiter().GetResult()
    $errText=$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0){throw "Benchmark failed ($Strategy): $($errText.Trim())"}
    if($outText.Length -gt 64KB -or $errText.Length -gt 64KB){throw 'Benchmark output exceeded 64 KiB.'}
    $report=$outText | ConvertFrom-Json -ErrorAction Stop
    if($report.strategy -ne $Strategy -or $report.rounds -ne $Rounds -or
       $report.input_bytes -ne 513216 -or $report.input_source -ne 'file'){
        throw "Benchmark report identity mismatch: $Strategy batch $Batch."
    }
    if(-not (Test-Path -LiteralPath $framePath -PathType Leaf)){throw "Benchmark frame output missing: $Strategy batch $Batch."}
    $frameInfo=Get-Item -LiteralPath $framePath
    $frameHash=Get-Sha256 $framePath
    if($frameInfo.Length -ne $report.frame_bytes){throw "Benchmark frame length mismatch: $Strategy batch $Batch."}
    Assert-KhcStorageContext -WorkDirectory $work
    return [pscustomobject]@{
        batch=$Batch;strategy=$Strategy;frame_format=[string]$report.frame_format
        input_crc32=[long]$report.input_crc32
        frame_bytes=[long]$report.frame_bytes;frame_crc32=[long]$report.frame_crc32
        frame_sha256=$frameHash;median_encode_ns=[long]$report.median_encode_ns
        median_decode_ns=[long]$report.median_decode_ns
        encode_samples_ns=@($report.encode_samples_ns | ForEach-Object {[long]$_})
        decode_samples_ns=@($report.decode_samples_ns | ForEach-Object {[long]$_})
        peak_working_set_bytes=$peakWorkingSet
    }
}

for($batch=0;$batch -lt 3;$batch++){
    $ordered=if($batch % 2 -eq 0){@('record-fast-trial','record-adaptive-trial')}else{@('record-adaptive-trial','record-fast-trial')}
    foreach($strategy in $ordered){$batchReports[$strategy].Add((Invoke-Benchmark $strategy $batch))}
}

function Summarize-Strategy([string]$Strategy) {
    $runs=@($batchReports[$Strategy])
    $formats=@($runs | ForEach-Object {$_.frame_format} | Select-Object -Unique)
    $inputCrcs=@($runs | ForEach-Object {$_.input_crc32} | Select-Object -Unique)
    $lengths=@($runs | ForEach-Object {$_.frame_bytes} | Select-Object -Unique)
    $crcs=@($runs | ForEach-Object {$_.frame_crc32} | Select-Object -Unique)
    $hashes=@($runs | ForEach-Object {$_.frame_sha256} | Select-Object -Unique)
    if($runs.Count -ne 3 -or $formats.Count -ne 1 -or $inputCrcs.Count -ne 1 -or $lengths.Count -ne 1 -or $crcs.Count -ne 1 -or $hashes.Count -ne 1){
        throw "Cross-process output is not deterministic: $Strategy."
    }
    $encode=@($runs | ForEach-Object {$_.encode_samples_ns})
    $decode=@($runs | ForEach-Object {$_.decode_samples_ns})
    if($encode.Count -ne 9 -or $decode.Count -ne 9){throw "Sample count mismatch: $Strategy."}
    return [pscustomobject]@{
        strategy=$Strategy;input_crc32=$inputCrcs[0];frame_format=$formats[0];frame_bytes=$lengths[0]
        frame_crc32=$crcs[0];frame_sha256=$hashes[0]
        median_encode_ns=(Get-Median ([long[]]$encode));median_decode_ns=(Get-Median ([long[]]$decode))
        encode_samples_ns=$encode;decode_samples_ns=$decode
        peak_working_set_bytes=[long](($runs | Measure-Object peak_working_set_bytes -Maximum).Maximum)
        batches=$runs
    }
}
$baseline=Summarize-Strategy 'record-fast-trial'
$candidate=Summarize-Strategy 'record-adaptive-trial'
if($baseline.input_crc32 -ne $candidate.input_crc32){throw 'Baseline/candidate input CRC-32 mismatch.'}
if($baseline.frame_format -ne 'KRS2' -or $baseline.frame_bytes -ne 46202 -or $baseline.frame_crc32 -ne 2710226762){
    throw 'KRS2 fixed ptt5 development baseline changed.'
}
$memoryPass=$candidate.peak_working_set_bytes -le 64MB
$sizePass=$candidate.frame_format -eq 'KRS3' -and $candidate.frame_bytes -lt 42127
$candidateStatus=if($candidate.frame_format -ne 'KRS3'){'fallback-no-go'}elseif(-not $memoryPass){'memory-no-go'}elseif(-not $sizePass){'block-size-no-go'}else{'block-gate-passed-archive-trial-required'}
Write-Report ([ordered]@{
    schema=1;status='complete';screen='KRS3 development block-only ptt5';
    input=[ordered]@{recovery_zip=$zipPath;recovery_zip_sha256=$zipHash;member='input/ptt5';bytes=513216;sha256=$inputHash}
    cpu_threshold_percent=15;cpu_samples_percent=@($cpu);rounds_per_batch=$Rounds;batch_count=3
    execution_order=@('record-fast-trial','record-adaptive-trial','record-adaptive-trial','record-fast-trial','record-fast-trial','record-adaptive-trial')
    benchmark=$benchmark;benchmark_sha256=$benchmarkHash;baseline=$baseline;candidate=$candidate
    thresholds=[ordered]@{baseline_frame_bytes=46202;baseline_frame_crc32=2710226762;projected_archive_outer_overhead_bytes=72;candidate_frame_bytes_strictly_below=42127;process_peak_working_set_bytes_at_most=67108864}
    candidate_status=$candidateStatus;promotion_gate_passed=($memoryPass -and $sizePass)
    note='Block-only development screen; not a complete KHC archive, not holdout, not a 7-Zip result.'
})
