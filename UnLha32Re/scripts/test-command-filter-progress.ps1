[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Fixtures,
    [Parameter(Mandatory)][string]$Level2Fixtures,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Fixtures = (Resolve-Path -LiteralPath $Fixtures).Path
$Level2Fixtures = (Resolve-Path -LiteralPath $Level2Fixtures).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
if (!(Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'DesktopRunner が必要です' }
$inputs = [ordered]@{
    lh0=(Join-Path $Fixtures 'literal/lh0-9.lzh')
    pm0=(Join-Path $Fixtures 'literal/pm0-9.lzh')
    mixed=(Join-Path $Fixtures 'mixed/pm0-middle.lzh')
    level2=(Join-Path $Level2Fixtures 'ascii-jm2/good.lzh')
}
$hashes = @{}
foreach ($path in @($TestProgram,$Oracle,$Candidate,$runner)+@($inputs.Values)) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "Command filter environment: $path, SHA256=$($hashes[$path])"
}
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Command filter workspace: $Workspace"
$results = [Collections.Generic.List[object]]::new()
foreach ($name in $inputs.Keys) { foreach ($operation in 'l','v','t','p') {
    foreach ($mode in 0,1,2) { foreach ($api in 'legacy','A','W') { foreach ($profile in 'all','missing','one','reject') {
        $archive = $inputs[$name]
        $pattern = if ($profile -eq 'missing') { 'missing' } elseif ($profile -eq 'one') { 'a.txt' } else { '*' }
        $selected = if ($profile -eq 'reject') { 0 } else { 1 }
        $line = $operation + ' -gm1 -n' + $mode + ' "' + $archive + '" "' + $pattern + '"'
        $label = "$name-$operation-n$mode-$api-$profile"
        $snapshots = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-enum-probe $dll $line w64 $selected '' 1041 1 $api 1 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $Workspace "$label.$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
            if ($code -ne 0 -or @($rows -match '^result=').Count -ne 1) { throw "コマンドが異常終了しました: $label/$side/exit=$code" }
            $snapshots += ,$rows
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        $results.Add([pscustomobject]@{name=$label;differences=$difference.Count})
        if ($difference.Count) {
            $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$label.diff.tsv") -Delimiter "`t" -NoTypeInformation
            throw "フィルター時のログ・状態・列挙・進捗が一致しません: $label"
        }
        if ($results.Count % 48 -eq 0) { Write-Host "Command filter: $($results.Count) comparisons passed" }
    } } }
} }
foreach ($operation in 't','p') { foreach ($mode in 1,2) { foreach ($api in 'legacy','A','W') { foreach ($pattern in '*','missing') {
    $archive = $inputs.lh0
    $line = $operation + ' -gm1 -n' + $mode + ' "' + $archive + '" "' + $pattern + '"'
    $patternName = if ($pattern -eq '*') { 'all' } else { $pattern }
    $label = "cancel-$operation-n$mode-$api-$patternName"
    $snapshots = @()
    foreach ($side in 'oracle','candidate') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-enum-probe $dll $line w64 1 '' 1041 1 $api 1 0 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $Workspace "$label.$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
        if ($code -ne 0 -or @($rows -match '^result=').Count -ne 1) { throw "キャンセル検証が異常終了しました: $label/$side/exit=$code" }
        $snapshots += ,$rows
    }
    $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    $results.Add([pscustomobject]@{name=$label;differences=$difference.Count})
    if ($difference.Count) {
        $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$label.diff.tsv") -Delimiter "`t" -NoTypeInformation
        throw "項目開始キャンセルの戻り値・ログ・状態が一致しません: $label"
    }
} } } }
$results | Export-Csv -LiteralPath (Join-Path $Workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) { throw "検証資産が変化しました: $path" }
}
if ($results.Count -ne 600) { throw 'フィルター検証の条件数が違います' }
Write-Host "Command filter: 576 selection/progress and 24 beginning-cancellation comparisons compatible"
