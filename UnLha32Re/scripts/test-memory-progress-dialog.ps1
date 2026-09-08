[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$RunnerPath = (Resolve-Path -LiteralPath $RunnerPath).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'メモリ進捗ダイアログ試験には新しい作業先が必要です。' }
New-Item -ItemType Directory -Path $Workspace | Out-Null

function Invoke-RunnerProbe([string[]]$ProbeArguments) {
    $rows = @(& $RunnerPath --timeout-seconds 20 $TestProgram --registry '' @ProbeArguments 2>&1 |
        ForEach-Object { "$_" })
    [pscustomobject]@{ Exit = $LASTEXITCODE; Rows = $rows }
}

function Assert-SameRows($Left, $Right, [string]$Label) {
    if ($Left.Exit -ne 0 -or $Right.Exit -ne 0) {
        throw "$Label のプローブが異常終了しました: 原版=$($Left.Exit), 候補=$($Right.Exit)"
    }
    $difference = @(Compare-Object -ReferenceObject $Left.Rows -DifferenceObject $Right.Rows -SyncWindow 0)
    if ($difference.Count) {
        throw "$Label の原版比較が不一致です。`n$($difference | Select-Object -First 12 | Out-String -Width 300)"
    }
}

function New-StoredArchive([string]$Name, [string]$Contents) {
    $input = Join-Path $Workspace "$Name-input"
    New-Item -ItemType Directory -Path (Join-Path $input 'folder') | Out-Null
    [IO.File]::WriteAllText((Join-Path $input 'folder\nested.txt'), $Contents, [Text.UTF8Encoding]::new($false))
    $archive = Join-Path $Workspace "$Name.lzh"
    $command = 'a -+ -gm1 -n1 -y1 -jm0 -h2 -x1 "' + $archive + '" "' +
        ($input.Replace('\', '/') + '/') + '" folder/nested.txt'
    $created = Invoke-RunnerProbe @('--command-probe', $Oracle, $command)
    if ($created.Exit -ne 0 -or $created.Rows -notcontains 'result=0' -or
        -not (Test-Path -LiteralPath $archive)) {
        throw "原版のメモリ進捗書庫を作成できません: $Name"
    }
    return (Resolve-Path -LiteralPath $archive).Path
}

function Invoke-MemoryDialog([string]$Dll, [string]$Archive, [string]$Action, [int]$Language) {
    Invoke-RunnerProbe @('--memory-progress-dialog-probe', $Dll, $Archive, '-gm1', '4194304', $Action, [string]$Language)
}

function Assert-RejectedMemoryDialogCapacity([string]$Capacity) {
    $probe = Invoke-RunnerProbe @('--memory-progress-dialog-probe', $Oracle, $dialogArchive, '-gm1', $Capacity)
    if ($probe.Exit -ne 2 -or $probe.Rows -notcontains 'memory progress dialog capacity is invalid') {
        throw "メモリ進捗ダイアログの不正な容量を拒否できません: $Capacity"
    }
}

function Get-StaticDialogSnapshot([string[]]$Rows, [string]$Label) {
    $snapshot = @($Rows | Where-Object {
        $_ -eq 'memory-dialog.present=1' -or $_ -like 'dialog.title=*' -or $_ -like 'dialog.client=*' -or
        $_ -match '^control\.\d+\.id=(601|602|603|604|609|610|605|611|606|1|608),'
    } | ForEach-Object {
        if ($_ -match '^control\.\d+\.id=(603|604|606|610),') {
            [regex]::Replace($_, ',text=(?:"(?:[^"\\]|\\.)*"|[^,]*),check=', ',text=<volatile>,check=')
        } else { $_ }
    })
    if ($snapshot -notcontains 'memory-dialog.present=1' -or
        @($snapshot | Where-Object { $_ -like 'control.*' }).Count -ne 11) {
        throw "$Label で進捗ダイアログの静的構造を取得できません。"
    }
    return $snapshot
}

function Get-DialogCompletion($Probe, [string]$Label, [bool]$Cancelled) {
    if ($Probe.Exit -ne 0 -or $Probe.Rows -notcontains 'memory-dialog.present=1') {
        throw "$Label で進捗ダイアログが生成されません。"
    }
    $summary = @($Probe.Rows | Where-Object { $_ -like 'memory-dialog.complete=*' })
    if ($summary.Count -ne 1) { throw "$Label の完了記録が不正です。" }
    if ($Cancelled) {
        if ($summary[0] -notmatch '^memory-dialog\.complete=1,result=32800,error=32800,system=(18|1223),written=\d+$') {
            throw "$Label の取消結果が原版契約外です: $($summary[0])"
        }
    } elseif ($summary[0] -notmatch '^memory-dialog\.complete=1,result=0,error=0,system=38,written=\d+$') {
        throw "$Label の正常完了結果が不正です: $($summary[0])"
    }
    return $summary[0]
}

function Assert-QuitConsumed($Probe, [string]$Label) {
    $summary = Get-DialogCompletion $Probe $Label $false
    $pending = @($Probe.Rows | Where-Object { $_ -like 'memory-dialog.quit-pending=*' })
    if ($pending.Count -ne 1 -or $pending[0] -ne 'memory-dialog.quit-pending=0') {
        throw "$Label が WM_QUIT を取り去る原版契約と一致しません: $($pending -join ', ')"
    }
    return $summary
}

function Invoke-MemoryProgress([string]$Dll, [string]$Archive, [string[]]$Steps) {
    Invoke-RunnerProbe (@('--progress-sequence-probe', $Dll, 'none', '1041', '1', 'W', 'w64') + $Steps)
}

function Get-ProgressCounts([string[]]$Rows, [string]$Label) {
    $counts = @($Rows | Where-Object { $_ -match '^progress\.count=\d+$' } |
        ForEach-Object { [int]($_ -replace '^progress\.count=', '') })
    if (-not $counts.Count) { throw "$Label に進捗件数がありません。" }
    return $counts
}

$dialogArchive = New-StoredArchive 'dialog' ('0123456789abcdef0123456789abcdef' * 65536)
$cadenceArchive = New-StoredArchive 'cadence' ('0123456789abcdef' * 196608)
$capacityValidations = 0
foreach ($capacity in '-1', '4194305', '4294967296') {
    Assert-RejectedMemoryDialogCapacity $capacity
    $capacityValidations++
}
$hashes = @{}
foreach ($path in $TestProgram, $RunnerPath, $Oracle, $Candidate, $dialogArchive, $cadenceArchive) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
Write-Host "Memory progress dialog: candidate SHA256=$($hashes[$Candidate]), oracle SHA256=$($hashes[$Oracle])"

$uiComparisons = 0
foreach ($language in 1041, 1033) {
    $oracleObserve = Invoke-MemoryDialog $Oracle $dialogArchive 'observe' $language
    $candidateObserve = Invoke-MemoryDialog $Candidate $dialogArchive 'observe' $language
    if ($oracleObserve.Exit -ne 125 -or $candidateObserve.Exit -ne 125) {
        throw "言語 $language の観測プローブが予定どおり停止しません。"
    }
    $difference = @(Compare-Object (Get-StaticDialogSnapshot $oracleObserve.Rows "原版/$language") `
        (Get-StaticDialogSnapshot $candidateObserve.Rows "候補/$language") -SyncWindow 0)
    if ($difference.Count) {
        throw "言語 $language の進捗ダイアログ構造が元 DLL と一致しません。`n$($difference | Out-String -Width 300)"
    }

    $oracleComplete = Invoke-MemoryDialog $Oracle $dialogArchive 'complete' $language
    $candidateComplete = Invoke-MemoryDialog $Candidate $dialogArchive 'complete' $language
    $oracleSummary = Get-DialogCompletion $oracleComplete "原版の正常完了/$language" $false
    $candidateSummary = Get-DialogCompletion $candidateComplete "候補の正常完了/$language" $false
    if ($oracleSummary -cne $candidateSummary) {
        throw "言語 $language の正常完了結果が元 DLL と一致しません。"
    }
    $uiComparisons += 2
}

$oracleCancel = Invoke-MemoryDialog $Oracle $dialogArchive 'cancel' 1041
$candidateCancel = Invoke-MemoryDialog $Candidate $dialogArchive 'cancel' 1041
[void](Get-DialogCompletion $oracleCancel '原版の取消' $true)
[void](Get-DialogCompletion $candidateCancel '候補の取消' $true)
$uiComparisons += 1

$oracleQuit = Invoke-MemoryDialog $Oracle $dialogArchive 'quit' 1041
$candidateQuit = Invoke-MemoryDialog $Candidate $dialogArchive 'quit' 1041
$oracleQuitSummary = Assert-QuitConsumed $oracleQuit '原版の WM_QUIT'
$candidateQuitSummary = Assert-QuitConsumed $candidateQuit '候補の WM_QUIT'
if ($oracleQuitSummary -cne $candidateQuitSummary) {
    throw 'WM_QUIT 投入後の正常完了結果が元 DLL と一致しません。'
}
$uiComparisons += 1

$progressComparisons = 0
foreach ($mode in 0, 1, 2) {
    $memoryStep = '@memory:-gm1 -n' + $mode + ' "' + $dialogArchive + '" *'
    $oracleRows = Invoke-MemoryProgress $Oracle $dialogArchive @($memoryStep)
    $candidateRows = Invoke-MemoryProgress $Candidate $dialogArchive @($memoryStep)
    Assert-SameRows $oracleRows $candidateRows "メモリ進捗 n$mode"
    $count = (Get-ProgressCounts $oracleRows.Rows "メモリ進捗 n$mode")[-1]
    if (($mode -eq 0 -and $count -ne 0) -or ($mode -ne 0 -and $count -le 0)) {
        throw "メモリ進捗 n$mode の通知抑止条件が不正です。"
    }
    $progressComparisons++
}

$normalN0 = 'l -gm1 -n0 "' + $dialogArchive + '" *'
$normalN1 = 'l -gm1 -n1 "' + $dialogArchive + '" *'
$memoryN0 = '@memory:-gm1 -n0 "' + $dialogArchive + '" *'
$memoryN1 = '@memory:-gm1 -n1 "' + $dialogArchive + '" *'
foreach ($entry in @(
        [pscustomobject]@{ Name = 'normal-n0-memory-n1'; Steps = @($normalN0, $memoryN1); Expected = @(0, 1) },
        [pscustomobject]@{ Name = 'normal-n1-memory-n0'; Steps = @($normalN1, $memoryN0); Expected = @(0, 0) })) {
    $oracleRows = Invoke-MemoryProgress $Oracle $dialogArchive $entry.Steps
    $candidateRows = Invoke-MemoryProgress $Candidate $dialogArchive $entry.Steps
    Assert-SameRows $oracleRows $candidateRows "進捗状態隔離/$($entry.Name)"
    $counts = Get-ProgressCounts $oracleRows.Rows "進捗状態隔離/$($entry.Name)"
    if ($counts.Count -ne 2 -or $counts[0] -ne $entry.Expected[0] -or
        (($entry.Expected[1] -eq 0) -ne ($counts[1] -eq 0))) {
        throw "進捗状態隔離の通知件数が不正です: $($entry.Name)"
    }
    $progressComparisons++
}

$cadenceStep = '@memory:-gm1 -n1 "' + $cadenceArchive + '" *'
$oracleCadence = Invoke-MemoryProgress $Oracle $cadenceArchive @($cadenceStep)
$candidateCadence = Invoke-MemoryProgress $Candidate $cadenceArchive @($cadenceStep)
Assert-SameRows $oracleCadence $candidateCadence '3 MiB メモリ進捗間隔'
if ((Get-ProgressCounts $oracleCadence.Rows '3 MiB メモリ進捗間隔')[-1] -lt 50) {
    throw '3 MiB メモリ進捗の中間通知が不足しています。'
}
$progressComparisons++

foreach ($state in 0, 1, 2, 3) {
    $oracleRows = Invoke-MemoryProgress $Oracle $dialogArchive @("@abort-state:$state", $memoryN1)
    $candidateRows = Invoke-MemoryProgress $Candidate $dialogArchive @("@abort-state:$state", $memoryN1)
    Assert-SameRows $oracleRows $candidateRows "メモリ進捗取消 state=$state"
    $progressComparisons++
}

foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) {
        throw "検証中に入力またはバイナリが変更されました: $path"
    }
}
Write-Host "Memory progress dialog: $uiComparisons UI comparisons, $progressComparisons exact callback/cancellation comparisons, and $capacityValidations input validations passed"
