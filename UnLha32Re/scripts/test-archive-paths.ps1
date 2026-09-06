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
$members = Join-Path $Workspace 'MiXeD'
$after = Join-Path $Workspace 'after'
New-Item -ItemType Directory -Path $members, $after | Out-Null
foreach ($name in @('plain.lzh', '資料.lzh', 'emoji-😀-𠮷.lzh')) {
    Copy-Item -LiteralPath $Archive -Destination (Join-Path $members $name)
}
$absolute = Join-Path $members 'plain.lzh'
$cases = @(
    'MiXeD\plain.lzh', '.\MiXeD\plain.lzh', '.\.\MiXeD\plain.lzh',
    'MiXeD\..\MiXeD\plain.lzh', 'MiXeD/./plain.lzh', 'MiXeD//plain.lzh',
    'MiXeD\\plain.lzh', $absolute, $absolute.Replace('\', '/'), $absolute.ToUpperInvariant(),
    $absolute.Substring(2), $absolute.Substring(2).Replace('\', '/'),
    ($Workspace.Substring(0, 2) + 'MiXeD\plain.lzh'), ('\\?\' + $absolute),
    '"MiXeD\plain.lzh"', '"MiXeD\plain.lzh', 'MiXeD\plain.lzh"',
    'MiXeD\plain.lzh  ', 'MiXeD\plain.lzh.', 'MiXeD\absent.lzh',
    'MiXeD\資料.lzh', '.\MiXeD\資料.lzh',
    'MiXeD\emoji-😀-𠮷.lzh', '.\MiXeD\emoji-😀-𠮷.lzh'
)

$caseCount = 0
$rowCount = 0
$failed = 0
Push-Location -LiteralPath $Workspace
try {
    foreach ($inputPath in $cases) {
        foreach ($encoding in @('ansi', 'ansi-ja', 'utf8')) {
            $expected = @(& $TestProgram --registry '' --archive-path-probe $Oracle $inputPath $after $encoding)
            $referenceExit = $LASTEXITCODE
            $actual = @(& $TestProgram --registry '' --archive-path-probe $Candidate $inputPath $after $encoding)
            $candidateExit = $LASTEXITCODE
            if ($referenceExit -ne 0 -or $candidateExit -ne 0) {
                throw "書庫パス比較の実行が失敗しました: $inputPath / $encoding / $referenceExit,$candidateExit"
            }
            $difference = @(Compare-Object $expected $actual -SyncWindow 0)
            if ($difference.Count -ne 0) {
                $description = ($difference | Select-Object -First 6 | ForEach-Object {
                    "$($_.SideIndicator) $($_.InputObject)"
                }) -join "`n"
                $message = "書庫パス取得が一致しません: $inputPath / $encoding`n$description"
                if (!$ReportDifferences) { throw $message }
                Write-Host $message
                $failed++
            }
            $caseCount++
            $rowCount += $expected.Count
        }
    }
} finally { Pop-Location }
if ($failed -ne 0) { throw "書庫パス比較: $caseCount 組中 $failed 組が不一致です。" }
Write-Host "Archive paths: $caseCount path/encoding cases, $rowCount open/name/buffer/state snapshots compatible"

$unicodeArchive = Join-Path $Workspace 'unicode-names.lzh'
& $TestProgram --registry '' --create-unicode-fixture $Oracle $unicodeArchive
if ($LASTEXITCODE -ne 0) { throw '名前取得用の Unicode 書庫を作成できません。' }
$getterRows = 0
$safeRows = 0
foreach ($memberArchive in @($absolute, $unicodeArchive)) {
    foreach ($encoding in @('ansi', 'ansi-ja', 'utf8')) {
        $expected = @(& $TestProgram --registry '' --getter-buffer-probe $Oracle $memberArchive $encoding)
        $referenceExit = $LASTEXITCODE
        $actual = @(& $TestProgram --registry '' --getter-buffer-probe $Candidate $memberArchive $encoding)
        $candidateExit = $LASTEXITCODE
        $difference = @(Compare-Object $expected $actual -SyncWindow 0)
        if ($referenceExit -ne 0 -or $candidateExit -ne 0 -or $expected.Count -ne 1056 -or
                $actual.Count -ne 1056 -or $difference.Count -ne 0) {
            $description = ($difference | Select-Object -First 8 | Out-String)
            throw "文字列取得のバッファ・状態比較が失敗しました: $memberArchive / $encoding`n$description"
        }
        $safety = @(& $TestProgram --registry '' --getter-zero-safety $Candidate $memberArchive $encoding)
        if ($LASTEXITCODE -ne 0 -or $safety.Count -ne 24) {
            throw "候補 DLL のサイズ 0 安全性テストが失敗しました: $memberArchive / $encoding"
        }
        $getterRows += $expected.Count
        $safeRows += $safety.Count
    }
}
Write-Host "String getters: $getterRows buffer/state snapshots compatible, $safeRows size-zero safety checks passed"
