[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Archive,
    [switch]$ReportDifferences
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$empty = Join-Path $Workspace 'empty.lzh'
$garbage = Join-Path $Workspace 'garbage.lzh'
[IO.File]::WriteAllBytes($empty, [byte[]]@())
[IO.File]::WriteAllBytes($garbage, [Text.Encoding]::ASCII.GetBytes('not an LHA archive'))
$inputs = @('@valid', '@null', '@empty', $empty, $garbage, $Workspace,
    ($Workspace + '\'), (Join-Path $Workspace 'missing.lzh'),
    (Join-Path $Workspace 'absent\missing.lzh'), (Join-Path $Workspace 'bad|name.lzh'),
    (Join-Path $Workspace '*.lzh'))
$actions = @('retry', 'settings', 'close-null', 'check-w', 'command-w', 'count-w', 'memory-w',
    'guards', 'api-variants', 'compress-state')
$cases = 0
$snapshots = 0
$failed = 0
foreach ($inputPath in $inputs) {
    foreach ($api in 0..5) {
        foreach ($owner in @($false, $true)) {
            foreach ($action in $actions) {
                if ($action -eq 'compress-state' -and $inputPath -ne '@valid') { continue }
                # NULL 入力は処理を開始しないので、処理中専用の検査は適用しない。
                if ($inputPath -eq '@null' -and $action -in @('guards', 'api-variants')) { continue }
                $arguments = @('--registry', '', '--open-state-probe', $Oracle, $Archive, $inputPath, $api, $action)
                if ($owner) { $arguments += 'owner' }
                $expected = @(& $TestProgram @arguments)
                $originalExit = $LASTEXITCODE
                $arguments[3] = $Candidate
                $actual = @(& $TestProgram @arguments)
                $candidateExit = $LASTEXITCODE
                if ($originalExit -ne 0 -or $candidateExit -ne 0 -or $expected.Count -lt 6 -or $actual.Count -lt 6) {
                    throw "OpenArchive 状態試験の実行が失敗しました: $inputPath / $api / $action / $originalExit,$candidateExit"
                }
                $difference = @(Compare-Object $expected $actual -SyncWindow 0)
                if ($difference.Count -ne 0) {
                    $description = ($difference | Select-Object -First 6 | Out-String)
                    $message = "OpenArchive 状態が一致しません: $inputPath / api=$api / owner=$owner / $action`n$description"
                    if (!$ReportDifferences) { throw $message }
                    Write-Host $message
                    $failed++
                }
                $cases++
                $snapshots += $expected.Count
            }
        }
    }
}
if ($failed -ne 0) { throw "OpenArchive 状態試験: $cases 組中 $failed 組が不一致です。" }
Write-Host "Archive open state: $cases failure/held-handle/API/owner sequences, $snapshots state snapshots compatible"
