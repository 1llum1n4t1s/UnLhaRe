[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$EmptyArchive,
    [Parameter(Mandatory)][string]$DataArchive,
    [switch]$ReportDifferences
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$EmptyArchive = (Resolve-Path -LiteralPath $EmptyArchive).Path
$DataArchive = (Resolve-Path -LiteralPath $DataArchive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$script:tailCases = 0
$script:tailSnapshots = 0
$script:tailFailures = 0

function Compare-TailProbe([string]$Probe, [string[]]$Values) {
    $arguments = @('--registry', '', $Probe, $Oracle) + $Values
    $expected = @(& $TestProgram @arguments)
    $originalExit = $LASTEXITCODE
    $arguments[3] = $Candidate
    $actual = @(& $TestProgram @arguments)
    if ($originalExit -ne 0 -or $LASTEXITCODE -ne 0 -or $expected.Count -eq 0 -or $actual.Count -eq 0) {
        throw "末尾判定試験が実行できません: $Probe / $($Values -join ' ')"
    }
    $difference = @(Compare-Object $expected $actual -SyncWindow 0)
    if ($difference.Count -ne 0) {
        $details = $difference | Select-Object -First 6 | ForEach-Object {
            $side = if ($_.SideIndicator -eq '<=') { 'original' } else { 'candidate' }
            "$side`: $($_.InputObject)"
        } | Out-String -Width 1000
        $message = "末尾判定が一致しません: $Probe / $($Values -join ' ')`n$details"
        if (!$ReportDifferences) { throw $message }
        Write-Host $message
        $script:tailFailures++
    }
    $script:tailCases++
    $script:tailSnapshots += $expected.Count
}

$fixtureDirectories = @()
foreach ($inputArchive in @($EmptyArchive, $DataArchive)) {
    $directory = Join-Path $Workspace ('fixtures-' + $fixtureDirectories.Count)
    & $TestProgram --create-open-size-fixtures $inputArchive $directory
    if ($LASTEXITCODE -ne 0) { throw '末尾判定 fixture の作成に失敗しました。' }
    $fixtureDirectories += $directory
    foreach ($fixture in Get-ChildItem -LiteralPath $directory -Filter '*.lzh' -File) {
        Compare-TailProbe '--check-existing-archive-probe' @($fixture.FullName)
        Compare-TailProbe '--archive-tail-probe' @($fixture.FullName)
        foreach ($api in 0..5) {
            Compare-TailProbe '--open-state-probe' @($fixture.FullName, '@valid', "$api", 'retry')
        }
        if ($fixture.BaseName -in @('size-55', 'size-64', 'size-79', 'size-511',
                'tail-80-zip', 'tail-125', 'tail-129', 'empty-lh0', 'empty-lh5')) {
            foreach ($command in @('l', 'v', 't', 'p', 'l -n1', 'l -n2',
                    'l -jsg0', 't -jsg0', 'p -jsg0', 'l -jsg1 -jsg0', 'l -jsg0 -jsg1')) {
                $line = $command + ' -gm1 "' + $fixture.FullName + '"'
                Compare-TailProbe '--command-probe' @($line)
                Compare-TailProbe '--command-probe-a' @($line)
                Compare-TailProbe '--command-probe-a' @($line, 'A')
            }
        }
    }
}

# 拒否される書庫への更新・展開は、すべて専用入力と専用出力だけで試す。
$foreignSource = Join-Path $fixtureDirectories[0] 'tail-80-zip.lzh'
$sourceHash = (Get-FileHash -LiteralPath $foreignSource).Hash
$member = Join-Path $Workspace 'member.lzh'
Copy-Item -LiteralPath $EmptyArchive -Destination $member
foreach ($variant in @('legacy', 'A', 'W', 'unicode-W')) {
    $directory = Join-Path $Workspace $variant
    New-Item -ItemType Directory -Path $directory | Out-Null
    $archive = Join-Path $directory $(if ($variant -eq 'unicode-W') { '書庫_🧪.lzh' } else { 'input.lzh' })
    Copy-Item -LiteralPath $foreignSource -Destination $archive
    $output = Join-Path $directory 'output'
    New-Item -ItemType Directory -Path $output | Out-Null
    foreach ($command in @('a', 'u', 'f', 'm', 'd', 'e', 'x', 'j', 'y', 'n', 'c', 's')) {
        $line = $command + ' -gm1 -y1 "' + $archive + '"'
        if ($command -in @('a', 'u', 'f', 'm', 'j')) { $line += ' "' + $member + '"' }
        elseif ($command -in @('e', 'x', 's')) { $line += ' "' + $output + '\"' }
        else { $line += ' *' }
        if ($variant -eq 'legacy') { Compare-TailProbe '--command-probe-a' @($line) }
        elseif ($variant -eq 'A') { Compare-TailProbe '--command-probe-a' @($line, 'A') }
        else { Compare-TailProbe '--command-probe' @($line) }
        if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash -ne $sourceHash -or
                !(Test-Path -LiteralPath $member) -or @(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) {
            throw "拒否された書庫または入力・展開先が変更されています: $variant / $command"
        }
    }
}
if ($script:tailFailures -ne 0) {
    throw "末尾判定試験: $script:tailCases 組・$script:tailSnapshots 項目中、$script:tailFailures 組が不一致です。"
}
Write-Host "Archive tails: $script:tailCases API/command sequences, $script:tailSnapshots snapshots compatible; rejected writes unchanged"
