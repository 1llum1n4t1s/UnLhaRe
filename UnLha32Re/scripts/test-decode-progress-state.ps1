[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$Methods = @('jm0','jm1','jm2','jm3','jm4','jmm12','jmm17','jmm19'),
    [int[]]$Sizes = @(0,13,280,2048),
    [ValidateSet('l','v','t','p','e','x')][string[]]$Commands = @('l','v','t','p','e','x'),
    [ValidateSet('a32','w32','a64','w64')][string[]]$ProgressLayouts = @('a32','w32','a64','w64')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Decode progress state workspace: $Workspace"
$count = 0
$rowCount = 0
foreach ($method in $Methods) { foreach ($size in $Sizes) {
    if ($size -lt 0 -or $size -gt 2048) { throw '単一ブロック内の復号状態を比較する試験です' }
    if ($method -notmatch '^(jm[0-4]|jmm(12|17|19))$') { throw "未定義の圧縮方式です: $method" }
    $seedRoot = Join-Path $Workspace "$method-$size"
    New-Item -ItemType Directory -Path $seedRoot | Out-Null
    $payload = 'Z' * $size
    $source = Join-Path $seedRoot 'member.txt'
    [IO.File]::WriteAllText($source,$payload,[Text.UTF8Encoding]::new($false))
    $stamp = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($source,$stamp)
    $archive = Join-Path $seedRoot 'seed.lzh'
    $created = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -+ -h0 -$method -gm1 -y1 `"$archive`" `"$seedRoot\`" member.txt" A)
    if ($LASTEXITCODE -ne 0 -or $created -notcontains 'result=0') { throw "元書庫の作成に失敗しました: $method/$size" }
    $bytes = [IO.File]::ReadAllBytes($archive)
    $actualMethod = [Text.Encoding]::ASCII.GetString($bytes,2,5)
    if ($method -ne 'jm0' -and $size -ge 100 -and $actualMethod -eq '-lh0-') { throw '圧縮本文の対照がありません' }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    foreach ($commandName in $Commands) { foreach ($layout in $ProgressLayouts) {
        $label = "$method/$size/$commandName/$layout"
        $snapshots = @()
        foreach ($side in 'oracle','reimpl') {
            $root = Join-Path $seedRoot ('case-{0:D4}-{1}' -f $count,$side)
            $out = Join-Path $root 'out'
            New-Item -ItemType Directory -Path $out | Out-Null
            $added = Join-Path $root 'added.txt'
            [IO.File]::WriteAllText($added,'subsequent new member',[Text.UTF8Encoding]::new($false))
            [IO.File]::SetCreationTimeUtc($added,$stamp)
            [IO.File]::SetLastWriteTimeUtc($added,$stamp)
            [IO.File]::SetLastAccessTimeUtc($added,$stamp)
            $newArchive = Join-Path $root 'new.lzh'
            $read = "$commandName -+ -n1 -gm1 -y1 `"$archive`""
            if ($commandName -in 'e','x') { $read += " `"$($out.Replace('\','/'))/`"" }
            $add = "a -+ -h0 -n1 -gm1 -y1 `"$newArchive`" `"$($root.Replace('\','/'))/`" added.txt"
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $rows = @(& $TestProgram --registry '' --progress-sequence-probe $dll none 1041 1 W $layout $read $add "@check:$newArchive")
            if ($LASTEXITCODE -ne 0) { throw "復号継続プローブが異常終了しました: $label/$side" }
            [IO.File]::WriteAllLines((Join-Path $root 'trace.txt'),$rows)
            if (@($rows -match '^result=').Count -ne 2 -or @($rows -match '^result=' | Where-Object { $_ -cne 'result=0' }).Count -ne 0 -or $rows -notcontains 'check=1' -or $rows -notcontains 'progress.kill=1') { throw "復号後の追加・検査に失敗しました: $label/$side" }
            if ($commandName -in 'e','x') {
                $extracted = Join-Path $out 'member.txt'
                if (!(Test-Path -LiteralPath $extracted) -or [IO.File]::ReadAllText($extracted) -cne $payload) { throw "展開本文が一致しません: $label/$side" }
            }
            $snapshots += ,@($rows | ForEach-Object {
                $row = $_
                # DIRECTORY の不定数値と実行時アクセス日時は生ログに保持する。
                if ($row -match '^progress.entry=.*?,state=5,') { $row = $row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source=' }
                if ($row -match '^progress.entry=') { $row = $row -replace ',access=\d+',',access=volatile' }
                $row.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            })
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) { throw "復号後の状態が一致しません: $label`n$($difference | Select-Object -First 6 | Out-String -Width 2200)" }
        $count++
        $rowCount += $snapshots[0].Count
    } }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $hash) { throw '元書庫が変更されました' }
    Write-Host "Decode progress state: $method/$size ($actualMethod), $count comparisons passed"
} }
Write-Host "Decode progress state: $count read/add/check comparisons, $rowCount exact callback/output/state snapshots compatible"
