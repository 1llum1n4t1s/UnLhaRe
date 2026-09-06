[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$CaseNames = @()
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression order workspace: $Workspace"
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
 foreach ($command in 'a','u','f','m') {
  foreach ($api in 'legacy','A','W') {
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
            $rows = @(& $TestProgram --registry '' --base-command-probe $Oracle $seed 1041 1 $api)
            $seedExit = $LASTEXITCODE
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
            $rows = @(& $TestProgram --registry '' --base-command-probe $dll $line 1041 1 $api w64 0)
            $commandExit = $LASTEXITCODE
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
            $metadata = @(& $TestProgram --registry '' --attribute-probe $Oracle $archive)
            $metadataExit = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $root 'metadata.txt'),[string[]](@("probe-exit=$metadataExit") + $metadata))
            if ($metadataExit -ne 0) { throw "順序試験の結果を原版で列挙できません: $label / $side" }
            $rows += $metadata
            $contents = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`"" A)
            $contentsExit = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $root 'payload.txt'),[string[]](@("probe-exit=$contentsExit") + $contents))
            if ($contentsExit -ne 0 -or $contents -notcontains 'result=0') {
                throw "順序試験の内容を原版で展開できません: $label / $side (exit $contentsExit)`n$($contents -join "`n")"
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
    $count++
  }
 }
 Write-Host "Compression order: $($case.Name), $count comparisons passed"
}
Write-Host "Compression order: $count A/W/legacy add/update/freshen/move existing order, replacement, callback order/metadata/path, content, and deletion comparisons passed"
Write-Host "Compression order: $originalRetryCount original MoveFile access-denied retries (cause unconfirmed; failure logs retained)"
