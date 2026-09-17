[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$CaseNames = @(),
    [string[]]$Commands = @(),
    [string[]]$Apis = @()
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression order workspace: $Workspace"

# 原版の断続的な停止で統合試験全体が無期限に待たないよう、各 native 呼び出しを
# 非表示デスクトップ・30 秒制限の子プロセスとして実行する。出力は呼び出し元が
# 既存の seed/command/metadata/payload ファイルへ保存し、タイムアウトも終了コードとして残す。
$script:lastProbeExit = 0
$script:lastProbeTimedOut = $false
function Invoke-Probe([string[]]$Arguments) {
    # 属性プローブは 12 回のメモリ展開 API と DLL 解放を 1 子プロセスで
    # 行うため、原版・候補とも通常の単発プローブより終了に時間が掛かる。
    # 出力後の解放待ちをタイムアウトと誤認しないよう、作業量に応じた枠を使う。
    $timeoutSeconds = if ($Arguments.Count -gt 0 -and
        $Arguments[0] -in @('--attribute-probe','--attribute-probe-audit')) { 60 } else { 30 }
    $start = [Diagnostics.ProcessStartInfo]::new($runner)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $Workspace
    foreach ($argument in @('--timeout-seconds',([string]$timeoutSeconds),$TestProgram,'--registry','') + $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $timedOut = !$child.WaitForExit(($timeoutSeconds + 10) * 1000)
        if ($timedOut) { $child.Kill($true); $child.WaitForExit() }
        $output = $stdout.GetAwaiter().GetResult()
        $script:lastProbeTimedOut = $timedOut
        $script:lastProbeExit = if ($timedOut) { 124 } else { $child.ExitCode }
        $reader = [IO.StringReader]::new($output)
        $rows = [Collections.Generic.List[string]]::new()
        try { while ($null -ne ($line = $reader.ReadLine())) { $rows.Add($line) } }
        finally { $reader.Dispose() }
        return $rows.ToArray()
    } finally { $child.Dispose() }
}
$cases = @(
    @{ Name='insert-first'; Seed=@('m.txt','z.txt'); Incoming=@('a.txt') },
    @{ Name='reversed-old'; Seed=@('z.txt','m.txt'); Incoming=@('a.txt') },
    @{ Name='replace-first'; Seed=@('m.txt','z.txt'); Incoming=@('m.txt') },
    @{ Name='replace-last'; Seed=@('m.txt','z.txt'); Incoming=@('z.txt') },
    @{ Name='mixed'; Seed=@('m.txt','z.txt'); Incoming=@('z.txt','a.txt','b.txt') },
    @{ Name='replace-all'; Seed=@('m.txt','z.txt'); Incoming=@('m.txt','a.txt','z.txt') },
    @{ Name='new-only'; Seed=@('m.txt','z.txt'); Incoming=@('b.txt','a.txt') },
    @{ Name='reversed-replace'; Seed=@('z.txt','m.txt'); Incoming=@('m.txt','z.txt') },
    @{ Name='case-replace'; Seed=@('m.txt','z.txt'); Incoming=@('M.TXT') },
    @{ Name='case-existing-upper'; Seed=@('M.TXT','z.txt'); Incoming=@('m.txt'); UpperSeed=$true },
    @{ Name='case-new-upper'; Seed=@('m.txt','z.txt'); Incoming=@('A.TXT') }
)
if ($CaseNames.Count) {
    foreach ($name in $CaseNames) {
        if ($name -cnotin $cases.Name) { throw "未知の順序試験ケースです: $name" }
    }
    $cases = @($cases | Where-Object { $_.Name -cin $CaseNames })
}
$requestedCommands = @($Commands | ForEach-Object { $_ -split ',' | Where-Object { $_ } })
$selectedCommands = @('a','u','f','m')
if ($requestedCommands.Count) {
    foreach ($command in $requestedCommands) {
        if ($command -cnotin $selectedCommands) { throw "未知の順序試験コマンドです: $command" }
    }
    $selectedCommands = @($selectedCommands | Where-Object { $_ -cin $requestedCommands })
}
$requestedApis = @($Apis | ForEach-Object { $_ -split ',' | Where-Object { $_ } })
$selectedApis = @('legacy','A','W')
if ($requestedApis.Count) {
    foreach ($api in $requestedApis) {
        if ($api -cnotin $selectedApis) { throw "未知の順序試験 API です: $api" }
    }
    $selectedApis = @($selectedApis | Where-Object { $_ -cin $requestedApis })
}
$runMetadataPath = Join-Path $Workspace 'compression-order-run.tsv'
$completedCellsPath = Join-Path $Workspace 'compression-order-comparisons.tsv'
foreach ($path in $runMetadataPath,$completedCellsPath) {
    if (Test-Path -LiteralPath $path) { throw "既存の圧縮順序試験記録を上書きできません: $path" }
}
@(
    "field`tvalue"
    "test-program-sha256`t$((Get-FileHash -LiteralPath $TestProgram -Algorithm SHA256).Hash)"
    "oracle-sha256`t$((Get-FileHash -LiteralPath $Oracle -Algorithm SHA256).Hash)"
    "candidate-sha256`t$((Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash)"
    "cases`t$($cases.Name -join ',')"
    "commands`t$($selectedCommands -join ',')"
    "apis`t$($selectedApis -join ',')"
) | Set-Content -LiteralPath $runMetadataPath -Encoding utf8
"case`tcommand`tapi" | Set-Content -LiteralPath $completedCellsPath -Encoding utf8
$count = 0
$originalRetryCount = 0
$when = [DateTime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
function Set-SourceTimes([string]$Path, [DateTime]$Value) {
    [IO.File]::SetCreationTimeUtc($Path,$Value)
    [IO.File]::SetLastWriteTimeUtc($Path,$Value)
    [IO.File]::SetLastAccessTimeUtc($Path,$Value)
}
function Test-OriginalMoveAccessDenied([string[]]$Rows) {
    return $Rows -contains 'result=32792' -and
        $Rows -contains 'compat-system-error=5' -and
        @($Rows -like '*on execute_cmd (MoveFile)*').Count -ne 0
}
foreach ($case in $cases) {
 foreach ($command in $selectedCommands) {
  foreach ($api in $selectedApis) {
    $label = "$($case.Name)-$command-$api"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $completed = $false
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            # 原版だけ再試行しても、出力に埋め込まれるパスのバイト長を両側で同じに保つ。
            # 上限 6 回の一桁番号を初回にも付け、output-length の厳密比較は省略しない。
            $attemptName = "$label-$side-attempt$attempt"
            $root = Join-Path $Workspace $attemptName
            New-Item -ItemType Directory -Path $root | Out-Null
            foreach ($name in 'a.txt','b.txt','m.txt','z.txt') {
                $path = Join-Path $root $name
                [IO.File]::WriteAllBytes($path,[Text.Encoding]::ASCII.GetBytes("old-$name"))
                Set-SourceTimes $path $when.AddYears(-4)
            }
            $archive = Join-Path $root 'result.lzh'
            if ($case.UpperSeed) { Rename-Item -LiteralPath (Join-Path $root 'm.txt') -NewName 'M.TXT' }
            $seedArgs = $case.Seed -join ' '
            # h2 更新 CRC の別件を混ぜず、既存順と置換対象の対応を比較する。
            $seed = "a -h0 -gm1 -n1 -c1 -y1 -x1 `"$archive`" `"$root\`" $seedArgs"
            $rows = @(Invoke-Probe @('--base-command-probe',$Oracle,$seed,'1041','1',$api))
            $seedExit = $script:lastProbeExit
            [IO.File]::WriteAllLines((Join-Path $root 'seed.txt'),[string[]](@("probe-exit=$seedExit") + $rows))
            if ($seedExit -ne 0 -or $rows -notcontains 'result=0' -or -not (Test-Path -LiteralPath $archive)) {
                if ($attempt -lt 5 -and (Test-OriginalMoveAccessDenied $rows)) {
                    [IO.File]::WriteAllLines((Join-Path $root 'original-seed-failure.txt'),[string[]]$rows)
                    $originalRetryCount++
                    Write-Host "Compression order: original MoveFile access denied during seed; retrying in a fresh directory ($label/$side/$attempt)"
                    Start-Sleep -Milliseconds 100
                    continue
                }
                throw "順序試験の更新元作成に失敗しました: $label / $side`n$($rows -join "`n")"
            }
            if ($case.UpperSeed) { Rename-Item -LiteralPath (Join-Path $root 'M.TXT') -NewName 'm.txt' }
            foreach ($name in $case.Incoming) {
                $path = Join-Path $root $name
                [IO.File]::WriteAllBytes($path,[Text.Encoding]::ASCII.GetBytes("new-$name-content"))
                Set-SourceTimes $path $when
            }
            $incomingArgs = $case.Incoming -join ' '
            $line = "$command -h0 -gm1 -n1 -c1 -y1 -x1 `"$archive`" `"$root\`" $incomingArgs"
            $rows = @(Invoke-Probe @('--base-command-probe',$dll,$line,'1041','1',$api,'w64','0'))
            $commandExit = $script:lastProbeExit
            [IO.File]::WriteAllLines((Join-Path $root 'command.txt'),[string[]](@("probe-exit=$commandExit") + $rows))
            if ($commandExit -ne 0 -or $rows -notcontains 'result=0' -or $rows -notcontains 'directory-preserved=1') {
                if ($side -eq 'oracle' -and $attempt -lt 5 -and (Test-OriginalMoveAccessDenied $rows)) {
                    [IO.File]::WriteAllLines((Join-Path $root 'original-update-failure.txt'),[string[]]$rows)
                    $originalRetryCount++
                    Write-Host "Compression order: original MoveFile access denied during update; retrying in a fresh directory ($label/$side/$attempt)"
                    Start-Sleep -Milliseconds 100
                    continue
                }
                throw "順序試験のコマンドに失敗しました: $label / $side`n$($rows -join "`n")"
            }
            # 通知順・格納名だけでなく、旧ヘッダー由来の全数値情報と追加ファイル名も比較する。
            $metadata = @(Invoke-Probe @('--attribute-probe',$Oracle,$archive))
            $metadataExit = $script:lastProbeExit
            [IO.File]::WriteAllLines((Join-Path $root 'metadata.txt'),[string[]](@("probe-exit=$metadataExit") + $metadata))
            if ($metadataExit -ne 0) { throw "順序試験の結果を原版で列挙できません: $label / $side" }
            $rows += $metadata
            $contents = @(Invoke-Probe @('--command-probe-a',$Oracle,"p -+ `"$archive`"",'A'))
            $contentsExit = $script:lastProbeExit
            [IO.File]::WriteAllLines((Join-Path $root 'payload.txt'),[string[]](@("probe-exit=$contentsExit") + $contents))
            if ($contentsExit -ne 0 -or $contents -notcontains 'result=0') {
                throw "順序試験の内容を原版で展開できません: $label / $side (exit $contentsExit)`n$($contents -join "`n")"
            }
            if ($side -eq 'reimpl') {
                # 候補が生成した順序・置換後の書庫を、候補自身の全列挙 API とメモリ展開 API でも読み返す。
                $candidateMetadata = @(Invoke-Probe @('--attribute-probe',$Candidate,$archive))
                $candidateMetadataExit = $script:lastProbeExit
                [IO.File]::WriteAllLines((Join-Path $root 'candidate-metadata.txt'),[string[]](@("probe-exit=$candidateMetadataExit") + $candidateMetadata))
                if ($candidateMetadataExit -ne 0) {
                    throw "順序試験の結果を候補自身で列挙できません: $label / $side"
                }
                $metadataDifference = @(Compare-Object $metadata $candidateMetadata -CaseSensitive -SyncWindow 0)
                if ($metadataDifference.Count) {
                    $details = $metadataDifference | Select-Object -First 12 | Out-String -Width 2000
                    throw "候補が生成した書庫の列挙・メモリ展開が原版と不一致です: $label`n$details"
                }
                $candidateContents = @(Invoke-Probe @('--command-probe-a',$Candidate,"p -+ `"$archive`"",'A'))
                $candidateContentsExit = $script:lastProbeExit
                [IO.File]::WriteAllLines((Join-Path $root 'candidate-payload.txt'),[string[]](@("probe-exit=$candidateContentsExit") + $candidateContents))
                if ($candidateContentsExit -ne 0 -or $candidateContents -notcontains 'result=0') {
                    throw "順序試験の内容を候補自身で展開できません: $label / $side (exit $candidateContentsExit)`n$($candidateContents -join "`n")"
                }
                $contentsDifference = @(Compare-Object $contents $candidateContents -CaseSensitive -SyncWindow 0)
                if ($contentsDifference.Count) {
                    $details = $contentsDifference | Select-Object -First 12 | Out-String -Width 2000
                    throw "候補が生成した書庫の本文展開が原版と不一致です: $label`n$details"
                }
            }
            $rows += @($contents | ForEach-Object { "data.$_" })
            foreach ($name in 'a.txt','b.txt','m.txt','z.txt') {
                $rows += "source=$name,exists=$(Test-Path -LiteralPath (Join-Path $root $name))"
            }
            $results += ,@($rows | ForEach-Object {
                $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            })
            $completed = $true
            break
        }
        if (!$completed) { throw "順序試験の原版取得を再試行できませんでした: $label / $side" }
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) {
        $details = $difference | Select-Object -First 12 | Out-String -Width 2000
        throw "圧縮時の既存順・置換対象・通知順が不一致です: $label`n$details"
    }
    "$($case.Name)`t$command`t$api" | Add-Content -LiteralPath $completedCellsPath -Encoding utf8
    $count++
  }
 }
 Write-Host "Compression order: $($case.Name), $count comparisons passed"
}
Write-Host "Compression order: $count selected API/command existing-order, replacement, callback order/metadata/path, content, and deletion comparisons passed"
Write-Host "Compression order: $originalRetryCount original MoveFile access-denied retries (cause unconfirmed; failure logs retained)"
