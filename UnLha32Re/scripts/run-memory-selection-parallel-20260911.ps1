[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Runner,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$ArchiveRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [int]$TimeoutSeconds = 600,
    [int]$BatchSize = 4
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
foreach ($path in @($TestProgram, $Runner, $Oracle, $Candidate, $ArchiveRoot)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}
if (Test-Path -LiteralPath $OutputRoot) { throw "Output root already exists: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$archives = @(
    Join-Path $ArchiveRoot 'memory-selection/selection.lzh'
    Join-Path $ArchiveRoot 'memory-selection-compressed/selection.lzh'
    Join-Path $ArchiveRoot 'find-pattern-unicode/pattern.lzh'
)
$modes = @('none', 'a32', 'w32', 'a64', 'w64', 'reject', 'rename')
$tasks = @(
    foreach ($archive in $archives) {
        foreach ($mode in $modes) {
            [pscustomobject]@{ Archive = $archive; Mode = $mode }
        }
    }
)
foreach ($archive in $archives) {
    if (-not (Test-Path -LiteralPath $archive)) { throw "Memory archive not found: $archive" }
}

$jobScript = {
    param($task, $testProgram, $runner, $oracle, $candidate, $timeoutSeconds, $outputRoot)
    $safeName = ((Split-Path -Leaf (Split-Path -Parent $task.Archive)) + '-' + $task.Mode) -replace '[^A-Za-z0-9_.-]', '_'
    $taskRoot = Join-Path $outputRoot $safeName
    New-Item -ItemType Directory -Path $taskRoot | Out-Null
    $oracleLog = Join-Path $taskRoot 'oracle.log'
    $candidateLog = Join-Path $taskRoot 'candidate.log'
    $oracleRows = @(& $runner --timeout-seconds $timeoutSeconds $testProgram --memory-selection-probe $oracle $task.Archive $task.Mode 2>&1 |
        ForEach-Object { "$_" } | Tee-Object -FilePath $oracleLog)
    $oracleExit = $LASTEXITCODE
    $candidateRows = @(& $runner --timeout-seconds $timeoutSeconds $testProgram --memory-selection-probe $candidate $task.Archive $task.Mode 2>&1 |
        ForEach-Object { "$_" } | Tee-Object -FilePath $candidateLog)
    $candidateExit = $LASTEXITCODE
    $difference = @(Compare-Object -ReferenceObject $oracleRows -DifferenceObject $candidateRows -SyncWindow 0)
    $expectedRows = @($candidateRows | Where-Object { $_ -match '^memory\.[01]\.[0-3]\.\d+=' }).Count
    [pscustomobject]@{
        Archive = $task.Archive
        Mode = $task.Mode
        OracleExit = $oracleExit
        CandidateExit = $candidateExit
        OracleRows = $oracleRows.Count
        CandidateRows = $candidateRows.Count
        ExpectedRows = $expectedRows
        DifferenceCount = $difference.Count
        Difference = (($difference | Select-Object -First 12 | Out-String).Trim())
    }
}

$results = [System.Collections.Generic.List[object]]::new()
for ($offset = 0; $offset -lt $tasks.Count; $offset += $BatchSize) {
    $end = [Math]::Min($offset + $BatchSize, $tasks.Count)
    $jobs = @()
    for ($index = $offset; $index -lt $end; $index++) {
        $jobs += Start-ThreadJob -ScriptBlock $jobScript -ArgumentList @(
            $tasks[$index], $TestProgram, $Runner, $Oracle, $Candidate, $TimeoutSeconds, $OutputRoot)
    }
    try {
        Wait-Job -Job $jobs -Timeout ($TimeoutSeconds * 2 + 120) | Out-Null
        foreach ($job in $jobs) {
            if ($job.State -ne 'Completed') { throw "Memory selection job did not complete: $($job.Id), state=$($job.State)" }
            $results.Add((Receive-Job -Job $job))
        }
    }
    finally {
        Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    }
    $results | Sort-Object Archive,Mode | Format-Table Archive,Mode,OracleExit,CandidateExit,ExpectedRows,DifferenceCount -AutoSize
}

$summaryPath = Join-Path $OutputRoot 'summary.json'
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$failed = @($results | Where-Object {
    $_.OracleExit -ne 0 -or $_.CandidateExit -ne 0 -or $_.DifferenceCount -ne 0 -or $_.ExpectedRows -ne 96
})
if ($failed.Count -ne 0) {
    $failed | Format-List | Out-Host
    throw "Memory selection comparison failed for $($failed.Count) of $($results.Count) modes."
}
Write-Host "Memory selection parallel: $($results.Count) modes, 2016 A/W/callback capacity cases compatible."
