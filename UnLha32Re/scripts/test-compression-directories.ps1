[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [switch]$NewArchive,
    [string[]]$Variants = @()
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression directories workspace: $Workspace"
function Normalize-NewDirectoryRows([string[]]$Rows, [string]$Side, [int]$ExpectedEntries) {
    $entries = 0
    $numeric = ',original=(-?\d+),packed=(-?\d+),attributes=(-?\d+),crc=(-?\d+),os=(-?\d+),ratio=(-?\d+),create=(-?\d+),access=(-?\d+),write=(-?\d+),'
    foreach ($row in $Rows) {
        if ($row.StartsWith('enum.entry=')) {
            if ($row -notmatch '^enum\.entry=size=\d+,command=2,' -or $row -notmatch $numeric) { throw '初回 ADD 通知の形式が不正です。' }
            $values = @($Matches[1],$Matches[2],$Matches[3],$Matches[4],$Matches[5],$Matches[6],$Matches[7],$Matches[8],$Matches[9])
            if ($Side -eq 'reimpl' -and @($values | Where-Object { $_ -cne '0' }).Count) { throw '初回 ADD 通知がゼロ初期化されていません。' }
            # 新規書庫だけに適用し、名前・順序・サイズ・命令は引き続き比較する。
            $row = $row -replace $numeric, ',initial-metadata=<INITIALIZED>,'
            $entries++
        }
        $row
    }
    if ($entries -ne $ExpectedEntries) { throw '初回 ADD 通知の件数が違います。' }
}
function Set-DirectoryFixture([string]$Path,[string]$Value,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}
$seedDirectory = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seedDirectory | Out-Null
Set-DirectoryFixture (Join-Path $seedDirectory 'guard.txt') 'seed-guard-value' 2020
$seed = Join-Path $Workspace 'seed.lzh'
$rows = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h0 -n1 -gm1 -y1 `"$seed`" `"$seedDirectory\`" guard.txt" A)
if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw '検索試験の元書庫を作成できません。' }
$allFiles = @('tree/a.txt','tree/sub/z.txt','guard.txt')
$both = @('tree/a.txt','tree/sub/z.txt')
# -a2/-d1 のディレクトリーメンバーと進捗通知は、この通常ファイルの検索試験には含めない。
$cases = @(
    @{ Name='literal-r0'; Flags='-r0'; Input='tree'; Files=@() },
    @{ Name='literal-r1'; Flags='-r1'; Input='tree'; Files=@() },
    @{ Name='literal-r2'; Flags='-r2'; Input='tree'; Files=$both },
    @{ Name='wildcard-r0'; Flags='-r0'; Input='tree/*'; Files=@('tree/a.txt') },
    @{ Name='wildcard-r1'; Flags='-r1'; Input='tree/*'; Files=$both },
    @{ Name='wildcard-r2'; Flags='-r2'; Input='tree/*'; Files=$both },
    @{ Name='empty'; Flags='-r1'; Input='empty'; Files=@() },
    @{ Name='literal-r2-x1'; Flags='-r2 -x1'; Input='tree'; Files=$both },
    @{ Name='wildcard-r0-x1'; Flags='-r0 -x1'; Input='tree/*'; Files=@('tree/a.txt') },
    @{ Name='literal-r2-a1'; Flags='-r2 -a1'; Input='tree'; Files=$both },
    @{ Name='wildcard-directory'; Flags='-r2'; Input='tr*'; Files=$both },
    @{ Name='literal-file-r1'; Flags='-r1'; Input='tree/z.txt'; Files=@('tree/sub/z.txt') },
    @{ Name='literal-file-r2'; Flags='-r2'; Input='tree/z.txt'; Files=@() }
)
if ($Variants.Count) { $cases = @($cases | Where-Object Name -in $Variants) }
$modes = @(
    @{ Api='legacy'; Layout='none'; Utf8=0; Locale=1041 },
    @{ Api='legacy'; Layout='a32'; Utf8=0; Locale=1033 },
    @{ Api='A'; Layout='a64'; Utf8=1; Locale=1041 },
    @{ Api='W'; Layout='w32'; Utf8=0; Locale=1041 },
    @{ Api='W'; Layout='w64'; Utf8=1; Locale=1033 }
)
$count = 0
foreach ($case in $cases) { foreach ($command in 'a','u','m') { foreach ($mode in $modes) {
    $label = "$($case.Name)/$command/$($mode.Api)/$($mode.Layout)/$($mode.Locale)/$($mode.Utf8)"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ("case-{0:D3}-$side" -f $count)
        $inputDirectory = Join-Path $root 'input'
        New-Item -ItemType Directory -Path (Join-Path $inputDirectory 'tree/sub'),(Join-Path $inputDirectory 'empty') | Out-Null
        foreach ($name in $allFiles) { Set-DirectoryFixture (Join-Path $inputDirectory $name) "input-$name-value" 2024 }
        $archive = Join-Path $root 'result.lzh'
        if (-not $NewArchive) { Copy-Item -LiteralPath $seed -Destination $archive }
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $line = "$command -h0 -n1 -gm1 -y1 -c1 $($case.Flags) `"$archive`" `"$($inputDirectory.Replace('\','/'))/`" $($case.Input)"
        $rows = @(& $TestProgram --registry '' --base-command-probe $dll $line $mode.Locale $mode.Utf8 $mode.Api $mode.Layout 0)
        if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or $rows -notcontains 'directory-preserved=1') {
            throw "ディレクトリー入力の試験に失敗しました: $label/$side`n$($rows -join "`n")"
        }
        foreach ($name in $allFiles) {
            $path = Join-Path $inputDirectory $name
            $expectedExists = $command -ne 'm' -or $name -notin $case.Files
            if ((Test-Path -LiteralPath $path) -ne $expectedExists) { throw "選択外の削除または削除漏れがあります: $label/$side/$name" }
            if ($expectedExists -and [IO.File]::ReadAllText($path) -cne "input-$name-value") { throw "残った入力が変化しました: $label/$side/$name" }
        }
        foreach ($directory in 'empty','tree','tree/sub') {
            if (-not (Test-Path -LiteralPath (Join-Path $inputDirectory $directory) -PathType Container)) { throw "元ディレクトリーが失われました: $label/$side/$directory" }
        }
        $expectedPayloads = @{}
        if (-not $NewArchive) { $expectedPayloads['guard.txt'] = 'seed-guard-value' }
        foreach ($name in $case.Files) { $expectedPayloads[[IO.Path]::GetFileName($name)] = "input-$name-value" }
        if ((Test-Path -LiteralPath $archive) -ne ($expectedPayloads.Count -gt 0)) { throw "空検索時の書庫の保持・不存在が違います: $label/$side" }
        if ($expectedPayloads.Count) {
            $destination = Join-Path $root 'extracted'
            New-Item -ItemType Directory -Path $destination | Out-Null
            $extraction = @(& $TestProgram --registry '' --command-probe-a $Oracle "e -+ -y1 -gm1 `"$archive`" `"$destination\`"" A)
            if ($LASTEXITCODE -ne 0 -or $extraction -notcontains 'result=0') { throw "生成書庫を原版で展開できません: $label/$side" }
            $files = @(Get-ChildItem -LiteralPath $destination -File -Recurse)
            if ($files.Count -ne $expectedPayloads.Count) { throw "書庫の項目数が違います: $label/$side" }
            foreach ($file in $files) {
                if (-not $expectedPayloads.ContainsKey($file.Name) -or [IO.File]::ReadAllText($file.FullName) -cne $expectedPayloads[$file.Name]) { throw "書庫に選択外の入力または不正な内容が含まれます: $label/$side/$($file.Name)" }
            }
            # 原版での展開だけでなく、候補が生成した書庫を候補自身のメモリ展開 API でも読み戻す。
            $contents = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`"" A)
            if ($LASTEXITCODE -ne 0 -or $contents -notcontains 'result=0') { throw "生成書庫の内容を原版で読み戻せません: $label/$side" }
            # 入力が一つも選ばれない既存書庫ケースは、候補が生成していない Oracle seed を保持する。
            if ($side -eq 'reimpl' -and $case.Files.Count -gt 0) {
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
        }
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if ($NewArchive) {
            $expectedEntries = if ($mode.Layout -eq 'none') { 0 } else { $case.Files.Count }
            $rows = @(Normalize-NewDirectoryRows $rows $side $expectedEntries)
        }
        $results += ,@($rows | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "検索・列挙通知・ログ・エラーが一致しません: $label`n$($difference | Select-Object -First 10 | Out-String -Width 2000)" }
    $count++
} }
Write-Host "Compression directories: $($case.Name), $count comparisons passed"
}
$operation = if ($NewArchive) { 'new' } else { 'existing' }
Write-Host "Compression directories: $count $operation a/u/m r0/r1/r2 selection, callbacks, source retention, directory retention, and full extracted-content comparisons passed"
