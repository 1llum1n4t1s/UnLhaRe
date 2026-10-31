$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$integrationRoot = Join-Path $repositoryRoot 'build\integration-tail25-20260911'
$desktopRunner = Join-Path $repositoryRoot 'artifacts\Release\DesktopRunner.exe'
$candidate = Join-Path $repositoryRoot 'artifacts\Release\UNLHA32RE.dll'
$testProgram = Join-Path $repositoryRoot 'artifacts\Release\CompatibilityTests.exe'
$oracle = Join-Path $repositoryRoot 'sample\ulh3300_extracted\UNLHA32.DLL'
$unicodeFixture = Join-Path $integrationRoot 'unicode-path-fixed.lzh'

foreach ($requiredPath in @($integrationRoot, $desktopRunner, $candidate, $testProgram, $oracle, $unicodeFixture)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Required progress path not found: $requiredPath" }
}
& $desktopRunner --require-isolated
if ($LASTEXITCODE -ne 0) { throw 'Progress continuation must run on the isolated desktop.' }

foreach ($mode in 0, 1, 2) {
    $oracleRoot = Join-Path $integrationRoot "progress-add-oracle-$mode"
    $candidateRoot = Join-Path $integrationRoot "progress-add-candidate-$mode"
    $oracleRows = @(& $testProgram --progress-add-probe $oracle $oracleRoot $mode 2>&1 | ForEach-Object { "$_" })
    $oracleExit = $LASTEXITCODE
    $candidateRows = @(& $testProgram --progress-add-probe $candidate $candidateRoot $mode 2>&1 | ForEach-Object { "$_" })
    $candidateExit = $LASTEXITCODE
    $difference = @(Compare-Object -ReferenceObject $oracleRows -DifferenceObject $candidateRows -SyncWindow 0)
    $expectedCount = if ($mode -eq 0) { 0 } else { 8 }
    if ($oracleExit -ne 0 -or $candidateExit -ne 0 -or
        $oracleRows -notcontains "add.count=$expectedCount" -or
        $candidateRows -notcontains "add.count=$expectedCount" -or
        $difference.Count -ne 0) {
        Write-Output "--- oracle n$mode (exit $oracleExit) ---"
        $oracleRows
        Write-Output "--- candidate n$mode (exit $candidateExit) ---"
        $candidateRows
        Write-Output ($difference | Out-String)
        throw "追加圧縮進捗 n$mode が一致しません。"
    }
    Write-Host "Add progress n${mode}: $expectedCount records compatible"
}
Write-Host 'Add progress callback: n0/n1/n2 selection, exact sequences and metadata compatible'
Write-Host 'Snapshot: original Unicode extension headers'
