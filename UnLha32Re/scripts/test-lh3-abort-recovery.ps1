[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$Runner = (Join-Path $PSScriptRoot '../artifacts/Release/DesktopRunner.exe'),
    [ValidateSet('legacy','A','W')][string[]]$CommandApis = @('legacy','A','W')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Runner = (Resolve-Path -LiteralPath $Runner).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes = @{}
foreach ($path in $TestProgram,$Candidate,$Runner) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash
    Write-Host "LH3 abort environment: $path, SHA256=$($hashes[$path])"
}
$abortCount = 34
foreach ($api in $CommandApis) {
    $root = Join-Path $Workspace $api
    New-Item -ItemType Directory -Path $root | Out-Null
    $inputPath = Join-Path $root 'a.bin'
    $data = [byte[]]::new(131072)
    [Array]::Fill($data,[byte]65)
    [IO.File]::WriteAllBytes($inputPath,$data)
    $inputHash = (Get-FileHash -LiteralPath $inputPath).Hash
    $steps = [Collections.Generic.List[string]]::new()
    $steps.Add('@abort-after-start')
    for ($index=0; $index -lt $abortCount; $index++) {
        # 最初の 2 回でコマンドと通知のキャッシュを温め、その後の増加を測る。
        if ($index -eq 2) { $steps.Add('@private-bytes') }
        $archive = Join-Path $root "abort-$index.lzh"
        $steps.Add("a -+ -jm6 -h2 -n1 -gm1 -y1 `"$archive`" `"$($root.Replace('\','/'))/`" a.bin")
    }
    $steps.Add('@private-bytes')
    $steps.Add('@abort-off')
    $recovered = Join-Path $root 'recovered.lzh'
    $steps.Add("a -+ -jm6 -h2 -n1 -gm1 -y1 `"$recovered`" `"$($root.Replace('\','/'))/`" a.bin")
    $rows = @(& $Runner --timeout-seconds 120 $TestProgram --registry '' --progress-sequence-probe `
        $Candidate none 1041 1 $api total @steps 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $root 'sequence.txt'),[string[]]$rows)
    if ($code -ne 0) { throw "LH3 中断シーケンスのプローブに失敗しました: $api/$code" }
    $results = @($rows | Where-Object { $_ -match '^result=' })
    if ($results.Count -ne $abortCount + 1 -or $results[-1] -cne 'result=0' -or
        @($results[0..($abortCount-1)] | Where-Object { $_ -cne 'result=-1' }).Count) {
        throw "LH3 の中断または再開の結果が不正です: $api"
    }
    $phases = [Collections.Generic.List[object]]::new()
    $phase = $null
    foreach ($row in $rows) {
        if ($row -match '^phase=') {
            $phase = @{ Result=''; Partial=$false }
            $phases.Add($phase)
        } elseif ($row -match '^result=') {
            $phase.Result = $row
        } elseif ($row -match '^progress.entry=.*?,state=1,file=(\d+),write=(\d+),') {
            if ([long]$Matches[2] -gt 0 -and [long]$Matches[2] -lt [long]$Matches[1]) { $phase.Partial = $true }
        }
    }
    if (@($phases | Where-Object { $_.Result -eq 'result=-1' -and $_.Partial }).Count -ne $abortCount) {
        throw "LH3 の全中断が圧縮完了前に到達していません: $api"
    }
    $memory = @($rows | Where-Object { $_ -match '^memory.private-bytes=' } | ForEach-Object { [long]$_.Split('=')[1] })
    if ($memory.Count -ne 2) { throw 'メモリ計測点が不足しています' }
    $growth = $memory[1] - $memory[0]
    # Windows ヒープの保持分に余裕を持たせても、32 回分の 320 KiB 漏れを検出する。
    if ($growth -gt 2MB) { throw "LH3 中断反復でプライベートメモリが増加しました: $api/$growth bytes" }
    if (@(Get-ChildItem -LiteralPath $root -Filter 'abort-*.lzh').Count -or
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count) {
        throw "LH3 中断後に未完成の書庫または一時ファイルが残っています: $api"
    }
    $payload = @(& $Runner --timeout-seconds 30 $TestProgram --registry '' --legacy-payload-probe `
        $Candidate $recovered $inputPath 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $root 'payload.txt'),[string[]]$payload)
    if ($code -ne 0 -or $payload.Count -ne 3 -or
        @($payload -match ',payload=1,prefix=1,tail=1,guard=1$').Count -ne 3) {
        throw "LH3 中断後の再圧縮データが不正です: $api"
    }
    if ((Get-FileHash -LiteralPath $inputPath).Hash -cne $inputHash) { throw '中断試験で入力が変更されました' }
    Write-Host "LH3 abort recovery: $api, $abortCount mid-compression cancellations through total progress, private growth=$growth bytes, clean temporary files and 3 payload guards passed"
}
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]) { throw '中断試験中に実行ファイルが変更されました' }
}
