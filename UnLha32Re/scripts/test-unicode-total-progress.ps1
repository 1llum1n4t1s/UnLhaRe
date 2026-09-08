param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$Runner = (Join-Path $PSScriptRoot '../artifacts/Release/DesktopRunner.exe')
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Runner = (Resolve-Path -LiteralPath $Runner).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
New-Item -ItemType Directory -Path $Workspace | Out-Null

$hashes = @{}
foreach ($path in $TestProgram, $Candidate, $Runner) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "Unicode total progress environment: $path, SHA256=$($hashes[$path])"
}

$source = Join-Path $Workspace '日本語.txt'
$archive = Join-Path $Workspace 'archive.lzh'
[IO.File]::WriteAllBytes($source, [Text.Encoding]::UTF8.GetBytes('unicode total progress'))
$command = 'a -+ -jm0 -h2 -n1 -gm1 -y1 "' + $archive + '" "' + $source + '"'
$rows = @(& $Runner --timeout-seconds 30 $TestProgram --registry '' --progress-sequence-probe `
    $Candidate none 1041 1 W total $command 2>&1 | ForEach-Object { "$_" })
$exitCode = $LASTEXITCODE
[IO.File]::WriteAllLines((Join-Path $Workspace 'command.log'), [string[]]$rows)
if ($exitCode -ne 0 -or $rows -notcontains 'result=0' -or
    $rows -notcontains 'progress.set=1' -or $rows -notcontains 'progress.kill=1') {
    throw 'Unicode 全体進捗プローブの実行に失敗しました。'
}
if (-not (Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -le 0) {
    throw 'Unicode 全体進捗プローブが書庫を生成していません。'
}

$progress = @($rows | Where-Object { $_ -like 'progress.entry=*' })
$expectedName = '\u65E5\u672C\u8A9E.txt'
$expectedFields = ',source="' + $expectedName + '",dest="' + $expectedName + '",'
if ($progress.Count -eq 0 -or @($progress | Where-Object { -not $_.Contains($expectedFields) }).Count) {
    throw 'Unicode 全体進捗の source/dest 名が UTF-8 圧縮入力と一致しません。'
}
if ((Get-ChildItem -LiteralPath $Workspace -Filter '*.tmp').Count) {
    throw 'Unicode 全体進捗プローブ後に一時書庫が残っています。'
}
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) {
        throw "検証中に実行ファイルが変更されました: $path"
    }
}

Write-Host "Unicode total progress: $($progress.Count) candidate-only callbacks preserved the Unicode source and destination name"
