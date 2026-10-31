#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$ProbeExecutable
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if([long]$record.max_bytes -ne 3MB -or [int]$record.max_entries -ne 64){throw 'Digit-run pilot requires the fixed 3MiB / 64-entry run reservation'}

function Plain([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    for($current=$full;$current;$current=[IO.Path]::GetDirectoryName($current)){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse point'}
    }
    return $full
}

$paths=Get-KhcStorageTaskPaths
$work=Plain $WorkDirectory
$probe=Plain $ProbeExecutable
$probeRoot=[IO.Path]::GetFullPath($paths.CargoTargetRoot)+[IO.Path]::DirectorySeparatorChar
if(-not $probe.StartsWith($probeRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Probe executable must stay inside the registered D: Cargo target'}
if(-not(Test-Path -LiteralPath $probe -PathType Leaf)){throw 'Probe executable is missing'}
if(Test-Path -LiteralPath $work){throw 'WorkDirectory must be new'}

$sourceZip='D:\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\0acc17d780a142dcafe88645a07205a5\recovery.zip'
$expectedZipSha256='27030319c3938bdec7df681d8113df43318d9a01ee40eef36e43af3e6f86e898'
$expectedSourceSha256='e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61'
$expectedSourceBytes=24603
$sourceZip=Plain $sourceZip
if(-not(Test-Path -LiteralPath $sourceZip -PathType Leaf)){throw 'Pinned recovery ZIP is missing'}
$actualZipSha=(Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash.ToLowerInvariant()
if($actualZipSha -ne $expectedZipSha256){throw 'Pinned recovery ZIP hash mismatch'}

$null=New-Item -ItemType Directory -Path $work
$inputPath=Join-Path $work 'cp.html'
$probeReportPath=Join-Path $work 'probe.json'
$resultPath=Join-Path $work 'result.json'
foreach($path in @($inputPath,$probeReportPath,$resultPath)){if(Test-Path -LiteralPath $path){throw 'Refusing to overwrite a pilot output'}}
$zip=[IO.Compression.ZipFile]::OpenRead($sourceZip)
try {
    $entry=$zip.GetEntry('pipeline-e2e/canterbury/cp.html')
    if($null -eq $entry -or $entry.Length -ne $expectedSourceBytes){throw 'Pinned Canterbury member is missing or has the wrong size'}
    $source=$entry.Open()
    $target=[IO.File]::Open($inputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$source.CopyTo($target)}finally{$target.Dispose();$source.Dispose()}
}finally{$zip.Dispose()}
$actualSourceSha=(Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
if((Get-Item -LiteralPath $inputPath).Length -ne $expectedSourceBytes -or $actualSourceSha -ne $expectedSourceSha256){throw 'Pinned Canterbury member hash mismatch'}

$sourceCode=Plain (Join-Path $PSScriptRoot '../../examples/khc_digit_run_probe.rs')
$runnerSource=Plain (Join-Path $PSScriptRoot 'digit-run-size-probe.ps1')
$runner=Plain (Join-Path $PSScriptRoot 'run-storage-experiment.ps1')
$runnerSha=(Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash.ToLowerInvariant()
$sourceCodeSha=(Get-FileHash -LiteralPath $sourceCode -Algorithm SHA256).Hash.ToLowerInvariant()
$probeSha=(Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant()

$start=[Diagnostics.ProcessStartInfo]::new($probe)
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.WorkingDirectory=$work
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
$start.Environment['TEMP']=$work
$start.Environment['TMP']=$work
$start.ArgumentList.Add($inputPath)
$start.ArgumentList.Add($probeReportPath)
$process=[Diagnostics.Process]::new()
$process.StartInfo=$start
try {
    if(-not $process.Start()){throw 'Could not start the digit-run probe'}
    $stdoutTask=$process.StandardOutput.ReadToEndAsync()
    $stderrTask=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(60000)){$process.Kill($true);if(-not $process.WaitForExit(5000)){throw 'Probe did not stop after timeout'};throw 'Digit-run probe exceeded 60 seconds'}
    $stdout=$stdoutTask.GetAwaiter().GetResult()
    $stderr=$stderrTask.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0){throw "Digit-run probe failed (exit $($process.ExitCode)): $stderr"}
}finally{$process.Dispose()}

if(-not(Test-Path -LiteralPath $probeReportPath -PathType Leaf)){throw 'Probe result file is missing'}
if((Get-Item -LiteralPath $probeReportPath).Length -gt 32768){throw 'Probe report exceeds 32 KiB'}
$probeReport=Get-Content -LiteralPath $probeReportPath -Raw | ConvertFrom-Json
if([int]$probeReport.input_bytes -ne $expectedSourceBytes -or [int]$probeReport.e2e_checks_passed -lt 20){throw 'Probe report does not satisfy the registered input/E2E contract'}
$result=[ordered]@{
    schema=1
    scope='size-first KHC block pilot; not a product archive benchmark'
    source_name='canterbury-development/cp.html'
    source_bytes=$expectedSourceBytes
    source_sha256=$actualSourceSha
    source_recovery_zip_sha256=$actualZipSha
    probe_source_sha256=$sourceCodeSha
    probe_executable_sha256=$probeSha
    runner_source_sha256=$runnerSha
    measurement='complete KHC block frame bytes only; no time, memory, or 7-Zip comparison'
    probe=$probeReport
}
$json=$result | ConvertTo-Json -Depth 8
if([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768){throw 'Result report exceeds 32 KiB'}
[IO.File]::WriteAllText($resultPath,$json,[Text.UTF8Encoding]::new($false))
Write-Output $json
