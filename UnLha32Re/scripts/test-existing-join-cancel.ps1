[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$FixturesRoot,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('legacy','A','W')][string[]]$Apis = @('legacy','A','W')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$seed = (Resolve-Path -LiteralPath (Join-Path $FixturesRoot 'seed-l2.lzh')).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい既存連結中断試験領域が必要です' }
if (!$Apis.Count -or @($Apis | Sort-Object -Unique).Count -ne $Apis.Count) { throw 'API 指定が空または重複しています' }
$hashes = @{}
foreach ($path in $TestProgram,$Candidate,$runner,$seed) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
$oldBytes = [IO.File]::ReadAllBytes($seed)
$expectedPrefix = [Convert]::ToHexString([byte[]]$oldBytes[0..([Math]::Min(256,$oldBytes.Length)-1)]).ToLowerInvariant()
New-Item -ItemType Directory -Path $Workspace | Out-Null
$count = 0
try {
    foreach ($api in $Apis) { foreach ($state in 5,3,0,1,4,2) {
        $folder = Join-Path $Workspace "$api-state-$state"
        New-Item -ItemType Directory -Path $folder | Out-Null
        $archive = Join-Path $folder 'joined.lzh'
        $source = Join-Path $folder 'source.lzh'
        $retry = Join-Path $folder 'retry.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        Copy-Item -LiteralPath $seed -Destination $source
        $command = 'j -gm1 -y1 -n1 "' + $archive + '" "' + $source + '"'
        $retryCommand = 'j -gm1 -y1 -n1 "' + $retry + '" "' + $source + '"'
        # 原版は INPROCESS 中断で元の書庫パスを失う。候補の保持保証を独立に検査する。
        $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --progress-sequence-probe `
            $Candidate w64 1041 0 $api w64 "@audit-progress-archive:$archive" `
            '@audit-progress-archive-prefix' "@abort-state:$state" $command `
            "@audit-archive-release:$archive" '@handle-count' '@abort-state:-1' $retryCommand `
            "@audit-archive-release:$retry" '@handle-count' 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $folder 'probe.txt'),[string[]]$rows)
        if ($exitCode -ne 0) { throw "中断プローブが異常終了しました: $api/$state/$exitCode" }
        $aborted = $state -in 5,3,0,1
        $expectedResult = if ($aborted) { 32800 } else { 0 }
        $results = @($rows | Where-Object { $_ -match '^result=' })
        $systems = @($rows | Where-Object { $_ -match '^compat-system-error=' })
        $expectedSystem = if ($aborted) { 1223 } else { 38 }
        if ($results.Count -ne 2 -or $results[0] -cne "result=$expectedResult" -or $results[1] -cne 'result=0' -or
            $systems.Count -ne 2 -or $systems[0] -cne "compat-system-error=$expectedSystem" -or $systems[1] -cne 'compat-system-error=38') {
            throw "中断・再利用の戻り値が不正です: $api/$state"
        }
        if (@($rows -ceq 'archive-released=1,error=0').Count -ne 2) { throw "書庫が消えたかハンドルが残っています: $api/$state" }
        $handles = @($rows | Where-Object { $_ -match '^handle-count=' })
        if ($handles.Count -ne 2 -or $handles[0] -cne $handles[1]) { throw "再利用後のハンドル数が不安定です: $api/$state" }
        if ((Get-FileHash -LiteralPath $source).Hash -cne $hashes[$seed]) { throw '連結元が変更されました' }
        if ($aborted) {
            if ((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$seed]) { throw '中断で旧書庫が変更されました' }
            $entries = @($rows | Where-Object { $_ -match '^progress.entry=' -and $_ -notmatch ',null=1,' })
            if (!$entries.Count -or @($entries | Where-Object { !$_.Contains(",audit-archive-size=$($oldBytes.Length),audit-archive-prefix=$expectedPrefix,") }).Count) {
                throw '通知中に元書庫のサイズ・本文が変化したか読めなくなりました'
            }
        } else {
            $joined = [IO.File]::ReadAllBytes($archive)
            $retryBytes = [IO.File]::ReadAllBytes($retry)
            # 旧書庫の終端以外はそのまま、後半は再利用成功時の新規連結書庫と一致する。
            $expected = [byte[]]($oldBytes[0..($oldBytes.Length - 2)] + $retryBytes)
            if ([Convert]::ToHexString($joined) -cne [Convert]::ToHexString($expected)) { throw 'COPY/END 後の旧項目または追加項目が変化しました' }
        }
        # 同じ DLL の後続呼び出しが正常な書庫を生成し、本文を保っていることを別に確認する。
        $retryBytes = [IO.File]::ReadAllBytes($retry)
        if ($retryBytes.Length -lt 65 -or $retryBytes[-1] -ne 0 -or
            @($retryBytes[($retryBytes.Length - 65)..($retryBytes.Length - 2)] -ne 65).Count) { throw '再利用後の本文が不正です' }
        foreach ($path in $archive,$source,$retry) {
            $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
            $stream.Dispose()
        }
        if (@(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp').Count) { throw '一時書庫が残っています' }
        ++$count
    } }
    if ($count -ne $Apis.Count * 6) { throw '中断ケースが不足しています' }
    Write-Host "Existing join safety: $count candidate-only cancellation/reuse cases passed; original archive/source retention, callback-time readability and release verified"
} finally {
    foreach ($path in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]) { throw "検証資産が変更されました: $path" }
    }
}
