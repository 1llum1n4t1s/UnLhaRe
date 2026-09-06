[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$Variants = @('new','multi','list','list-first','list-none','missing','open','find','find-none','count','check','off-list','off-add','mutate','memory','test','print','extract'),
    [string[]]$ProgressLayouts = @('a32','w32','a64','w64'),
    [string[]]$Apis = @('legacy','A','W'),
    [int[]]$Locales = @(1033,1041),
    [int[]]$UnicodeModes = @(0,1),
    [ValidateRange(0,2)][int]$SeedHeaderLevel = 0
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Progress state workspace: $Workspace"
$seedRoot = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seedRoot | Out-Null
foreach ($name in 'a.txt','b.txt') {
    $path = Join-Path $seedRoot $name
    [IO.File]::WriteAllText($path,"old-$name-payload",[Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]::new(2020,1,2,3,4,6,[DateTimeKind]::Utc))
}
$seed = Join-Path $Workspace 'seed.lzh'
$rows = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h$SeedHeaderLevel -gm1 -y1 `"$seed`" `"$seedRoot\`" a.txt b.txt" A)
if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw '進捗状態の元書庫を作成できません' }
$count = 0
$guards = 0
foreach ($case in $Variants) { foreach ($progressLayout in $ProgressLayouts) { foreach ($api in $Apis) { foreach ($locale in $Locales) { foreach ($utf8 in $UnicodeModes) {
    $label = "$case/$progressLayout/$api/$locale/$utf8"
    $snapshots = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ('case-{0:D3}-{1}' -f $count,$side)
        New-Item -ItemType Directory -Path (Join-Path $root 'out') | Out-Null
        foreach ($name in 'a.txt','b.txt') {
            $path = Join-Path $root $name
            $payload = if ($name -eq 'a.txt') { 'abcdefghijklmnopqrstuvwxyz' * 200 } else { 'last input bytes!' }
            [IO.File]::WriteAllText($path,$payload,[Text.UTF8Encoding]::new($false))
            $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
            [IO.File]::SetCreationTimeUtc($path,$time)
            [IO.File]::SetLastWriteTimeUtc($path,$time)
            [IO.File]::SetLastAccessTimeUtc($path,$time)
        }
        $base = "`"$($root.Replace('\','/'))/`""
        $first = "a -+ -n1 -gm1 -y1 -h0 `"$(Join-Path $root 'first.lzh')`" $base a.txt"
        $lastArchive = Join-Path $root 'last.lzh'
        $last = "a -+ -n1 -gm1 -y1 -h0 `"$lastArchive`" $base b.txt"
        $steps = @(switch ($case) {
            new { $first }
            multi { }
            list { "l -+ -n1 -gm1 `"$seed`"" }
            list-first { "l -+ -n1 -gm1 `"$seed`" a.txt" }
            list-none { "l -+ -n1 -gm1 `"$seed`" *.missing" }
            missing { $first; "l -+ -n1 -gm1 `"$(Join-Path $root 'missing.lzh')`"" }
            open { "@open:$seed"; '@close' }
            open-add { "@open:$seed"; '@close'; $first }
            off-open-add { '@progress-off'; "@open:$seed"; '@close'; $first; '@progress-on' }
            find { "@open:$seed"; '@first:b.txt'; '@close' }
            find-none { "@open:$seed"; '@first:*.missing'; '@close' }
            count { "@count:$seed" }
            check { "@check:$seed" }
            off-list { '@progress-off'; "l -+ -n1 -gm1 `"$seed`""; '@progress-on' }
            off-add { '@progress-off'; $first; '@progress-on' }
            mutate { '@mutate'; "l -+ -n1 -gm1 `"$seed`"" }
            memory { "@memory:`"$seed`" *" }
            test { "t -+ -n1 -gm1 `"$seed`"" }
            print { "p -+ -n1 -gm1 `"$seed`"" }
            extract { "x -+ -n1 -gm1 -y1 `"$seed`" `"$(Join-Path $root 'out')\`"" }
            default { throw "未知の進捗状態試験: $case" }
        })
        if ($case -eq 'multi') { $last = "a -+ -n1 -gm1 -y1 -h0 `"$lastArchive`" $base a.txt b.txt" }
        $lastPhase = $steps.Count
        $steps += $last,"@check:$lastArchive"
        $enumLayout = if ($case -eq 'mutate') { $progressLayout } else { 'none' }
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(& $TestProgram --registry '' --progress-sequence-probe $dll $enumLayout $locale $utf8 $api $progressLayout @steps)
        if ($LASTEXITCODE -ne 0) { throw "進捗状態のプローブが異常終了しました: $label/$side" }
        [IO.File]::WriteAllLines((Join-Path $root 'trace.txt'),$rows)
        if ($rows -notcontains 'progress.set=1' -or $rows -notcontains 'progress.kill=1' -or $rows -notcontains 'check=1') { throw "進捗の登録・解除・生成書庫の検査に失敗しました: $label/$side" }
        $phase = -1
        $selected = @()
        $lastRows = @()
        $verificationRows = @()
        $disabled = $false
        foreach ($row in $rows) {
            if ($row -match '^phase=(\d+)$') { $phase = [int]$Matches[1] }
            if ($row -eq 'progress.off=1') { $disabled = $true }
            if ($row -eq 'progress.on=1') { $disabled = $false }
            if ($disabled -and $row -match '^progress.count=(\d+)$' -and [int]$Matches[1] -ne 0) { throw "解除区間に進捗通知が発生しました: $label/$side" }
            if ($phase -eq $lastPhase + 1) { $verificationRows += $row }
            if ($phase -ne $lastPhase) { continue }
            $lastRows += $row
            if ($row -match '^progress.entry=.*?,state=(0|6),') {
                # パス表記差とアクセス日時の実行時変動は生ログに残し、数値状態から分離する。
                $selected += $row -replace ',source=.*$','' -replace ',access=\d+',',access=volatile'
            }
            if ($side -eq 'reimpl' -and $row -match '^progress.entry=.*?,state=5,') {
                if ($row -notmatch ',file=0,compressed=0,write=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write-time=0,mode=""') { throw "DIRECTORY の数値がゼロ初期化されていません: $label" }
                $guards++
            }
        }
        if ($case -like 'off-*' -and ($rows -notcontains 'progress.off=1' -or $rows -notcontains 'progress.on=1')) { throw "進捗の解除・復帰を通っていません: $label/$side" }
        if ($selected.Count -ne $(if ($case -eq 'multi') { 4 } else { 2 }) -or
            $lastRows -notcontains 'result=0' -or $lastRows -notcontains 'compat-error=0' -or $lastRows -notcontains 'compat-system-error=38' -or
            $verificationRows -notcontains 'check=1' -or $verificationRows -notcontains 'progress.count=0') { throw "最後の圧縮・BEGIN/FINISH・生成書庫の検査が不正です: $label/$side" }
        $snapshots += ,$selected
    }
    $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    if ($difference.Count) { throw "進捗の圧縮サイズ・CRC・数値状態が一致しません: $label`n$($difference | Select-Object -First 4 | Out-String -Width 2000)" }
    $count++
} } } }
Write-Host "Progress state: $case, $count comparisons passed"
}
Write-Host "Progress state: $count retained-DLL A/W 32/64 BEGIN/FINISH numeric-state comparisons, $guards zero-initialized DIRECTORY guards passed (paths and volatile access time excluded)"
