[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('new','files','directories')][string[]]$ArchiveStates = @('new','files','directories')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Directory members workspace: $Workspace"
# 新規格納時の未初期化通知は、通常ファイル検索と同じ安全性契約で検査する。
$helperAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-compression-directories.ps1'),[ref]$null,[ref]$null)
$helper = $helperAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Normalize-NewDirectoryRows'},$true)
if (!$helper) { throw '初回通知の検査処理がありません。' }
. ([scriptblock]::Create($helper.Extent.Text))
$sourceFiles = @('tree/a.txt','tree/sub/z.txt','guard.txt')
function New-MemberFixture([string]$Root,[string]$Prefix,[int]$Year) {
    New-Item -ItemType Directory -Path (Join-Path $Root 'tree/sub'),(Join-Path $Root 'empty') -Force | Out-Null
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    foreach ($name in $sourceFiles) {
        $path = Join-Path $Root $name
        [IO.File]::WriteAllText($path,"$Prefix-$name-value",[Text.UTF8Encoding]::new($false))
        [IO.File]::SetCreationTimeUtc($path,$time)
        [IO.File]::SetLastWriteTimeUtc($path,$time)
        [IO.File]::SetLastAccessTimeUtc($path,$time)
    }
    foreach ($name in 'tree/sub','tree','empty') {
        $path = Join-Path $Root $name
        [IO.Directory]::SetCreationTimeUtc($path,$time)
        [IO.Directory]::SetLastWriteTimeUtc($path,$time)
        [IO.Directory]::SetLastAccessTimeUtc($path,$time)
    }
}
$seedDirectory = Join-Path $Workspace 'seed'
New-MemberFixture $seedDirectory 'seed' 2020
$seeds = @{}
foreach ($state in 'files','directories') {
    $seeds[$state] = Join-Path $Workspace "seed-$state.lzh"
    $selection = if ($state -eq 'directories') { '-d1 guard.txt tree empty' } else { 'guard.txt' }
    $rows = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h0 -gm1 -y1 `"$($seeds[$state])`" `"$seedDirectory\`" $selection" A)
    if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw "ディレクトリーメンバー試験の元書庫を作成できません: $state" }
}
$treeMembers = @('tree/a.txt','tree/sub/z.txt','tree/sub/','tree/')
$cases = @(
    @{ Name='d1-tree'; Flags='-d1'; Input='tree'; Files=@('tree/a.txt','tree/sub/z.txt'); Members=$treeMembers },
    @{ Name='a2-x0-tree'; Flags='-r2 -a2 -x0'; Input='tree'; Files=@('tree/a.txt','tree/sub/z.txt'); Members=@('a.txt','z.txt','sub/','tree/'); Flat=$true },
    @{ Name='a2-x1-tree'; Flags='-r2 -a2 -x1'; Input='tree'; Files=@('tree/a.txt','tree/sub/z.txt'); Members=$treeMembers },
    @{ Name='empty'; Flags='-d1'; Input='empty'; Files=@(); Members=@('empty/') },
    @{ Name='wildcard'; Flags='-d1'; Input='tree/*'; Files=@('tree/a.txt','tree/sub/z.txt'); Members=@('tree/a.txt','tree/sub/z.txt','tree/sub/') },
    @{ Name='empty-first'; Flags='-d1'; Input='empty tree'; Files=@('tree/a.txt','tree/sub/z.txt'); Members=(@('empty/') + $treeMembers) },
    @{ Name='empty-last'; Flags='-d1'; Input='tree empty'; Files=@('tree/a.txt','tree/sub/z.txt'); Members=($treeMembers + @('empty/')) }
)
$modes = @(
    @{ Api='legacy'; Layout='none'; Utf8=0; Locale=1041 },
    @{ Api='legacy'; Layout='a32'; Utf8=0; Locale=1033 },
    @{ Api='A'; Layout='a64'; Utf8=1; Locale=1041 },
    @{ Api='W'; Layout='w32'; Utf8=0; Locale=1041 },
    @{ Api='W'; Layout='w64'; Utf8=1; Locale=1033 }
)
$count = 0
foreach ($state in $ArchiveStates) { foreach ($case in $cases) { foreach ($command in 'a','u','m') { foreach ($mode in $modes) {
    $label = "$state/$($case.Name)/$command/$($mode.Api)/$($mode.Layout)"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ("case-{0:D3}-$side" -f $count)
        $inputDirectory = Join-Path $root 'input'
        New-MemberFixture $inputDirectory 'input' 2024
        $archive = Join-Path $root 'result.lzh'
        if ($state -ne 'new') { Copy-Item -LiteralPath $seeds[$state] -Destination $archive }
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $line = "$command -h0 -n1 -gm1 -y1 -c1 $($case.Flags) `"$archive`" `"$($inputDirectory.Replace('\','/'))/`" $($case.Input)"
        $rows = @(& $TestProgram --registry '' --base-command-probe $dll $line $mode.Locale $mode.Utf8 $mode.Api $mode.Layout 0)
        if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or $rows -notcontains 'directory-preserved=1') { throw "ディレクトリー格納に失敗しました: $label/$side`n$($rows -join "`n")" }
        [IO.File]::WriteAllLines((Join-Path $root 'command.txt'),$rows)
        foreach ($name in $sourceFiles) {
            $path = Join-Path $inputDirectory $name
            $expectedExists = $command -ne 'm' -or $name -notin $case.Files
            if ((Test-Path -LiteralPath $path) -ne $expectedExists) { throw "格納後の入力の有無が違います: $label/$side/$name" }
            if ($expectedExists -and [IO.File]::ReadAllText($path) -cne "input-$name-value") { throw "残存入力が変化しました: $label/$side/$name" }
        }
        foreach ($name in 'tree','tree/sub','empty') { if (-not (Test-Path -LiteralPath (Join-Path $inputDirectory $name) -PathType Container)) { throw "元ディレクトリーが失われました: $label/$side/$name" } }
        $metadata = @(& $TestProgram --registry '' --attribute-probe $Oracle $archive)
        if ($LASTEXITCODE -ne 0) { throw "生成書庫のメタデータを読み取れません: $label/$side" }
        $entries = @($metadata | Where-Object { $_ -match '^attribute\.0\.\d+=' })
        $expectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if ($state -ne 'new') { $null = $expectedNames.Add('guard.txt') }
        if ($state -eq 'directories') { foreach ($name in ($treeMembers + @('empty/'))) { $null = $expectedNames.Add($name) } }
        foreach ($name in $case.Members) { $null = $expectedNames.Add($name) }
        if ($entries.Count -ne $expectedNames.Count) { throw "ディレクトリーの欠落・重複があります: $label/$side, expected=$($expectedNames.Count), actual=$($entries.Count)" }
        foreach ($entry in $entries) {
            if ($entry -notmatch 'name="([^"]+)"' -or -not $expectedNames.Remove($Matches[1])) { throw "予期しないメンバーまたは重複があります: $label/$side/$entry" }
        }
        $check = @(& $TestProgram --registry '' --command-probe-a $Oracle "t -+ `"$archive`"" A)
        if ($LASTEXITCODE -ne 0 -or $check -notcontains 'result=0') { throw "原版の書庫検査に失敗しました: $label/$side" }
        $destination = Join-Path $root 'extracted'
        New-Item -ItemType Directory -Path $destination | Out-Null
        $extraction = @(& $TestProgram --registry '' --command-probe-a $Oracle "x -+ -x1 -a1 -gm1 -y1 `"$archive`" `"$destination\`"" A)
        if ($LASTEXITCODE -ne 0 -or $extraction -notcontains 'result=0') { throw "原版による再展開に失敗しました: $label/$side" }
        $expectedPayloads = @{}
        if ($state -ne 'new') { $expectedPayloads['guard.txt'] = 'seed-guard.txt-value' }
        if ($state -eq 'directories') { foreach ($name in @('tree/a.txt','tree/sub/z.txt')) { $expectedPayloads[$name] = "seed-$name-value" } }
        foreach ($name in $case.Files) { $stored = if ($case.Flat) { [IO.Path]::GetFileName($name) } else { $name }; $expectedPayloads[$stored] = "input-$name-value" }
        $files = @(Get-ChildItem -LiteralPath $destination -File -Recurse)
        if ($files.Count -ne $expectedPayloads.Count) { throw "再展開されたファイル数が違います: $label/$side" }
        foreach ($file in $files) {
            $name = [IO.Path]::GetRelativePath($destination,$file.FullName).Replace('\','/')
            if (-not $expectedPayloads.ContainsKey($name) -or [IO.File]::ReadAllText($file.FullName) -cne $expectedPayloads[$name]) { throw "再展開内容が違います: $label/$side/$name" }
        }
        if ($state -eq 'new') {
            $expectedEntries = if ($mode.Layout -eq 'none') { 0 } else { $case.Members.Count }
            $rows = @(Normalize-NewDirectoryRows $rows $side $expectedEntries)
        }
        $results += ,@(($rows + $entries) | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "ディレクトリー格納の通知・ログ・エラー・並びが一致しません: $label`n$($difference | Select-Object -First 8 | Out-String -Width 2000)" }
    $count++
} }
Write-Host "Directory members: $state/$($case.Name), $count comparisons passed"
} }
Write-Host "Directory members: $count a/u/m creation/update, enumeration, member order, no-duplicate, CRC check, extraction, and source-retention comparisons passed"
