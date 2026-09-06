[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GhidraDirectory,
    [Parameter(Mandatory)][string]$JavaDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$reference = Join-Path $repositoryRoot 'sample\ulh3300_extracted\UNLHA32.DLL'
$expectedHash = '126F81C57D54C1CA6BBCDD524C647AF635CDB408401A5BC21216B4A0A792DC5C'
if ((Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash -ne $expectedHash) {
    throw '比較元 DLL が確認済みの 3.00.0.5 と異なります。'
}
$GhidraDirectory = (Resolve-Path -LiteralPath $GhidraDirectory).Path
$JavaDirectory = (Resolve-Path -LiteralPath $JavaDirectory).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$java = Join-Path $JavaDirectory 'bin\java.exe'
$launchSupport = Join-Path $GhidraDirectory 'support\LaunchSupport.jar'
$utility = Join-Path $GhidraDirectory 'Ghidra\Framework\Utility\lib\Utility.jar'
foreach ($file in $java,$launchSupport,$utility) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "解析ツールが見つかりません: $file" }
}
if ((Test-Path -LiteralPath $OutputDirectory) -and
    @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count) {
    throw '既存の解析結果を保護するため、空の出力ディレクトリを指定してください。'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$log = Join-Path $OutputDirectory 'headless.log'
$decompiled = Join-Path $OutputDirectory 'decompiled'
$vmArguments = @(& $java -cp $launchSupport LaunchSupport $GhidraDirectory -vmargs)
if ($LASTEXITCODE -ne 0) { throw 'Ghidra の起動設定を取得できません。' }
Write-Host "Reference SHA256: $expectedHash"
Write-Host "Analysis output: $OutputDirectory"
# Ghidra の設定とキャッシュも出力先に分離し、Java/PATH のシステム設定は変えない。
& $java @vmArguments -Xmx2G -XX:ParallelGCThreads=2 -XX:CICompilerCount=2 `
    "-Dapplication.settingsdir=$OutputDirectory\settings" `
    "-Dapplication.cachedir=$OutputDirectory\cache" "-Dapplication.tempdir=$OutputDirectory\temp" `
    -cp $utility ghidra.Ghidra ghidra.app.util.headless.AnalyzeHeadless `
    $OutputDirectory UNLHA32-reference -import $reference -max-cpu 2 -analysisTimeoutPerFile 600 `
    -scriptPath (Join-Path $PSScriptRoot 'reverse') -postScript ExportUnlhaReference.java $decompiled *> $log
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $decompiled 'analysis.txt'))) {
    throw "逆コンパイルが完了していません。ログ: $log"
}
$summary = Get-Content -LiteralPath (Join-Path $decompiled 'analysis.txt')
if ($summary -notcontains "sha256=$($expectedHash.ToLowerInvariant())" -or
    -not (Select-String -LiteralPath $log -Pattern 'REFERENCE_EXPORT_COMPLETE' -Quiet)) {
    throw "解析対象または出力の完了状態が一致しません。ログ: $log"
}
$summary | Write-Host
if ($summary -notcontains 'failed=0') { throw '逆コンパイルに失敗した関数があります。functions.tsv を確認してください。' }

