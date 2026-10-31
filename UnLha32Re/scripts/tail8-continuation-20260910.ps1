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
$integrationRoot = Join-Path $testWorkspaceBase 'integration-tail8c-20260910'
if (Test-Path -LiteralPath $integrationRoot) {
    throw "Continuation workspace already exists: $integrationRoot"
}
New-Item -ItemType Directory -Path $integrationRoot | Out-Null

$existingTop = Join-Path $repositoryRoot 'build\integration-resume-650293d3054c4488a9ac43956ac76e3c'
$existingIntegration = Get-ChildItem -LiteralPath $existingTop -Directory |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $existingIntegration) {
    throw "Existing integration fixture root not found: $existingTop"
}
$headerCrcCommandsRoot = Join-Path $existingIntegration 'header-crc-commands'
$shortHeadersRoot = Join-Path $existingIntegration 'command-short-headers'
$pmarcCheckRoot = Join-Path $existingIntegration 'pmarc-check'
$extractionBodyRoot = Join-Path $existingIntegration 'level3-body-errors'
foreach ($requiredRoot in @($headerCrcCommandsRoot, $shortHeadersRoot, $pmarcCheckRoot, $extractionBodyRoot)) {
    if (-not (Test-Path -LiteralPath $requiredRoot)) {
        throw "Required fixture root not found: $requiredRoot"
    }
}
$CodecPayloadDisplay = 'Focused'
$CrcDialogCoverage = 'Full'
$CompareUpdatePolicyOracle = $false
Write-Host "Continuation workspace: $integrationRoot"
Write-Host "Candidate SHA256: $((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash)"
Write-Host "Oracle SHA256: $((Get-FileHash -LiteralPath $oracle -Algorithm SHA256).Hash)"
Write-Host "Body fixtures: $extractionBodyRoot"

# Lines 686-1547 of test.ps1 are the uncompleted body after the full CRC-dialog matrix.
# The final closing brace (line 1548) is supplied by this wrapper.
$continuationBody = $sourceLines[685..1546]
try {
    $scriptsRootLiteral = "'" + $PSScriptRoot.Replace("'", "''") + "'"
    $continuationText = ($continuationBody -join "`n").Replace('$PSScriptRoot', $scriptsRootLiteral)
    Invoke-Expression ("if (Test-Path -LiteralPath `$oracle) {" + $continuationText + "`n}")
    Write-Host 'Continuation body (test.ps1 lines 686-1547) completed.'
}
catch {
    Write-Host ("Continuation error: " + $_.Exception.ToString())
    Write-Host ("Continuation stack: " + $_.ScriptStackTrace)
    exit 1
}
