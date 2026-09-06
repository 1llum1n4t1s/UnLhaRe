[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$ArchiveDirectory,
    [switch]$Warmup
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$ArchiveDirectory = (Resolve-Path -LiteralPath $ArchiveDirectory).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Header CRC API state workspace: $Workspace"
$count = 0
foreach ($variant in 'good','first','middle','last','all') {
    $archive = Join-Path $ArchiveDirectory "$variant.lzh"
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    foreach ($operation in 'open','find-first','find-next','find-next2','find-end','count','check','memory') { foreach ($layout in 'a32','w32','a64','w64') {
        $label = "$variant/$operation/$layout"
        $failedOpen = $variant -eq 'all' -and $operation -in 'open','find-first','find-next','find-next2','find-end'
        $snapshots = @()
        foreach ($side in 'oracle','reimpl') {
            $root = Join-Path $Workspace ('case-{0:D3}-{1}' -f $count,$side)
            New-Item -ItemType Directory -Path $root | Out-Null
            $source = Join-Path $root 'added.txt'
            [IO.File]::WriteAllText($source,'subsequent new member',[Text.UTF8Encoding]::new($false))
            $stamp = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
            [IO.File]::SetCreationTimeUtc($source,$stamp)
            [IO.File]::SetLastWriteTimeUtc($source,$stamp)
            [IO.File]::SetLastAccessTimeUtc($source,$stamp)
            $created = Join-Path $root 'new.lzh'
            $steps = @(switch ($operation) {
                open { "@open-quiet:$archive"; '@probe-progress-kill'; '@close' }
                find-first { "@open-quiet:$archive"; '@first:*'; '@close' }
                find-next { "@open-quiet:$archive"; '@first:*'; '@next'; '@close' }
                find-next2 { "@open-quiet:$archive"; '@first:*'; '@next'; '@next'; '@close' }
                find-end { "@open-quiet:$archive"; '@first:*'; '@next'; '@next'; '@next'; '@probe-progress-kill'; '@close' }
                count { "@count:$archive" }
                check { "@check:$archive" }
                memory { "@memory:-+ -gm1 `"$archive`" *" }
            })
            $add = "a -+ -h0 -n1 -gm1 -y1 `"$created`" `"$($root.Replace('\','/'))/`" added.txt"
            $steps += $add,"@check:$created"
            if ($Warmup) { $steps = @("a -+ -h0 -n1 -gm1 -y1 `"$(Join-Path $root 'warmup.lzh')`" `"$($root.Replace('\','/'))/`" added.txt") + $steps }
            if ($failedOpen) { $steps += '@expect-progress-kill-failure' }
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $rows = @(& $TestProgram --registry '' --progress-sequence-probe $dll none 1041 1 W $layout @steps)
            $probeExit = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $root 'trace.txt'),$rows)
            if ($probeExit -ne 0) { throw "API 継続プローブが異常終了しました: $label/$side exit=$probeExit" }
            $results = @($rows -match '^result=')
            $expectedKill = if ($failedOpen) { 'progress.kill=0' } else { 'progress.kill=1' }
            if ($results.Count -ne $(if ($Warmup) {2} else {1}) -or $rows -notcontains $expectedKill) { throw "API 継続プローブの終了状態が不正です: $label/$side" }
            if ($Warmup -and $results[0] -cne 'result=0') { throw "事前圧縮に失敗しました: $label/$side" }
            if ($operation -in 'open','find-end' -and $rows -notcontains 'progress.probe-kill=0,error=0,system=0') { throw "書庫保持中の進捗解除を拒否しません: $label/$side" }
            # 全項目不良時の Open は原版の処理中状態を残す。失敗後の実行結果も比較する。
            if ($failedOpen -and ($results[-1] -cne 'result=32799' -or $rows -notcontains 'progress.kill-error=0,system=0' -or (Test-Path -LiteralPath $created))) { throw "Open 失敗後の処理中状態が不正です: $label/$side" }
            if (!$failedOpen -and ($results[-1] -cne 'result=0' -or $rows -notcontains 'check=1')) { throw "API 読み取り後の追加・検査に失敗しました: $label/$side" }
            $snapshots += ,@($rows | ForEach-Object {
                $row = $_
                if ($row -match '^progress.entry=.*?,state=5,') { $row = $row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source=' }
                if ($row -match '^progress.entry=') { $row = $row -replace ',access=\d+',',access=volatile' }
                $row.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            })
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) { throw "ヘッダー CRC 不良後の API 状態が一致しません: $label`n$($difference | Select-Object -First 8 | Out-String -Width 2200)" }
        $count++
    } }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $hash) { throw '参照書庫が変更されました' }
    Write-Host "Header CRC API state: $variant, $count comparisons passed"
}
Write-Host "Header CRC API state: $count Open/Find/Count/Check/Memory, owner-registration and subsequent-command state comparisons compatible"
