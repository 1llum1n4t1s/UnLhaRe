[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Runner,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$ValidArchive,
    [Parameter(Mandatory)][string[]]$Archives,
    [Parameter(Mandatory)][string]$Workspace,
    [int]$TimeoutSeconds = 30,
    [int]$BatchSize = 4
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
foreach ($path in @($TestProgram, $Runner, $Oracle, $Candidate, $ValidArchive) + $Archives) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required memory failure path not found: $path" }
}
if ($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 600) { throw 'Memory failure timeout is out of range.' }
if ($BatchSize -lt 1 -or $BatchSize -gt 16) { throw 'Memory failure batch size is out of range.' }
if (Test-Path -LiteralPath $Workspace) { throw "Memory failure workspace already exists: $Workspace" }
New-Item -ItemType Directory -Path $Workspace | Out-Null

$tasks = @(
    $taskId = 0
    foreach ($archive in $Archives) {
        foreach ($wide in 0, 1) {
            foreach ($selection in 0, 1, 2) {
                foreach ($capacity in 1, 1024, 4096, 8192) {
                    [pscustomobject]@{
                        Id = $taskId++
                        Archive = $archive
                        Wide = $wide
                        Selection = $selection
                        Capacity = $capacity
                    }
                }
            }
        }
    }
)
if ($tasks.Count -ne $Archives.Count * 24) {
    throw "Memory failure task count is unexpected: $($tasks.Count)"
}

$jobScript = {
    param($task, $testProgram, $runner, $oracle, $candidate, $validArchive, $timeoutSeconds, $workspace)
    $taskRoot = Join-Path $workspace ('case-' + $task.Id.ToString('D4'))
    New-Item -ItemType Directory -Path $taskRoot | Out-Null

    function Invoke-MemoryFailureCase {
        param([string]$Name, [string]$Dll)
        $log = Join-Path $taskRoot ($Name + '.log')
        $output = @(& $runner --timeout-seconds $timeoutSeconds $testProgram `
            --memory-failure-case-probe $Dll $task.Archive $validArchive `
            $task.Wide $task.Selection $task.Capacity 2>&1 |
            ForEach-Object { "$_" } | Tee-Object -FilePath $log)
        [pscustomobject]@{
            Name = $Name
            Exit = $LASTEXITCODE
            Output = $output
            Comparable = @($output | Where-Object { $_ -match '^failure\.' })
            Rows = @($output | Where-Object { $_ -match '^failure\.[01]\.[0-2]\.\d+=' }).Count
        }
    }

    $oracleResult = Invoke-MemoryFailureCase 'oracle' $oracle
    $candidateResult = Invoke-MemoryFailureCase 'candidate' $candidate
    $difference = @(Compare-Object -ReferenceObject $oracleResult.Comparable `
        -DifferenceObject $candidateResult.Comparable -SyncWindow 0)
    [pscustomobject]@{
        Id = $task.Id
        Archive = $task.Archive
        Wide = $task.Wide
        Selection = $task.Selection
        Capacity = $task.Capacity
        OracleExit = $oracleResult.Exit
        CandidateExit = $candidateResult.Exit
        OracleRows = $oracleResult.Rows
        CandidateRows = $candidateResult.Rows
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
            $tasks[$index], $TestProgram, $Runner, $Oracle, $Candidate, $ValidArchive,
            $TimeoutSeconds, $Workspace)
    }
    try {
        Wait-Job -Job $jobs -Timeout ($TimeoutSeconds * 2 + 120) | Out-Null
        foreach ($job in $jobs) {
            if ($job.State -ne 'Completed') {
                throw "Memory failure case job did not complete: $($job.Id), state=$($job.State)"
            }
            $results.Add((Receive-Job -Job $job))
        }
    }
    finally {
        Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    }
    $completed = $results.Count
    if ($completed % 24 -eq 0 -or $completed -eq $tasks.Count) {
        Write-Host "Memory failure cases: $completed/$($tasks.Count) independent probes completed"
    }
}

$summaryPath = Join-Path $Workspace 'summary.json'
$results | Sort-Object Id | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$failed = @($results | Where-Object {
    $_.OracleExit -ne 0 -or $_.CandidateExit -ne 0 -or
    $_.OracleRows -ne 1 -or $_.CandidateRows -ne 1 -or $_.DifferenceCount -ne 0
})
if ($failed.Count -ne 0) {
    $failed | Format-List | Out-Host
    throw "Memory failure comparison failed for $($failed.Count) of $($results.Count) cases."
}
Write-Host "Memory damage: $($results.Count) A/W CRC/header/truncation, selection, capacity, and retained-state cases compatible"
