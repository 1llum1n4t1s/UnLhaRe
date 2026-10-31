param(
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$ReferenceLabPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [ValidateSet('nearest','priced-tie','bt4','bt5','hybrid')][string]$CandidateMatches = 'bt4',
    [ValidateSet('nearest','priced-tie','bt4','bt5','hybrid')][string]$ReferenceMatches = 'priced-tie',
    [ValidateSet(1,2,4,8,16)][int]$CandidateWidth = 4,
    [ValidateSet(1,2,4,8,16)][int]$ReferenceWidth = 4,
    [ValidateSet(64,128,256,512,1024,2048,4096,8192)][int]$CandidateBlock = 512,
    [ValidateSet(64,128,256,512,1024,2048,4096,8192)][int]$ReferenceBlock = 512,
    [switch]$RequireIdenticalFrames,
    [ValidateRange(1,100)][int]$Repeats = 5
)
# 出力変更を許すmatcher実験。旧frameとの同値ではなく、各benchの復元・決定性を検査する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$executables = @{
    candidate = (Resolve-Path -LiteralPath $LabPath).Path
    reference = (Resolve-Path -LiteralPath $ReferenceLabPath).Path
}
$hashes = @{}
foreach ($side in 'candidate','reference') { $hashes[$side] = (Get-FileHash -LiteralPath $executables[$side]).Hash }
$work = [IO.Path]::GetFullPath($WorkDirectory)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $work.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below build.' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
$manifestPath = Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json'
$manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
$scriptHash = (Get-FileHash -LiteralPath $PSCommandPath).Hash
$manifest = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json | Where-Object name -eq 'canterbury-development').files)
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'build/khc-corpus/canterbury-development') -File | Sort-Object Name)
if ($files.Count -ne 11 -or $manifest.Count -ne 11) { throw 'Expected fixed development corpus.' }
$pairs = @()
$frameChecks = @()
function Get-FrameHash([string]$Executable, [string]$InputPath, [string]$Policy, [int]$Width, [int]$Block) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($arg in @('encode', $InputPath, '--algorithm', 'beam', '--beam-model', 'blended', '--beam-matches', $Policy, '--beam-width', [string]$Width, '--beam-block', [string]$Block, '--dictionary-mib', '64')) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $memory = [IO.MemoryStream]::new()
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Cannot start frame check.' }
        $copy = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { throw 'Frame check exceeded 120 seconds.' }
        $null = $copy.GetAwaiter().GetResult()
        $stderr = $errors.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Frame check exit $($process.ExitCode): $stderr" }
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$memory.ToArray()))
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $memory.Dispose()
        $process.Dispose()
    }
}
$pairIndex = 0
foreach ($file in $files) {
    $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
    $entry = @($manifest | Where-Object name -eq $file.Name)
    if ($entry.Count -ne 1 -or $entry[0].sha256 -ne $hash -or $entry[0].bytes -ne $file.Length) { throw 'Corpus mismatch.' }
    for ($repeat = 0; $repeat -lt $Repeats; $repeat++) {
        $order = if ($pairIndex % 2) { @('candidate','reference') } else { @('reference','candidate') }
        $pair = [ordered]@{input = $file.Name; sha256 = $hash; repeat = $repeat; order = $order}
        foreach ($side in $order) {
            $policy = if ($side -eq 'candidate') { $CandidateMatches } else { $ReferenceMatches }
            $width = if ($side -eq 'candidate') { $CandidateWidth } else { $ReferenceWidth }
            $block = if ($side -eq 'candidate') { $CandidateBlock } else { $ReferenceBlock }
            $info = [Diagnostics.ProcessStartInfo]::new($executables[$side])
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($arg in @('bench', $file.FullName, '--algorithm', 'beam', '--beam-model', 'blended', '--beam-matches', $policy, '--beam-width', [string]$width, '--beam-block', [string]$block, '--dictionary-mib', '64', '--repeats', '1')) { $info.ArgumentList.Add($arg) }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $info
            $started = $false
            $startedUtc = [DateTime]::UtcNow.ToString('o')
            $wall = [Diagnostics.Stopwatch]::new()
            try {
                $wall.Start()
                $started = $process.Start()
                if (-not $started) { throw 'Cannot start bench.' }
                $output = $process.StandardOutput.ReadToEndAsync()
                $errors = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(120000)) { throw 'Bench exceeded 120 seconds.' }
                $json = $output.GetAwaiter().GetResult()
                $stderr = $errors.GetAwaiter().GetResult()
                $wall.Stop()
                if ($process.ExitCode -ne 0) { throw "Bench exit $($process.ExitCode): $stderr" }
                $cpuMs = $null
                $cpuStatus = 'available'
                try { $cpuMs = $process.TotalProcessorTime.TotalMilliseconds }
                catch { $cpuStatus = 'unavailable' }
                $result = $json | ConvertFrom-Json
                $expectedPolicy = switch ($policy) { 'bt4' { 'Bt4' }; 'bt5' { 'Bt5' }; 'hybrid' { 'Hybrid' }; 'priced-tie' { 'PricedTie' }; 'nearest' { 'Nearest' } }
                if ($result.algorithm -ne 'Beam' -or $result.beam_model -ne 'Blended' -or $result.beam_matches -ne $expectedPolicy -or $result.beam_width -ne $width -or $result.beam_block -ne $block -or $result.dictionary -ne 67108864 -or $result.input_bytes -ne $file.Length -or $result.samples.Count -ne 1) { throw 'Unexpected bench settings.' }
                $result | Add-Member -NotePropertyName process_observation -NotePropertyValue ([pscustomobject]@{
                    started_utc = $startedUtc
                    wall_ms = $wall.Elapsed.TotalMilliseconds
                    cpu_ms = $cpuMs
                    cpu_status = $cpuStatus
                })
                $pair[$side] = $result
            } finally {
                if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                $process.Dispose()
            }
        }
        $pairs += [pscustomobject]$pair
        $pairIndex++
    }
    if ($RequireIdenticalFrames) {
        $candidateHash = Get-FrameHash $executables.candidate $file.FullName $CandidateMatches $CandidateWidth $CandidateBlock
        $referenceHash = Get-FrameHash $executables.reference $file.FullName $ReferenceMatches $ReferenceWidth $ReferenceBlock
        if ($candidateHash -ne $referenceHash) { throw "Frame changed: $($file.Name)" }
        $frameChecks += [pscustomobject]@{input = $file.Name; candidate_sha256 = $candidateHash; reference_sha256 = $referenceHash}
    }
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne $hash) { throw 'Input changed.' }
    Write-Host "$($file.Name): $Repeats paired sample(s), warm-up/round-trip/determinism passed"
}
foreach ($side in 'candidate','reference') { if ((Get-FileHash -LiteralPath $executables[$side]).Hash -ne $hashes[$side]) { throw 'Executable changed.' } }
if ((Get-FileHash -LiteralPath $manifestPath).Hash -ne $manifestHash -or (Get-FileHash -LiteralPath $PSCommandPath).Hash -ne $scriptHash) { throw 'Manifest or script changed.' }
$report = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o'); executables = $executables; binary_sha256 = $hashes
    manifest_sha256 = $manifestHash; script_sha256 = $scriptHash
    cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    os = [Environment]::OSVersion.VersionString; power_scheme = @(powercfg /getactivescheme)
    note = 'Alternating fixed binaries; each sample has its own warm-up. samples contain internal codec wall times. process_observation includes startup, warm-up, measured encode/decode and output draining; CPU time covers the child process only and is null when unavailable. It is not encode-only CPU time, and wall-minus-CPU does not isolate scheduler delay. No 7zip/CLI/holdout claim; binary provenance checked separately.'
    require_identical_frames = $RequireIdenticalFrames.IsPresent
    beam_widths = @{ candidate = $CandidateWidth; reference = $ReferenceWidth }
    beam_blocks = @{ candidate = $CandidateBlock; reference = $ReferenceBlock }
    frame_checks = $frameChecks
    pairs = $pairs
}
$null = New-Item -ItemType Directory -Path $work
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8
Write-Host "Saved $work/report.json"
