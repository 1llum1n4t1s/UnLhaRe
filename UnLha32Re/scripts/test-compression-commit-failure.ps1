[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('a','u','f','m')][string[]]$Commands = @('a','u','f','m')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'Fresh workspace required' }
$parseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$parseErrors)
$helper = $helperAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-EnumProbe'
},$true)
if ($parseErrors.Count -or !$helper) { throw 'Cannot load bounded probe helper' }
. ([scriptblock]::Create($helper.Extent.Text))
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression commit failure workspace: $Workspace"

$protected = @($TestProgram,$Candidate,$runner,$PSCommandPath | ForEach-Object {
    [pscustomobject]@{ Path=$_; SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$protected | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Workspace 'binaries.json') -Encoding utf8

function Set-CompressionInput([string]$Path,[string]$Value,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}

$seedRoot = Join-Path $Workspace 'seed-source'
$seedTemp = Join-Path $Workspace 'seed-temp'
New-Item -ItemType Directory -Path $seedRoot,$seedTemp | Out-Null
Set-CompressionInput (Join-Path $seedRoot 'a.txt') 'old-a' 2020
Set-CompressionInput (Join-Path $seedRoot 'z.txt') 'old-z' 2020
$seedArchive = Join-Path $Workspace 'seed.lzh'
$seedBase = $seedRoot.TrimEnd('\') + '\'
$seedCommand = "a -h0 -n1 -gm1 -y1 -c1 `"$seedArchive`" `"$seedBase`" a.txt z.txt"
$previousTemp = [Environment]::GetEnvironmentVariable('TEMP','Process')
$previousTmp = [Environment]::GetEnvironmentVariable('TMP','Process')
try {
    [Environment]::SetEnvironmentVariable('TEMP',$seedTemp,'Process')
    [Environment]::SetEnvironmentVariable('TMP',$seedTemp,'Process')
    $seedRows = @(Invoke-EnumProbe (Join-Path $Workspace 'seed') @('--command-probe',$Candidate,$seedCommand) $Workspace)
} finally {
    [Environment]::SetEnvironmentVariable('TEMP',$previousTemp,'Process')
    [Environment]::SetEnvironmentVariable('TMP',$previousTmp,'Process')
}
if ($seedRows -notcontains 'result=0' -or !(Test-Path -LiteralPath $seedArchive)) {
    throw "Cannot create candidate seed archive`n$($seedRows -join "`n")"
}
if (@(Get-ChildItem -LiteralPath $seedTemp -Force).Count) { throw 'Seed compression temporary file remains' }
$seedHash = (Get-FileHash -LiteralPath $seedArchive -Algorithm SHA256).Hash

function New-CommitFixture([string]$Name,[string]$Operation) {
    $root = Join-Path $Workspace $Name
    $sourceDirectory = Join-Path $root 'source'
    $temporaryDirectory = Join-Path $root 'temp'
    New-Item -ItemType Directory -Path $sourceDirectory,$temporaryDirectory | Out-Null
    $archive = Join-Path $root 'archive.lzh'
    Copy-Item -LiteralPath $seedArchive -Destination $archive
    $source = Join-Path $sourceDirectory 'a.txt'
    $payload = "new-$Operation-$Name"
    Set-CompressionInput $source $payload 2024
    [pscustomobject]@{
        Root=$root
        SourceDirectory=$sourceDirectory
        TemporaryDirectory=$temporaryDirectory
        Source=$source
        SourceBytes=[IO.File]::ReadAllBytes($source)
        Archive=$archive
        OldArchiveHash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        Payload=$payload
    }
}

function Get-CompressionCommand($Fixture,[string]$Operation) {
    $base = $Fixture.SourceDirectory.TrimEnd('\') + '\'
    "$Operation -h0 -n1 -gm1 -y1 -c1 `"$($Fixture.Archive)`" `"$base`" a.txt"
}

function Invoke-CommitSequence($Fixture,[string[]]$Steps,[string]$LogName,[string]$ProgressLayout = 'w64') {
    $previousTemp = [Environment]::GetEnvironmentVariable('TEMP','Process')
    $previousTmp = [Environment]::GetEnvironmentVariable('TMP','Process')
    try {
        [Environment]::SetEnvironmentVariable('TEMP',$Fixture.TemporaryDirectory,'Process')
        [Environment]::SetEnvironmentVariable('TMP',$Fixture.TemporaryDirectory,'Process')
        @(Invoke-EnumProbe (Join-Path $Fixture.Root $LogName) (@(
            '--progress-sequence-probe',$Candidate,'none','1041','0','W',$ProgressLayout
        ) + $Steps) $Fixture.Root)
    } finally {
        [Environment]::SetEnvironmentVariable('TEMP',$previousTemp,'Process')
        [Environment]::SetEnvironmentVariable('TMP',$previousTmp,'Process')
    }
}

function Assert-ExclusiveArchive([string]$Archive,[string]$Label) {
    $file = $null
    try {
        $file = [IO.File]::Open($Archive,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch {
        throw "Archive is not exclusively reusable: $Label ($($_.Exception.Message))"
    } finally {
        if ($file) { $file.Dispose() }
    }
}

function Assert-NoCommitTemps($Fixture,[string]$Label) {
    $remaining = @(Get-ChildItem -LiteralPath $Fixture.Root -Recurse -Force -File |
        Where-Object { $_.Name -match '^(?i:LHT|LHC).*?[.]tmp$' })
    if ($remaining.Count) {
        throw "Compression commit temporary files remain: $Label`n$($remaining.FullName -join "`n")"
    }
}

function Assert-SourceRetained($Fixture,[string]$Label) {
    if (!(Test-Path -LiteralPath $Fixture.Source)) { throw "Compression input was removed: $Label" }
    $expected = [Convert]::ToBase64String($Fixture.SourceBytes)
    $actual = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Fixture.Source))
    if ($actual -cne $expected) { throw "Compression input changed: $Label" }
}

function Assert-FailedFixture($Fixture,[string]$Label) {
    if (!(Test-Path -LiteralPath $Fixture.Archive)) { throw "Archive disappeared after failure: $Label" }
    $actualHash = (Get-FileHash -LiteralPath $Fixture.Archive -Algorithm SHA256).Hash
    if ($actualHash -cne $Fixture.OldArchiveHash) {
        throw "Published archive changed after failure: $Label, old=$($Fixture.OldArchiveHash), actual=$actualHash"
    }
    Assert-SourceRetained $Fixture $Label
    Assert-NoCommitTemps $Fixture $Label
    Assert-ExclusiveArchive $Fixture.Archive $Label
}

function Assert-CommandResults([string[]]$Rows,[bool[]]$ExpectedSuccess,[string]$Label) {
    $results = @($Rows | Where-Object { $_ -match '^result=(-?\d+)$' } | ForEach-Object {
        [int]([regex]::Match($_,'^result=(-?\d+)$').Groups[1].Value)
    })
    if ($results.Count -ne $ExpectedSuccess.Count) {
        throw "Unexpected command result count: $Label, expected=$($ExpectedSuccess.Count), actual=$($results.Count)`n$($Rows -join "`n")"
    }
    for ($index = 0; $index -lt $results.Count; $index++) {
        if (($results[$index] -eq 0) -ne $ExpectedSuccess[$index]) {
            throw "Unexpected command result: $Label, index=$index, result=$($results[$index])"
        }
    }
}

function Get-CommandPhaseAudits([string[]]$Rows) {
    $phases = [Collections.Generic.List[object]]::new()
    $phase = $null
    foreach ($row in $Rows) {
        if ($row -match '^phase=(\d+)$') {
            $phase = [pscustomobject]@{
                Index=[int]$Matches[1]
                Result=$null
                PositiveInProcess=0
                Copy=0
            }
            $phases.Add($phase)
        } elseif ($phase -and $row -match '^result=(-?\d+)$') {
            $phase.Result = [int]$Matches[1]
        } elseif ($phase -and $row -match '^progress[.]entry=.*?,state=1,file=(\d+),write=(\d+),') {
            if ([long]$Matches[1] -gt 0 -and [long]$Matches[2] -gt 0 -and
                [long]$Matches[2] -le [long]$Matches[1]) {
                $phase.PositiveInProcess++
            }
        } elseif ($phase -and $row -match '^progress[.]entry=.*?,state=4,') {
            $phase.Copy++
        }
    }
    @($phases | Where-Object { $null -ne $_.Result })
}

function Assert-FaultAudit([string[]]$Rows,[string]$Mode,[string]$Label) {
    $audits = @($Rows | Where-Object { $_ -like "compression-commit-fault=$Mode,*" } | Select-Object -Unique)
    if ($audits.Count -ne 1) { throw "Missing or inconsistent hook audit: $Label`n$($Rows -join "`n")" }
    $expected = switch ($Mode) {
        'copy-fail' { '^compression-commit-fault=copy-fail,initial-move=1,copy=1,partial-bytes=([1-9]\d*),flush=0,final-move=0,source-recorded=1,stage-recorded=1,source-present-at-failure=1,stage-present-at-failure=1$' }
        'flush-fail' { '^compression-commit-fault=flush-fail,initial-move=1,copy=1,partial-bytes=0,flush=1,final-move=0,source-recorded=1,stage-recorded=1,source-present-at-failure=1,stage-present-at-failure=1$' }
        'replace-fail' { '^compression-commit-fault=replace-fail,initial-move=1,copy=1,partial-bytes=0,flush=1,final-move=1,source-recorded=1,stage-recorded=1,source-present-at-failure=1,stage-present-at-failure=1$' }
        'copy-success' { '^compression-commit-fault=copy-success,initial-move=1,copy=1,partial-bytes=0,flush=1,final-move=1,source-recorded=1,stage-recorded=1,source-present-at-failure=0,stage-present-at-failure=0$' }
        default { throw "Unknown fault audit mode: $Mode" }
    }
    if ($audits[0] -notmatch $expected) { throw "Unexpected hook audit: $Label`n$($audits[0])" }
}

function Assert-SuccessFixture($Fixture,[string]$Operation,[string]$Label) {
    foreach ($member in 'a.txt','z.txt') {
        $expected = if ($member -eq 'a.txt') { $Fixture.Payload } else { 'old-z' }
        $command = "p -n1 -gm1 `"$($Fixture.Archive)`" $member"
        $rows = @(Invoke-EnumProbe (Join-Path $Fixture.Root "read-$member") @('--command-probe',$Candidate,$command) $Fixture.Root)
        if ($rows -notcontains 'result=0' -or $rows -notcontains ('output="' + $expected + '"')) {
            throw "Stored member mismatch: $Label/$member`n$($rows -join "`n")"
        }
    }
    if ($Operation -eq 'm') {
        if (Test-Path -LiteralPath $Fixture.Source) { throw "Move source was not removed after success: $Label" }
    } else {
        Assert-SourceRetained $Fixture $Label
    }
    Assert-NoCommitTemps $Fixture $Label
    Assert-ExclusiveArchive $Fixture.Archive $Label
}

$failureModes = @('copy-fail','flush-fail','replace-fail')
$count = 0
$bodyAbortTargetCount = 0
foreach ($operation in $Commands) {
    foreach ($mode in $failureModes) {
        $label = "$operation-$mode-failure"
        $fixture = New-CommitFixture $label $operation
        $command = Get-CompressionCommand $fixture $operation
        $rows = @(Invoke-CommitSequence $fixture @(
            "@compression-commit-fault:$mode",$command,'@compression-commit-audit',
            "@audit-archive-release:$($fixture.Archive)"
        ) 'sequence')
        Assert-CommandResults $rows @($false) $label
        Assert-FaultAudit $rows $mode $label
        if ($rows -notcontains 'archive-released=1,error=0') { throw "Archive handle retained: $label" }
        Assert-FailedFixture $fixture $label
        $count++

        $label = "$operation-$mode-reuse"
        $fixture = New-CommitFixture $label $operation
        $command = Get-CompressionCommand $fixture $operation
        $rows = @(Invoke-CommitSequence $fixture @(
            "@compression-commit-fault:$mode",$command,"@audit-archive-release:$($fixture.Archive)",
            '@compression-commit-fault:off',$command,"@audit-archive-release:$($fixture.Archive)"
        ) 'sequence')
        Assert-CommandResults $rows @($false,$true) $label
        Assert-FaultAudit $rows $mode $label
        if (@($rows | Where-Object { $_ -eq 'archive-released=1,error=0' }).Count -ne 2 -or
            $rows -notcontains 'compression-commit-hooks=off') {
            throw "Same-DLL recovery/release audit failed: $label"
        }
        Assert-SuccessFixture $fixture $operation $label
        $count++
    }

    $label = "$operation-copy-success"
    $fixture = New-CommitFixture $label $operation
    $command = Get-CompressionCommand $fixture $operation
    $rows = @(Invoke-CommitSequence $fixture @(
        '@compression-commit-fault:copy-success',$command,'@compression-commit-audit',
        "@audit-archive-release:$($fixture.Archive)",'@compression-commit-fault:off'
    ) 'sequence')
    Assert-CommandResults $rows @($true) $label
    Assert-FaultAudit $rows 'copy-success' $label
    if ($rows -notcontains 'archive-released=1,error=0' -or $rows -notcontains 'compression-commit-hooks=off') {
        throw "Cross-volume success/release audit failed: $label"
    }
    Assert-SuccessFixture $fixture $operation $label
    $count++

    foreach ($kind in 'failure','reuse') {
        $label = "$operation-inprocess-abort-$kind"
        $fixture = New-CommitFixture $label $operation
        $command = Get-CompressionCommand $fixture $operation
        $steps = @('@abort-after-start',$command,"@audit-archive-release:$($fixture.Archive)")
        if ($kind -eq 'reuse') { $steps += @('@abort-off',$command,"@audit-archive-release:$($fixture.Archive)") }
        $rows = @(Invoke-CommitSequence $fixture $steps 'sequence' 'total')
        [bool[]]$expectedResults = if ($kind -eq 'reuse') { @($false,$true) } else { @($false) }
        Assert-CommandResults -Rows $rows -ExpectedSuccess $expectedResults -Label $label
        $commandPhases = @(Get-CommandPhaseAudits $rows)
        if ($commandPhases.Count -ne $expectedResults.Count -or
            $commandPhases[0].Result -eq 0 -or
            $commandPhases[0].PositiveInProcess -ne 1 -or
            $commandPhases[0].Copy -ne 0) {
            throw "Compression-body INPROCESS abort target was not reached exactly before COPY: $label`n$($rows -join "`n")"
        }
        $bodyAbortTargetCount += $commandPhases[0].PositiveInProcess
        $expectedReleases = if ($kind -eq 'reuse') { 2 } else { 1 }
        if (@($rows | Where-Object { $_ -eq 'archive-released=1,error=0' }).Count -ne $expectedReleases) {
            throw "Compression-body abort retained archive handle: $label"
        }
        if ($kind -eq 'failure') { Assert-FailedFixture $fixture $label }
        else { Assert-SuccessFixture $fixture $operation $label }
        $count++
    }
}

if ((Get-FileHash -LiteralPath $seedArchive -Algorithm SHA256).Hash -cne $seedHash) { throw 'Seed archive changed' }
foreach ($entry in $protected) {
    if ((Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -cne $entry.SHA256) {
        throw "Protected test input changed: $($entry.Path)"
    }
}
Write-Host "Compression commit failure: $count candidate-only fault, cleanup, exact rollback, forced-copy success and same-DLL recovery cases passed; body INPROCESS abort targets=$bodyAbortTargetCount"
