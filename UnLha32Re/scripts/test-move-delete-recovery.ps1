[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Seed,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Seed = (Resolve-Path -LiteralPath $Seed).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Move deletion recovery workspace: $Workspace"
function Normalize-MoveRecoveryRows([string[]]$Rows, [string]$Variant, [string]$Side) {
    $phase = -1
    $initialEntries = 0
    $numeric = ',original=(-?\d+),packed=(-?\d+),attributes=(-?\d+),crc=(-?\d+),os=(-?\d+),ratio=(-?\d+),create=(-?\d+),access=(-?\d+),write=(-?\d+),'
    foreach ($row in $Rows) {
        if ($row -match '^phase=(\d+)$') { $phase = [int]$Matches[1] }
        if ($Variant -eq 'new' -and $phase -eq 0 -and $row.StartsWith('enum.entry=')) {
            if ($row -notmatch '^enum\.entry=size=\d+,command=2,' -or $row -notmatch $numeric) {
                throw '初回 ADD 通知の形式が不正です。'
            }
            $values = @($Matches[1],$Matches[2],$Matches[3],$Matches[4],$Matches[5],$Matches[6],$Matches[7],$Matches[8],$Matches[9])
            if ($Side -eq 'reimpl' -and @($values | Where-Object { $_ -cne '0' }).Count) {
                throw '候補の初回 ADD 通知がゼロ初期化されていません。'
            }
            # 原版の未初期化領域だけを分離し、サイズ・命令・名前・順序は比較する。
            $row = $row -replace $numeric, ',initial-metadata=<INITIALIZED>,'
            $initialEntries++
        }
        $row
    }
    if ($Variant -eq 'new' -and $initialEntries -ne 3) { throw '初回 ADD 通知の件数が違います。' }
}
$count = 0
foreach ($layout in 'a32','w32','a64','w64') { foreach ($locale in 1033,1041) { foreach ($utf8 in 0,1) { foreach ($api in 'legacy','A','W') { foreach ($variant in 'existing','new') {
    $label = "$layout/$locale/$utf8/$api/$variant"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        # ログの文字数とパスを同時に比較できるよう、両側のディレクトリ名を同長にする。
        $root = Join-Path $Workspace ("case-{0:D3}-$side" -f $count)
        foreach ($stage in 'first','second','final') {
            $directory = Join-Path $root $stage
            New-Item -ItemType Directory -Path $directory | Out-Null
            foreach ($name in 'a.txt','m.txt','z.txt') {
                $path = Join-Path $directory $name
                [IO.File]::WriteAllText($path,"$stage-$name-new-value",[Text.UTF8Encoding]::new($false))
                $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
                [IO.File]::SetCreationTimeUtc($path,$time)
                [IO.File]::SetLastWriteTimeUtc($path,$time)
                [IO.File]::SetLastAccessTimeUtc($path,$time)
            }
        }
        $archive = Join-Path $root 'result.lzh'
        if ($variant -eq 'existing') { Copy-Item -LiteralPath $Seed -Destination $archive }
        $firstDirectory = Join-Path $root 'first'
        $secondDirectory = Join-Path $root 'second'
        $finalDirectory = Join-Path $root 'final'
        # h2 のアクセス日時は原版同士でも実行時刻に依存するため、削除状態の比較は h0 で固定する。
        $first = "m -h0 -n1 -gm1 -y1 -c1 `"$archive`" `"$($firstDirectory.Replace('\','/'))/`" z.txt m.txt a.txt"
        $second = "m -h0 -n1 -gm1 -y1 -c1 `"$archive`" `"$($secondDirectory.Replace('\','/'))/`" a.txt m.txt z.txt"
        $final = "m -h0 -n1 -gm1 -y1 -c1 `"$archive`" `"$($finalDirectory.Replace('\','/'))/`" z.txt m.txt a.txt"
        [IO.File]::SetAttributes((Join-Path $secondDirectory 'a.txt'),[IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Archive)
        $holder = [IO.File]::Open((Join-Path $firstDirectory 'm.txt'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        try {
            $rows = @(& $TestProgram --registry '' --enum-sequence-probe $dll $layout $locale $utf8 $api $first "@count:$archive" "@check:$archive" $second "@count:$archive" "@check:$archive" $final "@check:$archive")
            if ($LASTEXITCODE -ne 0) { throw "削除失敗後の連続呼び出しが異常終了しました: $label/$side" }
        } finally { $holder.Dispose() }
        [IO.File]::WriteAllLines((Join-Path $root 'sequence.log'),[string[]]$rows)
        $commandResults = @($rows | Where-Object { $_ -match '^result=' })
        if (($commandResults -join ',') -cne 'result=32828,result=32828,result=0' -or
            @($rows | Where-Object { $_ -eq 'count=3' }).Count -ne 2 -or
            @($rows | Where-Object { $_ -eq 'check=1' }).Count -ne 3) {
            throw "削除失敗後の書庫・DLLの再利用に失敗しました: $label/$side`n$($rows -join "`n")"
        }
        foreach ($stage in 'first','second','final') {
            $directory = Join-Path $root $stage
            $remaining = @(Get-ChildItem -LiteralPath $directory -File | Sort-Object Name | Select-Object -ExpandProperty Name)
            $expected = switch ($stage) { 'first' { 'a.txt,m.txt' } 'second' { 'a.txt,m.txt,z.txt' } 'final' { '' } }
            if (($remaining -join ',') -cne $expected) { throw "連続呼び出し後の入力が違います: $label/$side/$stage, remaining=$($remaining -join ',')" }
            foreach ($name in $remaining) {
                if ([IO.File]::ReadAllText((Join-Path $directory $name)) -cne "$stage-$name-new-value") { throw "残った入力が変わりました: $label/$side/$stage/$name" }
            }
        }
        foreach ($name in 'a.txt','m.txt','z.txt') {
            $data = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`" $name" A)
            if ($LASTEXITCODE -ne 0 -or $data -notcontains 'result=0' -or $data -notcontains "output=`"final-$name-new-value`"") {
                throw "削除失敗後に再更新した圧縮内容が違います: $label/$side/$name"
            }
            if ($side -eq 'reimpl') {
                # 候補が生成した書庫を、候補自身のメモリ展開 API でも読み返す。
                $readCommand = 'p -+ "' + $archive + '" ' + $name
                $candidateData = @(& $TestProgram --registry '' --command-probe-a $Candidate $readCommand A)
                $candidateDataExit = $LASTEXITCODE
                if ($candidateDataExit -ne 0 -or $candidateData -notcontains 'result=0') {
                    throw "削除失敗後に再更新した圧縮内容を候補自身で読み取れません: $label/$side/$name"
                }
                $payloadDifference = @(Compare-Object $data $candidateData -CaseSensitive -SyncWindow 0)
                if ($payloadDifference.Count) {
                    $details = $payloadDifference | Select-Object -First 8 | Out-String -Width 1500
                    throw ("候補が生成した再更新書庫の自己読み出しが原版読み出しと一致しません: " +
                        $label + "/" + $name + [Environment]::NewLine + $details)
                }
            }
        }
        $results += ,@(Normalize-MoveRecoveryRows $rows $variant $side | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "削除失敗後の状態・出力が一致しません: $label`n$($difference | Select-Object -First 12 | Out-String -Width 2000)" }
    $count++
}
Write-Host "Move deletion recovery: $layout/$locale/$utf8/$api, $count sequences passed"
} } } }
Write-Host "Move deletion recovery: $count shared-delete failure, readonly failure, success, count/check, retained-enum-state, and input-order sequences passed"
