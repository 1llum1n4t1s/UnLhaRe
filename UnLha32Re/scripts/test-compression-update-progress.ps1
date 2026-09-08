[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$Commands = @('a','u','f','m'),
    [string[]]$Selections = @('first','middle','last','all','new','mixed'),
    [string[]]$Ages = @('newer','older'),
    [string[]]$ConfigurationNames = @('plain','a32','w32','a64','w64'),
    [ValidateRange(0,2)][int]$HeaderLevel = 0,
    [ValidateRange(1,200)][int]$PayloadRepeats = 1
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression update progress workspace: $Workspace"
$configs = @(
    @{ Name='plain'; Enum='none'; Progress='w64'; Api='W'; Locale=1033; Utf8=0 },
    @{ Name='a32'; Enum='a32'; Progress='a32'; Api='A'; Locale=1041; Utf8=1 },
    @{ Name='w32'; Enum='w32'; Progress='w32'; Api='W'; Locale=1041; Utf8=0 },
    @{ Name='a64'; Enum='a64'; Progress='a64'; Api='legacy'; Locale=1033; Utf8=0 },
    @{ Name='w64'; Enum='w64'; Progress='w64'; Api='legacy'; Locale=1033; Utf8=1 }
)
$selectedInputs = @{
    first=@('a.txt'); middle=@('m.txt'); last=@('z.txt')
    all=@('z.txt','a.txt','m.txt'); new=@('b.txt'); mixed=@('b.txt','z.txt','a.txt')
}
function Set-ProgressFixture([string]$Path,[string]$Value,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}
$seedRoot = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seedRoot | Out-Null
foreach ($name in 'a.txt','m.txt','z.txt') { Set-ProgressFixture (Join-Path $seedRoot $name) ("old-$name-payload" * $PayloadRepeats) 2020 }
$seed = Join-Path $Workspace 'seed.lzh'
$rows = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h$HeaderLevel -gm1 -y1 `"$seed`" `"$seedRoot\`" a.txt m.txt z.txt" A)
if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw '更新進捗の元書庫を作成できません' }
$count = 0
foreach ($commandName in $Commands) { foreach ($selection in $Selections) { foreach ($age in $Ages) {
    if (-not $selectedInputs.ContainsKey($selection)) { throw "未知の入力選択: $selection" }
    foreach ($config in $configs | Where-Object { $_.Name -in $ConfigurationNames }) {
        $label = "$commandName/$selection/$age/$($config.Name)"
        $snapshots = @()
        foreach ($side in 'oracle','reimpl') {
            $root = Join-Path $Workspace ('case-{0:D3}-{1}' -f $count,$side)
            New-Item -ItemType Directory -Path $root | Out-Null
            foreach ($name in 'a.txt','b.txt','m.txt','z.txt') {
                Set-ProgressFixture (Join-Path $root $name) ("new-$name-payload-with-more-bytes" * $PayloadRepeats) $(if ($age -eq 'newer') { 2024 } else { 2018 })
            }
            $archive = Join-Path $root 'result.lzh'
            Copy-Item -LiteralPath $seed -Destination $archive
            $beforeHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
            $command = "$commandName -+ -h$HeaderLevel -n1 -gm1 -y1 `"$archive`" `"$($root.Replace('\','/'))/`" $($selectedInputs[$selection] -join ' ')"
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $rows = @(& $TestProgram --registry '' --progress-sequence-probe $dll $config.Enum $config.Locale $config.Utf8 $config.Api $config.Progress $command "@check:$archive")
            if ($LASTEXITCODE -ne 0) { throw "更新進捗プローブが異常終了しました: $label/$side" }
            [IO.File]::WriteAllLines((Join-Path $root 'trace.txt'),$rows)
            if ($rows -notcontains 'result=0' -or $rows -notcontains 'compat-error=0' -or
                $rows -notcontains 'check=1' -or $rows -notcontains 'progress.set=1' -or $rows -notcontains 'progress.kill=1') {
                throw "更新・生成書庫の検査・通知登録のいずれかに失敗しました: $label/$side"
            }
            $beginCount = @($rows -match '^progress.entry=.*?,state=0,').Count
            $finishCount = @($rows -match '^progress.entry=.*?,state=6,').Count
            if ($beginCount -ne 3 + $finishCount) { throw "旧 3 メンバーと新入力の BEGIN 件数が不正です: $label/$side" }
            if ($commandName -eq 'f' -and @($rows -match '^progress.entry=.*?,state=5,').Count) { throw "f が DIRECTORY を通知しました: $label/$side" }
            # 原版も不更新時に書庫の更新日時を変更する。内容不変と日時不変を混同しない。
            if ($finishCount -eq 0 -and (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $beforeHash) { throw "不更新の書庫内容が変わりました: $label/$side" }
            $safeOlderMove = $commandName -eq 'm' -and $age -eq 'older'
            $storedNewInput = $selectedInputs[$selection] -contains 'b.txt'
            if ($safeOlderMove) {
                # 古い既存項目は更新せず、新しい名前だけを格納する。未格納入力の削除は安全仕様の例外。
                $expectedFinishes = if ($storedNewInput) { 1 } else { 0 }
                $expectedSystem = if ($side -eq 'reimpl' -and -not $storedNewInput) { 38 } else { 18 }
                $systems = @($rows -match '^compat-system-error=')
                if ($finishCount -ne $expectedFinishes -or $systems.Count -ne 1 -or
                    $systems[0] -cne "compat-system-error=$expectedSystem") {
                    throw "古い入力の移動における格納数・最終エラーが違います: $label/$side"
                }
            }
            $normalized = @()
            $copyStage = $false
            foreach ($row in $rows) {
                if ($safeOlderMove -and $side -eq 'reimpl' -and -not $storedNewInput -and $row -ceq 'compat-system-error=38') {
                    # 上で削除を行わない場合の 38 を検証済み。原版の削除後の 18 とだけ分離する。
                    $row = 'compat-system-error=18'
                }
                if ($row -match '^progress.entry=.*?,state=(\d+),') {
                    $state = [int]$Matches[1]
                    if ($state -eq 4) { $copyStage = $true }
                    # DIRECTORY 数値は原版で未初期化。COPY の一時名と実行時のアクセス日時は別件として生ログに残す。
                    if ($state -eq 5) { $row = $row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source=' }
                    if ($copyStage -and $state -in 1,4) { $row = $row -replace ',source=.*?,dest=',',source=copy-path-unverified,dest=' }
                    $row = $row -replace ',access=\d+',',access=volatile'
                }
                $normalized += $row.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            }
            # 原版で実際に展開し、通知だけでなく書庫の全内容と移動元の状態も比較する。
            $destination = Join-Path $root 'out'
            $extracted = @(& $TestProgram --registry '' --command-probe-a $Oracle "x -+ -n1 -gm1 -y1 `"$archive`" `"$destination\`"" A)
            if ($LASTEXITCODE -ne 0 -or $extracted -notcontains 'result=0') { throw "生成書庫を原版で展開できません: $label/$side" }
            # 原版での展開だけでなく、候補が生成した書庫を候補自身のメモリ展開 API でも読み戻す。
            $contents = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`"" A)
            if ($LASTEXITCODE -ne 0 -or $contents -notcontains 'result=0') { throw "生成書庫の内容を原版で読み戻せません: $label/$side" }
            # finish がない既存書庫は Oracle seed のままなので、候補生成書庫の自己読戻し対象外。
            if ($side -eq 'reimpl' -and $finishCount -gt 0) {
                $candidateContents = @(& $TestProgram --registry '' --command-probe-a $Candidate "p -+ `"$archive`"" A)
                $candidateContentsExit = $LASTEXITCODE
                [IO.File]::WriteAllLines((Join-Path $root 'candidate-payload.txt'),[string[]](@("probe-exit=$candidateContentsExit") + $candidateContents))
                if ($candidateContentsExit -ne 0 -or $candidateContents -notcontains 'result=0') {
                    throw "生成書庫の内容を候補自身で読み戻せません: $label/$side (exit $candidateContentsExit)`n$($candidateContents -join "`n")"
                }
                $contentsDifference = @(Compare-Object $contents $candidateContents -CaseSensitive -SyncWindow 0)
                if ($contentsDifference.Count) {
                    $details = $contentsDifference | Select-Object -First 12 | Out-String -Width 2000
                    throw "候補生成書庫の本文読み戻しが原版と不一致です: $label`n$details"
                }
            }
            if ($safeOlderMove) {
                $expectedNames = @('a.txt','m.txt','z.txt')
                if ($storedNewInput) { $expectedNames += 'b.txt' }
                $actualNames = @(Get-ChildItem -LiteralPath $destination -File -Recurse | ForEach-Object { $_.Name })
                if (@(Compare-Object $expectedNames $actualNames).Count) { throw "古い入力の移動で書庫の項目が変わりました: $label/$side" }
                foreach ($name in $expectedNames) {
                    $expectedData = if ($name -eq 'b.txt') { "new-$name-payload-with-more-bytes" * $PayloadRepeats } else { "old-$name-payload" * $PayloadRepeats }
                    if ([IO.File]::ReadAllText((Join-Path $destination $name),[Text.Encoding]::UTF8) -cne $expectedData) {
                        throw "未更新の旧内容または新規格納内容が違います: $label/$side/$name"
                    }
                }
            }
            foreach ($file in Get-ChildItem -LiteralPath $destination -File -Recurse | Sort-Object FullName) {
                $normalized += "data=$($file.Name),hash=$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
            }
            foreach ($name in 'a.txt','b.txt','m.txt','z.txt') {
                $exists = Test-Path -LiteralPath (Join-Path $root $name)
                if ($safeOlderMove) {
                    $selected = $selectedInputs[$selection] -contains $name
                    $expectedExists = -not $selected -or ($side -eq 'reimpl' -and $name -ne 'b.txt')
                    if ($exists -ne $expectedExists) { throw "未格納入力の保持・格納済み入力の削除が違います: $label/$side/$name" }
                    if ($exists -and [IO.File]::ReadAllText((Join-Path $root $name),[Text.Encoding]::UTF8) -cne ("new-$name-payload-with-more-bytes" * $PayloadRepeats)) {
                        throw "保持した入力内容が変わりました: $label/$side/$name"
                    }
                    # 両側の実状態を検査してから、未格納の旧名だけを比較上の保持状態へそろえる。
                    if ($selected -and $name -ne 'b.txt') { $exists = $true }
                }
                $normalized += "source=$name,exists=$exists"
            }
            $snapshots += ,$normalized
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) { throw "更新時の進捗順・メタデータ・内容が一致しません: $label`n$($difference | Select-Object -First 8 | Out-String -Width 2000)" }
        $count++
    }
} }
Write-Host "Compression update progress: $commandName, $count comparisons passed"
}
if ($count -eq 0) { throw '更新進捗の試験条件が空です' }
Write-Host "Compression update progress: $count existing-member BEGIN, freshen DIRECTORY suppression, notification sequences, metadata, archive-content and source-state comparisons passed (COPY source paths and volatile access time excluded; older m inputs use independently asserted safe retention and deletion-dependent system errors)"
