param(
    [Parameter(Mandatory)][string]$BaselineReportPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)

# 成功済みサイズscreenの入力とbinaryだけを使い、CLI end-to-end圧縮時間を順序反転で比較する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'build'))
$buildPrefix = $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$baselinePath = [IO.Path]::GetFullPath($BaselineReportPath)
$expectedBaselineHash = 'C713283A071BEFED0AD7371A55EC81DC31B55286A0243CB53445E1BF92CE6CFD'

function Assert-BelowBuild([string]$Path, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be strictly below UnLhaRe/build: $full"
    }
    $full
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not allowed in this path: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -ceq $current) { break }
        $current = $parent
    }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-FileSnapshot([object]$Snapshot) {
    foreach ($path in @([string]$Snapshot.source_path, [string]$Snapshot.snapshot_path)) {
        $full = Assert-BelowBuild $path 'Corpus source or snapshot'
        Assert-NoReparse $full
        $item = Get-Item -LiteralPath $full -Force
        if ($item -isnot [IO.FileInfo] -or
            $item.Length -ne [long]$Snapshot.bytes -or
            (Get-Sha256 $full) -cne [string]$Snapshot.sha256) {
            throw "Corpus source or snapshot drifted: $($Snapshot.name)"
        }
    }
}

function Assert-RecordedOutput([object]$Run, [long]$ExpectedBytes, [string]$ExpectedSha256) {
    if (-not (Test-Path -LiteralPath $Run.output_path -PathType Leaf)) {
        throw "Measured output is missing: $($Run.output_path)"
    }
    $actualBytes = (Get-Item -LiteralPath $Run.output_path -Force).Length
    $actualSha256 = Get-Sha256 ([string]$Run.output_path)
    if ($actualBytes -ne $ExpectedBytes -or $actualSha256 -cne $ExpectedSha256) {
        throw "Measured output changed from the successful size screen: $($Run.label)"
    }
    $Run.output_bytes = $actualBytes
    $Run.output_sha256 = $actualSha256
}

function Invoke-TimedProcess(
    [string]$Program,
    [string[]]$Arguments,
    [ValidateSet('file', 'discard')][string]$OutputMode,
    [string]$OutputPath,
    [string]$WorkingDirectory,
    [string]$Label,
    [string]$ArtifactPath = ''
) {
    if ($OutputMode -ceq 'file') {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'File output requires an output path.' }
    } elseif (-not [string]::IsNullOrEmpty($OutputPath)) {
        throw 'Discard output must not specify a path.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new($Program)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $WorkingDirectory
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timer = [Diagnostics.Stopwatch]::new()
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    $sink = $null
    try {
        $timer.Start()
        $sink = if ($OutputMode -ceq 'file') {
            [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        } else {
            [IO.Stream]::Null
        }
        $started = $process.Start()
        if (-not $started) { throw "Failed to start: $Program" }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($sink)
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        while (-not $process.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Process deadline exceeded: $Label" }
            if ($stdoutTask.IsFaulted) { $null = $stdoutTask.GetAwaiter().GetResult() }
        }
        $null = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$Label exit $($process.ExitCode): $stderr" }
        if ($OutputMode -ceq 'file') { $sink.Flush($true) }
        $timer.Stop()
        [pscustomobject][ordered]@{
            label = $Label
            program = $Program
            arguments = [string[]]$Arguments
            exit_code = $process.ExitCode
            elapsed_ms = $timer.Elapsed.TotalMilliseconds
            output_path = $(if ($OutputMode -ceq 'file') { $OutputPath } else { $ArtifactPath })
            output_bytes = $null
            output_sha256 = $null
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        if ($null -ne $stdoutTask) {
            try { $null = $stdoutTask.GetAwaiter().GetResult() } catch { }
        }
        if ($null -ne $stderrTask) {
            try { $null = $stderrTask.GetAwaiter().GetResult() } catch { }
        }
        if ($OutputMode -ceq 'file' -and $null -ne $sink) { $sink.Dispose() }
        $process.Dispose()
    }
}

function Get-Median([double[]]$Values) {
    if ($Values.Count -eq 0) { throw 'Cannot calculate a median from no values.' }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$middle] }
    ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

Assert-NoReparse $buildRoot
$null = Assert-BelowBuild $WorkDirectory 'WorkDirectory'
$null = Assert-BelowBuild $BaselineReportPath 'BaselineReportPath'
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new; existing data will not be overwritten.' }
Assert-NoReparse $work
Assert-NoReparse $baselinePath
if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) { throw "Baseline report is missing: $baselinePath" }
if ((Get-Sha256 $baselinePath) -cne $expectedBaselineHash) { throw 'Baseline report hash does not match the verified size screen.' }

$baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
if ($baseline.status -cne 'success: size-only Canterbury development solid-order screen; not a product archive or performance claim') {
    throw 'Baseline report is not a successful size-only solid-order screen.'
}
if ($baseline.provenance.source_root -cne $sourceRoot -or $baseline.corpus.role -cne 'development') {
    throw 'Baseline report belongs to a different repository or corpus role.'
}
$baselineWork = Assert-BelowBuild ([string]$baseline.provenance.work_directory) 'Baseline work directory'
$lab = Assert-BelowBuild ([string]$baseline.provenance.lab_path) 'KHC executable'
$sevenZip = Assert-BelowBuild ([string]$baseline.provenance.seven_zip_path) '7-Zip executable'
foreach ($path in @($baselineWork, $lab, $sevenZip)) { Assert-NoReparse $path }
if (-not (Test-Path -LiteralPath $lab -PathType Leaf) -or
    (Get-Sha256 $lab) -cne [string]$baseline.provenance.lab_sha256) {
    throw 'KHC executable is missing or changed since the size screen.'
}
if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf) -or
    (Get-Sha256 $sevenZip) -cne [string]$baseline.provenance.seven_zip_sha256) {
    throw '7-Zip executable is missing or changed since the size screen.'
}

$ordinal = @($baseline.cases | Where-Object { $_.id -ceq 'ordinal-ascii-name' })
$content = @($baseline.cases | Where-Object { $_.id -ceq 'content-based' })
if ($ordinal.Count -ne 1 -or $content.Count -ne 1 -or
    $ordinal[0].opaque_group.format -cne 'KHSGRP0' -or
    $content[0].opaque_group.format -cne 'KHSGRP1') {
    throw 'Baseline must contain one KHSGRP0 ordinal and one KHSGRP1 content-based case.'
}
foreach ($case in @($ordinal[0], $content[0])) {
    $groupPath = Assert-BelowBuild ([string]$case.opaque_group.path) 'Solid-group input'
    Assert-NoReparse $groupPath
    if (-not (Test-Path -LiteralPath $groupPath -PathType Leaf) -or
        (Get-Sha256 $groupPath) -cne [string]$case.opaque_group.sha256) {
        throw "Baseline group is missing or changed: $($case.id)"
    }
}
$archiveBaselinePath = Assert-BelowBuild ([string]$ordinal[0].seven_zip.archive_path) '7-Zip baseline archive'
Assert-NoReparse $archiveBaselinePath
if (-not (Test-Path -LiteralPath $archiveBaselinePath -PathType Leaf) -or
    (Get-Sha256 $archiveBaselinePath) -cne [string]$ordinal[0].seven_zip.archive_sha256) {
    throw 'Ordinal 7-Zip archive is missing or changed since the size screen.'
}

$snapshots = @($baseline.corpus.snapshots)
if ($snapshots.Count -ne 11) { throw 'Expected the fixed 11-file Canterbury development snapshot.' }
foreach ($snapshot in $snapshots) { Assert-FileSnapshot $snapshot }
$inputDirectory = Assert-BelowBuild ([IO.Path]::GetDirectoryName([string]$snapshots[0].snapshot_path)) 'Corpus snapshot directory'
Assert-NoReparse $inputDirectory
$inputNames = [string[]]@($ordinal[0].logical_entry_order)
if ([string]::Join([char]10, $inputNames) -cne [string]::Join([char]10, [string[]]$ordinal[0].seven_zip.observed_entry_order)) {
    throw 'Ordinal KHC and 7-Zip input orders differ in the baseline.'
}

$khcTemplate = [string[]]@($baseline.settings.khc.arguments)
if ($khcTemplate.Count -lt 3 -or $khcTemplate[0] -cne 'group-encode' -or $khcTemplate[1] -cne '<group>') {
    throw 'Unexpected KHC command template in baseline report.'
}
$khcOptions = [string[]]@($khcTemplate[2..($khcTemplate.Count - 1)])
$sevenZipTemplate = [string[]]@($baseline.settings.seven_zip.arguments)
if ($sevenZipTemplate.Count -lt 4 -or
    $sevenZipTemplate[$sevenZipTemplate.Count - 2] -cne '<archive>' -or
    $sevenZipTemplate[$sevenZipTemplate.Count - 1] -cne '<ordered input basenames>') {
    throw 'Unexpected 7-Zip command template in baseline report.'
}
$sevenZipOptions = [string[]]@($sevenZipTemplate[0..($sevenZipTemplate.Count - 3)])
$scriptHashAtStart = Get-Sha256 $PSCommandPath
foreach ($source in $baseline.provenance.source_sha256) {
    $sourcePath = Join-Path $sourceRoot ([string]$source.path)
    if ((Get-Sha256 $sourcePath) -cne [string]$source.sha256) {
        throw "A source file changed before the timing screen: $($source.path)"
    }
}

$null = New-Item -ItemType Directory -Path $work
Assert-NoReparse $work
$warmupDirectory = Join-Path $work 'warmup'
$null = New-Item -ItemType Directory -Path $warmupDirectory
$records = @()
$warmups = @()

function Invoke-KhcRun([string]$CaseName, [string]$Pair, [string]$Order, [string]$Suffix) {
    $case = if ($CaseName -ceq 'ordinal-ascii-name') { $ordinal[0] } else { $content[0] }
    $output = Join-Path $script:activeOutputDirectory "khc-$CaseName-$Suffix.khc"
    $arguments = @('group-encode', [string]$case.opaque_group.path) + $khcOptions
    $run = Invoke-TimedProcess $lab ([string[]]$arguments) 'file' $output $sourceRoot "KHC $CaseName $Suffix"
    Assert-RecordedOutput $run ([long]$case.khc.frame_bytes) ([string]$case.khc.frame_sha256)
    [pscustomobject][ordered]@{
        pair = $Pair
        order = $Order
        case = $CaseName
        tool = 'KHC'
        elapsed_ms = $run.elapsed_ms
        output_path = $run.output_path
        output_bytes = $run.output_bytes
        output_sha256 = $run.output_sha256
        exit_code = $run.exit_code
    }
}

function Invoke-SevenZipRun([string]$Pair, [string]$Order, [string]$Suffix) {
    $output = Join-Path $script:activeOutputDirectory "sevenzip-$Suffix.7z"
    $arguments = @($sevenZipOptions) + @($output) + $inputNames
    $run = Invoke-TimedProcess $sevenZip ([string[]]$arguments) 'discard' '' $inputDirectory "7-Zip $Suffix" $output
    Assert-RecordedOutput $run ([long]$ordinal[0].seven_zip.archive_bytes) ([string]$ordinal[0].seven_zip.archive_sha256)
    [pscustomobject][ordered]@{
        pair = $Pair
        order = $Order
        case = 'ordinal-ascii-name'
        tool = '7-Zip'
        elapsed_ms = $run.elapsed_ms
        output_path = $run.output_path
        output_bytes = $run.output_bytes
        output_sha256 = $run.output_sha256
        exit_code = $run.exit_code
    }
}

$script:activeOutputDirectory = $warmupDirectory
$warmups += Invoke-KhcRun 'ordinal-ascii-name' 'warmup' 'warmup' 'ordinal'
$warmups += Invoke-KhcRun 'content-based' 'warmup' 'warmup' 'content'
$warmups += Invoke-SevenZipRun 'warmup' 'warmup' 'sevenzip'
$script:activeOutputDirectory = $work

for ($round = 1; $round -le 7; $round++) {
    $forwardPair = "forward-$('{0:D2}' -f $round)"
    $records += Invoke-KhcRun 'ordinal-ascii-name' $forwardPair 'ordinal-7z-content' "$forwardPair-ordinal"
    $records += Invoke-SevenZipRun $forwardPair 'ordinal-7z-content' "$forwardPair-sevenzip"
    $records += Invoke-KhcRun 'content-based' $forwardPair 'ordinal-7z-content' "$forwardPair-content"

    $reversePair = "reverse-$('{0:D2}' -f $round)"
    $records += Invoke-KhcRun 'content-based' $reversePair 'content-7z-ordinal' "$reversePair-content"
    $records += Invoke-SevenZipRun $reversePair 'content-7z-ordinal' "$reversePair-sevenzip"
    $records += Invoke-KhcRun 'ordinal-ascii-name' $reversePair 'content-7z-ordinal' "$reversePair-ordinal"
}

foreach ($snapshot in $snapshots) { Assert-FileSnapshot $snapshot }
if ((Get-Sha256 $lab) -cne [string]$baseline.provenance.lab_sha256 -or
    (Get-Sha256 $sevenZip) -cne [string]$baseline.provenance.seven_zip_sha256) {
    throw 'A measured executable changed during the timing screen.'
}
if ((Get-Sha256 $PSCommandPath) -cne $scriptHashAtStart) {
    throw 'The timing script changed during the screen.'
}
foreach ($source in $baseline.provenance.source_sha256) {
    $sourcePath = Join-Path $sourceRoot ([string]$source.path)
    if ((Get-Sha256 $sourcePath) -cne [string]$source.sha256) {
        throw "A source file changed during the timing screen: $($source.path)"
    }
}
foreach ($run in @($warmups) + @($records)) {
    if ((Get-Item -LiteralPath $run.output_path).Length -ne [long]$run.output_bytes -or
        (Get-Sha256 $run.output_path) -cne [string]$run.output_sha256) {
        throw "A measured output changed after validation: $($run.output_path)"
    }
}

$pairs = @()
for ($round = 1; $round -le 7; $round++) {
    foreach ($direction in @('forward', 'reverse')) {
        $pairId = "$direction-$('{0:D2}' -f $round)"
        $pairRecords = @($records | Where-Object { $_.pair -ceq $pairId })
        $ordinalRun = @($pairRecords | Where-Object { $_.tool -ceq 'KHC' -and $_.case -ceq 'ordinal-ascii-name' })
        $contentRun = @($pairRecords | Where-Object { $_.tool -ceq 'KHC' -and $_.case -ceq 'content-based' })
        $sevenZipRun = @($pairRecords | Where-Object { $_.tool -ceq '7-Zip' })
        if ($ordinalRun.Count -ne 1 -or $contentRun.Count -ne 1 -or $sevenZipRun.Count -ne 1) {
            throw "Incomplete timing pair: $pairId"
        }
        $pairs += [pscustomobject][ordered]@{
            pair = $pairId
            ordinal_khc_ms = $ordinalRun[0].elapsed_ms
            content_khc_ms = $contentRun[0].elapsed_ms
            seven_zip_ms = $sevenZipRun[0].elapsed_ms
            content_khc_reduction_vs_ordinal_percent = 100.0 * ($ordinalRun[0].elapsed_ms - $contentRun[0].elapsed_ms) / $ordinalRun[0].elapsed_ms
            content_khc_reduction_vs_seven_zip_percent = 100.0 * ($sevenZipRun[0].elapsed_ms - $contentRun[0].elapsed_ms) / $sevenZipRun[0].elapsed_ms
        }
    }
}
$forwardPairs = @($pairs | Where-Object { $_.pair.StartsWith('forward-') })
$reversePairs = @($pairs | Where-Object { $_.pair.StartsWith('reverse-') })
$ordinalTimes = [double[]]@($records | Where-Object { $_.tool -ceq 'KHC' -and $_.case -ceq 'ordinal-ascii-name' } | ForEach-Object { $_.elapsed_ms })
$contentTimes = [double[]]@($records | Where-Object { $_.tool -ceq 'KHC' -and $_.case -ceq 'content-based' } | ForEach-Object { $_.elapsed_ms })
$sevenZipTimes = [double[]]@($records | Where-Object { $_.tool -ceq '7-Zip' } | ForEach-Object { $_.elapsed_ms })
$forwardReduction = [double[]]@($forwardPairs | ForEach-Object { $_.content_khc_reduction_vs_ordinal_percent })
$reverseReduction = [double[]]@($reversePairs | ForEach-Object { $_.content_khc_reduction_vs_ordinal_percent })
$forwardVsSevenZip = [double[]]@($forwardPairs | ForEach-Object { $_.content_khc_reduction_vs_seven_zip_percent })
$reverseVsSevenZip = [double[]]@($reversePairs | ForEach-Object { $_.content_khc_reduction_vs_seven_zip_percent })

$report = [ordered]@{
    status = 'success: paired end-to-end compression timing; fixed Canterbury development corpus only'
    completed_utc = [DateTime]::UtcNow.ToString('o')
    provenance = [ordered]@{
        os = [Environment]::OSVersion.VersionString
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
        invocation_working_directory = [Environment]::CurrentDirectory
        source_root = $sourceRoot
        work_directory = $work
        baseline_report_path = $baselinePath
        baseline_report_sha256 = $expectedBaselineHash
        script_path = $PSCommandPath
        script_sha256 = $scriptHashAtStart
        rust_version = $baseline.provenance.rust_version_from_project_directory
        lab_path = $lab
        lab_sha256 = $baseline.provenance.lab_sha256
        seven_zip_path = $sevenZip
        seven_zip_sha256 = $baseline.provenance.seven_zip_sha256
        seven_zip_identity = $baseline.provenance.seven_zip_identity
        source_sha256 = $baseline.provenance.source_sha256
    }
    corpus = [ordered]@{
        collection = 'canterbury-development'
        role = 'development'
        source_directory = $baseline.corpus.source_directory
        snapshots = $snapshots
        entry_order_for_seven_zip = $inputNames
    }
    settings = [ordered]@{
        khc_options = $khcOptions
        seven_zip_options = $sevenZipOptions
        warmups_per_tool = 1
        paired_repetitions_per_order = 7
        output_volume = [IO.Path]::GetPathRoot($work)
        timing_scope = 'process start through output stream flush/child exit; excludes post-run hashing'
        memory_measured = $false
        seven_zip_observed_order_is_canonical_ordinal = $true
        content_based_physical_order_matches_seven_zip = $false
    }
    verification = [ordered]@{
        baseline_report_sha_checked = $true
        source_and_snapshot_hash_checked_before_and_after = $true
        all_generated_frames_match_size_screen_byte_count_and_sha = $true
        all_generated_archives_match_size_screen_byte_count_and_sha = $true
        all_generated_outputs_rehashed_after_timing = $true
        timings_include_equal_file_output_write_path = $true
    }
    summary = [ordered]@{
        khc_ordinal_median_ms = $(Get-Median $ordinalTimes)
        khc_content_median_ms = $(Get-Median $contentTimes)
        seven_zip_ordinal_median_ms = $(Get-Median $sevenZipTimes)
        content_khc_vs_ordinal_forward_paired_median_reduction_percent = $(Get-Median $forwardReduction)
        content_khc_vs_ordinal_reverse_paired_median_reduction_percent = $(Get-Median $reverseReduction)
        content_khc_vs_7zip_forward_paired_median_reduction_percent = $(Get-Median $forwardVsSevenZip)
        content_khc_vs_7zip_reverse_paired_median_reduction_percent = $(Get-Median $reverseVsSevenZip)
        content_order_meets_3_percent_forward_gate = (Get-Median $forwardReduction) -ge 3.0
        content_order_meets_3_percent_reverse_gate = (Get-Median $reverseReduction) -ge 3.0
        faster_than_seven_zip_both_order_directions = (Get-Median $forwardVsSevenZip) -gt 0 -and (Get-Median $reverseVsSevenZip) -gt 0
    }
    warmups = $warmups
    paired_samples = $pairs
    measurements = $records
    notes = @(
        'All measurements are end-to-end CLI wall time on the same logical 11-file set; KHC content order is KHSGRP1 and 7-Zip observed physical order is ordinal.',
        'Output file creation, process launch, input reads, encoding, and output flush are timed. Output hashing and report serialization are outside the timed interval.',
        'This development-corpus experiment is not a holdout or general 7-Zip superiority claim.'
    )
}
$reportPath = Join-Path $work 'report.json'
$reportJson = $report | ConvertTo-Json -Depth 15
$reportStream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$reportWriter = [IO.StreamWriter]::new($reportStream, [Text.UTF8Encoding]::new($false))
try { $reportWriter.Write($reportJson) }
finally { $reportWriter.Dispose() }

$report.summary | ConvertTo-Json -Depth 5
