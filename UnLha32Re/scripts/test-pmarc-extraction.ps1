[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Fixtures,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$CaseLabels = @()
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Fixtures = (Resolve-Path -LiteralPath $Fixtures).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
$cases = [Collections.Generic.List[object]]::new()
# PM2 は非対応方式の読み飛ばし用の任意本文であり、正常な圧縮データとは扱わない。
$files = @('literal/lh0-0.lzh','literal/lh0-9.lzh','literal/pm0-0.lzh',
    'literal/pm0-9.lzh','literal/pm2-0.lzh','literal/pm2-9.lzh')
foreach ($method in 'pm0','pm2') {
    foreach ($position in 'first','middle','last','embedded-large') { $files += "mixed/$method-$position.lzh" }
}
foreach ($file in $files) { foreach ($operation in 'e','x') { foreach ($api in 'legacy','A','W') {
    $stem = $file.Replace('/','-').Replace('.lzh','')
    $cases.Add([pscustomobject]@{ label="$stem-$operation-$api"; file=$file; operation=$operation
        api=$api; profile='normal'; mode=1; locale=1041; unicode=1 })
} } }
foreach ($method in 'pm0','pm2') { foreach ($operation in 'e','x') {
    foreach ($profile in 'missing','reject','existing','n0','n2','english','ansi') {
        $cases.Add([pscustomobject]@{ label="$method-$operation-$profile"; file="literal/$method-9.lzh"
            operation=$operation; api='W'; profile=$profile
            mode=$(if ($profile -eq 'n0') { 0 } elseif ($profile -eq 'n2') { 2 } else { 1 })
            locale=$(if ($profile -eq 'english') { 1033 } else { 1041 })
            unicode=$(if ($profile -eq 'ansi') { 0 } else { 1 }) })
    }
} }
if ($cases.Count -ne 112) { throw 'PMarc 展開の比較条件数が違います' }
if ($CaseLabels.Count) {
    if (@($CaseLabels | Sort-Object -Unique).Count -ne $CaseLabels.Count) { throw 'ラベルが重複しています' }
    foreach ($label in $CaseLabels) { if ($label -cnotin $cases.label) { throw "不明なラベル: $label" } }
    $cases = @($cases | Where-Object { $_.label -cin $CaseLabels })
}
$hashes = @{}
foreach ($path in @($TestProgram,$runner,$Oracle,$Candidate,(Join-Path $Fixtures 'literal/lh0-0.bin'),
    (Join-Path $Fixtures 'literal/lh0-9.bin')) + @($cases.file | Sort-Object -Unique | ForEach-Object { Join-Path $Fixtures $_ })) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Workspace 'environment.json') -Encoding utf8
$cases | Export-Csv -LiteralPath (Join-Path $Workspace 'plan.tsv') -Delimiter "`t" -NoTypeInformation
Write-Host "PMarc extraction workspace: $Workspace; selected=$($cases.Count)"
$results = [Collections.Generic.List[object]]::new()
try {
    foreach ($case in $cases) {
        $snapshots = @()
        $archive = Join-Path $Fixtures $case.file
        $expectedBody = if ($case.file.StartsWith('mixed/')) { 'lh0-9.bin' }
            elseif ($case.file.StartsWith('literal/lh0-')) { [IO.Path]::GetFileNameWithoutExtension($case.file) + '.bin' }
            else { $null }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        foreach ($side in 'oracle','candidate') {
            $directory = Join-Path $Workspace "$($case.label)/$side"
            $outputDirectory = Join-Path $directory 'out'
            New-Item -ItemType Directory -Path $outputDirectory | Out-Null
            $existing = Join-Path $outputDirectory 'member.txt'
            if ($case.profile -eq 'existing') { [IO.File]::WriteAllBytes($existing,[byte[]](83,65,70,69)) }
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $pattern = if ($case.profile -eq 'missing') { 'missing' } else { '*' }
            $selected = if ($case.profile -eq 'reject') { 0 } else { 1 }
            $line = $case.operation + ' -gm1 -n' + $case.mode + ' "' + $archive + '" "out\" "' + $pattern + '"'
            Push-Location $directory
            try {
                $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-enum-probe `
                    $dll $line w64 $selected '' $case.locale $case.unicode $case.api 1 2>&1 | ForEach-Object { "$_" })
                $code = $LASTEXITCODE
            } finally { Pop-Location }
            [IO.File]::WriteAllLines((Join-Path $directory 'probe.txt'),[string[]]$rows)
            if ($code -ne 0 -or @($rows -ceq 'result=0').Count -ne 1) { throw "展開が異常終了しました: $($case.label)/$side/exit=$code" }
            $outputFiles = @(Get-ChildItem -LiteralPath $outputDirectory -Force -Recurse -File)
            $expectedCount = if ($expectedBody -or $case.profile -eq 'existing') { 1 } else { 0 }
            if ($outputFiles.Count -ne $expectedCount -or ($expectedCount -and $outputFiles[0].FullName -cne $existing)) {
                throw "展開ファイルの有無・名前が違います: $($case.label)/$side"
            }
            if ($expectedCount) {
                $body = [IO.File]::ReadAllBytes($existing)
                if ($case.profile -eq 'existing') { $expected = [byte[]](83,65,70,69) }
                else { $expected = [IO.File]::ReadAllBytes((Join-Path $Fixtures "literal/$expectedBody")) }
                if ([Convert]::ToHexString($body) -cne [Convert]::ToHexString($expected)) { throw "本文が違います: $($case.label)/$side" }
            }
            # 書庫と出力を排他で開き、コマンド終了時にハンドルが残っていないことも検査する。
            foreach ($path in @($archive) + @($outputFiles | ForEach-Object { $_.FullName })) {
                $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
                $stream.Dispose()
            }
            $normalized = @($rows | ForEach-Object { $_.Replace($directory.Replace('\','/'),'{case}').Replace($directory.Replace('\','\\'),'{case}') })
            $snapshots += ,$normalized
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) {
            $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$($case.label).diff.tsv") -Delimiter "`t" -NoTypeInformation
            throw "PMarc 展開の状態・通知・ログが一致しません: $($case.label)"
        }
        $results.Add([pscustomobject]@{label=$case.label; elapsedSeconds=$watch.Elapsed.TotalSeconds})
        $results | Export-Csv -LiteralPath (Join-Path $Workspace 'comparisons.tsv') -Delimiter "`t" -NoTypeInformation
        if ($results.Count % 12 -eq 0) { Write-Host "PMarc extraction: $($results.Count) comparisons passed" }
    }
    Write-Host "PMarc extraction: $($results.Count) exact comparisons, output retention/body and exclusive-open guards passed"
} finally {
    foreach ($path in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) { throw "検証中に入力または実行ファイルが変わりました: $path" }
    }
}
