$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$sourceScript = Join-Path $PSScriptRoot 'test.ps1'
$sourceLines = Get-Content -LiteralPath $sourceScript
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$desktopRunner = Join-Path $repositoryRoot 'artifacts\Release\DesktopRunner.exe'
$candidate = Join-Path $repositoryRoot 'artifacts\Release\UNLHA32RE.dll'
$testProgram = Join-Path $repositoryRoot 'artifacts\Release\CompatibilityTests.exe'
$oracle = Join-Path $repositoryRoot 'sample\ulh3300_extracted\UNLHA32.DLL'
$fixtureRoot = Join-Path $repositoryRoot 'sample\lha-master\tests'
$testWorkspaceBase = Join-Path $repositoryRoot 'build'
$integrationRoot = Join-Path $testWorkspaceBase 'integration-tail24-20260911'
if (Test-Path -LiteralPath $integrationRoot) {
    throw "Continuation workspace already exists: $integrationRoot"
}
New-Item -ItemType Directory -Path $integrationRoot | Out-Null

foreach ($requiredPath in @($desktopRunner, $candidate, $testProgram, $oracle, $fixtureRoot)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required test asset not found: $requiredPath"
    }
}

$rewriteLevelsRoot = Join-Path $integrationRoot 'rewrite-levels'
$rewriteSourceRoot = Join-Path $testWorkspaceBase 'integration-tail9-20260910'
$rewriteLevelsSource = Join-Path $rewriteSourceRoot 'rewrite-levels\seed-l2.lzh'
if (-not (Test-Path -LiteralPath $rewriteLevelsSource)) {
    throw "Required rewrite fixture not found: $rewriteLevelsSource"
}
New-Item -ItemType Directory -Path $rewriteLevelsRoot | Out-Null
Copy-Item -LiteralPath $rewriteLevelsSource -Destination (Join-Path $rewriteLevelsRoot 'seed-l2.lzh')

$CodecPayloadDisplay = 'Focused'
$CrcDialogCoverage = 'Full'
$CompareUpdatePolicyOracle = $false
$completedRoot = Join-Path $testWorkspaceBase 'integration-tail12-20260911'
$memorySelectionArchive = Join-Path $completedRoot 'memory-selection/selection.lzh'
$memoryCompressedRoot = Join-Path $completedRoot 'memory-selection-compressed'
$oracleCheckRoot = Join-Path $completedRoot 'check-archive-oracle'
$oracleFindRoot = Join-Path $completedRoot 'find-state-oracle'
$findTreeRoot = Join-Path $completedRoot 'find-pattern-tree'
$findUnicodeArchive = Join-Path $completedRoot 'find-pattern-unicode/pattern.lzh'
foreach ($requiredPath in @($memorySelectionArchive, $memoryCompressedRoot, $oracleCheckRoot,
        $oracleFindRoot, $findTreeRoot, $findUnicodeArchive)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Missing prior fixture: $requiredPath" }
}
& $desktopRunner --require-isolated
if ($LASTEXITCODE -ne 0) {
    throw 'Continuation must run on the isolated desktop.'
}
Write-Host "Continuation workspace: $integrationRoot"
Write-Host "Candidate SHA256: $((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash)"
Write-Host "Oracle SHA256: $((Get-FileHash -LiteralPath $oracle -Algorithm SHA256).Hash)"

# 同じ DLL の設定・一覧成功結果を再利用し、メモリ展開以降を再開する。
$continuationEnd = [Array]::FindIndex($sourceLines, [Predicate[string]]{ param($line) $line -match "Write-Host 'Snapshot: original Unicode extension headers'" })
if ($continuationEnd -lt 1190) { throw 'Continuation endpoint not found.' }
$continuationStart = [Array]::FindIndex($sourceLines, [Predicate[string]]{ param($line) $line -match '^        \$oracleMemoryState = @\(' })
if ($continuationStart -lt 0 -or $continuationStart -ge $continuationEnd) { throw 'Continuation start not found.' }
$continuationBody = $sourceLines[$continuationStart..$continuationEnd]
try {
    $scriptsRootLiteral = "'" + $PSScriptRoot.Replace("'", "''") + "'"
    $continuationText = ($continuationBody -join "`n").Replace('$PSScriptRoot', $scriptsRootLiteral)
    $parallelSummary = Join-Path $testWorkspaceBase 'memory-selection-parallel-20260911/summary.json'
    if (-not (Test-Path -LiteralPath $parallelSummary)) { throw "Memory selection summary not found: $parallelSummary" }
    $parallelResults = @(Get-Content -LiteralPath $parallelSummary -Raw | ConvertFrom-Json)
    if ($parallelResults.Count -ne 21 -or @($parallelResults | Where-Object {
        $_.OracleExit -ne 0 -or $_.CandidateExit -ne 0 -or $_.DifferenceCount -ne 0 -or $_.ExpectedRows -ne 96
    }).Count -ne 0) { throw 'Memory selection parallel summary is incomplete or mismatched.' }
    Write-Host 'Memory selection: 21 modes, 2016 A/W/callback capacity cases compatible.'
    Invoke-Expression ("if (Test-Path -LiteralPath `$oracle) {" + $continuationText + "`n}")
    Write-Host 'Continuation body (remaining memory through Unicode extension headers) completed.'
}
catch {
    Write-Host ("Continuation error: " + $_.Exception.ToString())
    Write-Host ("Continuation stack: " + $_.ScriptStackTrace)
    exit 1
}
