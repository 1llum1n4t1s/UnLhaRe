$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$integrationRoot = Join-Path $repositoryRoot 'build\integration-tail25-20260911'
$completedRoot = Join-Path $repositoryRoot 'build\integration-tail12-20260911'
$desktopRunner = Join-Path $repositoryRoot 'artifacts\Release\DesktopRunner.exe'
$candidate = Join-Path $repositoryRoot 'artifacts\Release\UNLHA32RE.dll'
$testProgram = Join-Path $repositoryRoot 'artifacts\Release\CompatibilityTests.exe'
$oracle = Join-Path $repositoryRoot 'sample\ulh3300_extracted\UNLHA32.DLL'
$memorySelectionArchive = Join-Path $completedRoot 'memory-selection\selection.lzh'
$memoryCompressedRoot = Join-Path $integrationRoot 'memory-damage-compressed'
$checkStateRoot = Join-Path $integrationRoot 'check-state-boundaries'
$checkValidArchive = Join-Path $completedRoot 'check-archive-oracle\valid.lzh'
$findUnicodeArchive = Join-Path $completedRoot 'find-pattern-unicode\pattern.lzh'
$oracleFindRoot = Join-Path $completedRoot 'find-state-oracle'
$findTreeRoot = Join-Path $completedRoot 'find-pattern-tree'
$huffmanArchive = Join-Path $memoryCompressedRoot 'body-ff.lzh'

foreach ($requiredPath in @($integrationRoot, $desktopRunner, $candidate, $testProgram, $oracle,
        $memorySelectionArchive, $memoryCompressedRoot, $checkStateRoot, $checkValidArchive,
        $findUnicodeArchive, $oracleFindRoot, $findTreeRoot, $huffmanArchive)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Required post-memory path not found: $requiredPath" }
}

$sourceScript = Join-Path $PSScriptRoot 'test.ps1'
$sourceLines = Get-Content -LiteralPath $sourceScript
$start = [Array]::FindIndex($sourceLines, [Predicate[string]]{ param($line) $line -match '^        # 失敗後の同一プロセス再利用' })
$end = [Array]::FindIndex($sourceLines, [Predicate[string]]{ param($line) $line -match "Write-Host 'Snapshot: original Unicode extension headers'" })
if ($start -lt 0 -or $end -le $start) { throw 'Post-memory continuation range not found.' }
$scriptsRootLiteral = "'" + $PSScriptRoot.Replace("'", "''") + "'"
$body = (($sourceLines[$start..$end] -join "`n").Replace('$PSScriptRoot', $scriptsRootLiteral))
Invoke-Expression $body
Write-Host 'Post-memory continuation (boundary through Unicode/progress) completed.'
