[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [int[]]$Sizes = @(0,1,13,64,98,99,100,101,128,255,280,1024,2048),
    [ValidateSet(0,2)][int[]]$Methods = @(0,2),
    [ValidateSet('t','p','e','x')][string[]]$Commands = @('t','p','e','x'),
    [ValidateSet('a32','w32','a64','w64')][string[]]$ProgressLayouts = @('a32','w32','a64','w64'),
    [ValidateRange(0,2)][int]$HeaderLevel = 2,
    [ValidateSet('lh0','lz4')][string]$StoredMethod = 'lh0'
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Extraction initial progress workspace: $Workspace"
$count = 0
$rowCount = 0
foreach ($size in $Sizes) { foreach ($method in $Methods) {
    if ($size -lt 0 -or $size -gt 2048) { throw 'この試験は先頭通知の境界を単一読み取りブロック内で比較します' }
    $seedRoot = Join-Path $Workspace "size-$size-jm$method"
    New-Item -ItemType Directory -Path $seedRoot | Out-Null
    $source = Join-Path $seedRoot 'member.txt'
    $payload = 'Z' * $size
    [IO.File]::WriteAllText($source,$payload,[Text.UTF8Encoding]::new($false))
    $stamp = [datetime]::new(2020,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($source,$stamp)
    [IO.File]::SetLastWriteTimeUtc($source,$stamp)
    [IO.File]::SetLastAccessTimeUtc($source,$stamp)
    $archive = Join-Path $seedRoot 'seed.lzh'
    $created = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -+ -h$HeaderLevel -jm$method -gm1 -y1 `"$archive`" `"$seedRoot\`" member.txt" A)
    if ($LASTEXITCODE -ne 0 -or $created -notcontains 'result=0') { throw '進捗の元書庫を作成できません' }
    $bytes = [IO.File]::ReadAllBytes($archive)
    if ($StoredMethod -eq 'lz4' -and $method -eq 0) {
        if ($HeaderLevel -ne 0) { throw 'lz4 の格納方式対照には level-0 ヘッダーを指定してください' }
        [Text.Encoding]::ASCII.GetBytes('-lz4-').CopyTo($bytes,2)
        $checksum = 0
        for ($offset = 2; $offset -lt [int]$bytes[0] + 2; $offset++) { $checksum = ($checksum + $bytes[$offset]) -band 255 }
        $bytes[1] = [byte]$checksum
        [IO.File]::WriteAllBytes($archive,$bytes)
    }
    $actualMethod = [Text.Encoding]::ASCII.GetString($bytes,2,5)
    if ($method -eq 2 -and $size -ge 100 -and $actualMethod -cne '-lh5-') { throw '圧縮本文の対照がありません' }
    $beforeHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    foreach ($commandName in $Commands) { foreach ($layout in $ProgressLayouts) {
        $label = "h$HeaderLevel/size=$size/jm$method/$commandName/$layout"
        $snapshots = @()
        foreach ($side in 'oracle','reimpl') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $root = Join-Path $seedRoot ('case-{0:D4}-{1}' -f $count,$side)
            New-Item -ItemType Directory -Path $root | Out-Null
            $destination = $root.Replace('\','/') + '/'
            $command = "$commandName -+ -n1 -gm1 -y1 `"$archive`""
            if ($commandName -in 'e','x') { $command += " `"$destination`"" }
            $rows = @(& $TestProgram --registry '' --progress-sequence-probe $dll none 1041 1 W $layout $command)
            if ($LASTEXITCODE -ne 0) { throw "進捗プローブが異常終了しました: $label/$side" }
            [IO.File]::WriteAllLines((Join-Path $root 'trace.txt'),$rows)
            if ($rows -notcontains 'result=0' -or $rows -notcontains 'progress.set=1' -or $rows -notcontains 'progress.kill=1') { throw "正常処理・通知登録に失敗しました: $label/$side" }
            $zeroProgress = @($rows -match '^progress.entry=.*?,state=1,.*?,write=0,').Count
            $expectedZero = if ($size -eq 0 -or ($actualMethod -in '-lh0-','-lz4-' -and $size -lt 100)) { 1 } else { 0 }
            if ($zeroProgress -ne $expectedZero) { throw "先頭または空項目の通知数が不正です: $label/$side expected=$expectedZero actual=$zeroProgress" }
            if ($commandName -in 'e','x') {
                $extracted = Join-Path $root 'member.txt'
                if (!(Test-Path -LiteralPath $extracted) -or [IO.File]::ReadAllText($extracted) -cne $payload) { throw "展開本文が一致しません: $label/$side" }
            }
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $beforeHash) { throw "元書庫が変更されました: $label/$side" }
            $snapshots += ,@($rows | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) { throw "展開の先頭進捗・終了・状態が一致しません: $label`n$($difference | Select-Object -First 8 | Out-String -Width 2000)" }
        $rowCount += $snapshots[0].Count
        $count++
    } }
    Write-Host "Extraction initial progress: size=$size, jm$method, $count comparisons passed"
} }
Write-Host "Extraction initial progress: $count comparisons, $rowCount exact callback/output/state snapshots compatible; extraction payloads matched"
